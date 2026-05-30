const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Source = @import("source.zig").Source;
const suppression = @import("suppression.zig");

const rule_id = "unused-decl";

const DeclKind = enum {
    function,
    type_decl,
    constant,
    variable,
    declaration,

    fn description(self: DeclKind) []const u8 {
        return switch (self) {
            .function => "Function",
            .type_decl => "Type",
            .constant => "Constant",
            .variable => "Variable",
            .declaration => "Declaration",
        };
    }
};

const FileInfo = struct {
    path: []const u8,
    content: [:0]const u8,
    tree: std.zig.Ast,
    suppressions: suppression.SuppressionMap,

    fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        self.suppressions.deinit();
        self.tree.deinit(allocator);
        allocator.free(self.content.ptr[0 .. self.content.len + 1]);
    }
};

const DeclInfo = struct {
    file_index: usize,
    name: []const u8,
    normalized_name: []const u8,
    byte_offset: usize,
    kind: DeclKind,

    fn deinit(self: *DeclInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.normalized_name);
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (file_paths.len < 2) return;

    var files: std.ArrayList(FileInfo) = .empty;
    defer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    for (file_paths) |path| {
        if (containsPath(files.items, path)) continue;

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const max_size = 10 * 1024 * 1024;
        // Sentinel needed for std.zig.Ast.parse; free accounts for sentinel byte below.
        // zwanzig-disable-next-line: sentinel-alloc
        const content = try file.readToEndAllocOptions(
            allocator,
            max_size,
            null,
            std.mem.Alignment.of(u8),
            0,
        );
        errdefer allocator.free(content.ptr[0 .. content.len + 1]);

        var tree = try std.zig.Ast.parse(allocator, content, .zig);
        errdefer tree.deinit(allocator);

        var suppressions = try suppression.parseSuppressions(allocator, content);
        errdefer suppressions.deinit();

        try files.append(allocator, .{
            .path = path,
            .content = content,
            .tree = tree,
            .suppressions = suppressions,
        });
    }

    var decls: std.ArrayList(DeclInfo) = .empty;
    defer {
        for (decls.items) |*decl| decl.deinit(allocator);
        decls.deinit(allocator);
    }

    for (files.items, 0..) |*file, file_index| {
        try collectPublicRootDecls(allocator, &file.tree, file_index, &decls);
    }

    for (decls.items) |decl| {
        if (isReferencedFromAnotherFile(files.items, decl)) continue;

        var source = Source.init(allocator, files.items[decl.file_index].path, files.items[decl.file_index].content);
        defer source.deinit();
        const range = try source.byteRangeToSourceRange(decl.byte_offset, decl.byte_offset + decl.name.len);

        if (files.items[decl.file_index].suppressions.isSuppressed(range.start.line, rule_id)) continue;

        const message = try std.fmt.allocPrint(
            allocator,
            "{s} '{s}' is never used by another analyzed file",
            .{ decl.kind.description(), decl.name },
        );
        defer allocator.free(message);

        var diag = try Diagnostic.init(
            allocator,
            files.items[decl.file_index].path,
            rule_id,
            .warning,
            message,
            range,
        );
        errdefer diag.deinit(allocator);
        try diagnostics.append(allocator, diag);
    }
}

fn containsPath(files: []const FileInfo, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}

fn collectPublicRootDecls(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    file_index: usize,
    decls: *std.ArrayList(DeclInfo),
) !void {
    const tags = tree.nodes.items(.tag);
    const token_starts = tree.tokens.items(.start);

    for (tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        const info = switch (tags[idx]) {
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            => try extractPublicVarDecl(allocator, tree, @intCast(idx), token_starts, file_index),
            .fn_decl,
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => try extractPublicFnDecl(allocator, tree, @intCast(idx), token_starts, file_index),
            else => null,
        };

        if (info) |decl| {
            if (isSpecialName(decl.name)) {
                var mutable_decl = decl;
                mutable_decl.deinit(allocator);
                continue;
            }
            var mutable_decl = decl;
            errdefer mutable_decl.deinit(allocator);
            try decls.append(allocator, mutable_decl);
        }
    }
}

fn extractPublicVarDecl(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node_idx: u32,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return null;
    if (!isPubToken(tree, full.visib_token)) return null;
    if (full.extern_export_token != null) return null;

    const token_tags = tree.tokens.items(.tag);
    const name_token = full.ast.mut_token + 1;
    if (name_token >= token_tags.len) return null;
    if (token_tags[name_token] != .identifier) return null;

    const name = tree.tokenSlice(name_token);
    return try makeDeclInfo(
        allocator,
        file_index,
        name,
        token_starts[name_token],
        classifyVarDecl(tree, full),
    );
}

fn extractPublicFnDecl(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node_idx: u32,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    const tags = tree.nodes.items(.tag);
    const tag = tags[node_idx];
    var buffer: [1]std.zig.Ast.Node.Index = undefined;

    return switch (tag) {
        .fn_decl => blk: {
            const data = tree.nodes.items(.data)[node_idx];
            const proto_node = @intFromEnum(data.node_and_node[0]);
            break :blk extractPublicFnDecl(allocator, tree, proto_node, token_starts, file_index);
        },
        .fn_proto => extractPublicFnProto(
            allocator,
            tree,
            tree.fnProto(@enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_simple => extractPublicFnProto(
            allocator,
            tree,
            tree.fnProtoSimple(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_one => extractPublicFnProto(
            allocator,
            tree,
            tree.fnProtoOne(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_multi => extractPublicFnProto(
            allocator,
            tree,
            tree.fnProtoMulti(@enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        else => null,
    };
}

fn extractPublicFnProto(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    proto: std.zig.Ast.full.FnProto,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    if (!isPubToken(tree, proto.visib_token)) return null;
    if (proto.extern_export_inline_token) |tok| {
        const tag = tree.tokenTag(tok);
        if (tag == .keyword_extern or tag == .keyword_export) return null;
    }

    const name_token = proto.name_token orelse return null;
    if (tree.tokenTag(name_token) != .identifier) return null;

    return try makeDeclInfo(
        allocator,
        file_index,
        tree.tokenSlice(name_token),
        token_starts[name_token],
        .function,
    );
}

fn makeDeclInfo(
    allocator: std.mem.Allocator,
    file_index: usize,
    name: []const u8,
    byte_offset: usize,
    kind: DeclKind,
) !DeclInfo {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const normalized_copy = try allocator.dupe(u8, normalizeIdentifier(name));
    return .{
        .file_index = file_index,
        .name = name_copy,
        .normalized_name = normalized_copy,
        .byte_offset = byte_offset,
        .kind = kind,
    };
}

fn isPubToken(tree: *const std.zig.Ast, token: ?std.zig.Ast.TokenIndex) bool {
    const tok = token orelse return false;
    return tree.tokenTag(tok) == .keyword_pub;
}

fn classifyVarDecl(tree: *const std.zig.Ast, full: std.zig.Ast.full.VarDecl) DeclKind {
    if (full.ast.init_node.unwrap()) |init_node| {
        if (isContainerTag(tree.nodes.items(.tag)[@intFromEnum(init_node)])) return .type_decl;
    }
    const mut_tag = tree.tokenTag(full.ast.mut_token);
    if (mut_tag == .keyword_const) return .constant;
    if (mut_tag == .keyword_var) return .variable;
    return .declaration;
}

fn isReferencedFromAnotherFile(files: []const FileInfo, decl: DeclInfo) bool {
    const decl_file = files[decl.file_index];
    for (files, 0..) |*file, file_index| {
        if (file_index == decl.file_index) continue;
        if (std.mem.eql(u8, file.path, decl_file.path)) continue;
        if (fileReferencesName(&file.tree, decl.normalized_name)) return true;
    }
    return false;
}

fn fileReferencesName(tree: *const std.zig.Ast, normalized_name: []const u8) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    for (tags, 0..) |tag, node_index| {
        if (tag != .field_access) continue;
        const field_token = datas[node_index].node_and_token[1];
        const slice = normalizeIdentifier(tree.tokenSlice(field_token));
        if (std.mem.eql(u8, slice, normalized_name)) return true;
    }
    return false;
}

fn normalizeIdentifier(ident: []const u8) []const u8 {
    if (ident.len >= 3 and std.mem.startsWith(u8, ident, "@\"") and ident[ident.len - 1] == '"') {
        return ident[2 .. ident.len - 1];
    }
    return ident;
}

fn isSpecialName(name: []const u8) bool {
    if (name.len > 0 and name[0] == '_') return true;
    if (std.mem.eql(u8, name, "main")) return true;
    if (std.mem.eql(u8, name, "panic")) return true;
    if (std.mem.eql(u8, name, "std_options")) return true;
    return false;
}

fn isContainerTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}
