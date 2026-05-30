const std = @import("std");
const ast_walk = @import("ast_walk.zig");
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
    node_index: u32,
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

    if (files.items.len < 2) return;

    var decls: std.ArrayList(DeclInfo) = .empty;
    defer {
        for (decls.items) |*decl| decl.deinit(allocator);
        decls.deinit(allocator);
    }

    for (files.items, 0..) |*file, file_index| {
        if (isPublicApiFile(files.items, file.path)) continue;
        try collectPublicRootDecls(allocator, &file.tree, file_index, &decls);
    }

    const used = try collectProjectUsedDecls(allocator, files.items, decls.items);
    defer allocator.free(used);

    for (decls.items, 0..) |decl, decl_index| {
        if (used[decl_index]) continue;
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
    if (isPublicAliasDecl(tree, full)) return null;

    const token_tags = tree.tokens.items(.tag);
    const name_token = full.ast.mut_token + 1;
    if (name_token >= token_tags.len) return null;
    if (token_tags[name_token] != .identifier) return null;

    const name = tree.tokenSlice(name_token);
    return try makeDeclInfo(
        allocator,
        file_index,
        node_idx,
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
            node_idx,
            tree.fnProto(@enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_simple => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProtoSimple(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_one => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProtoOne(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_multi => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
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
    node_idx: u32,
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
        node_idx,
        tree.tokenSlice(name_token),
        token_starts[name_token],
        .function,
    );
}

fn makeDeclInfo(
    allocator: std.mem.Allocator,
    file_index: usize,
    node_index: u32,
    name: []const u8,
    byte_offset: usize,
    kind: DeclKind,
) !DeclInfo {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const normalized_copy = try allocator.dupe(u8, normalizeIdentifier(name));
    return .{
        .file_index = file_index,
        .node_index = node_index,
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

fn isPublicEntrypointPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/lib.zig") or std.mem.endsWith(u8, path, "/src/lib.zig");
}

fn isPublicApiFile(files: []const FileInfo, path: []const u8) bool {
    if (isPublicEntrypointPath(path)) return true;

    for (files) |*file| {
        if (!isPublicEntrypointPath(file.path)) continue;
        if (filePubliclyImportsPath(file, path)) return true;
    }
    return false;
}

fn filePubliclyImportsPath(file: *const FileInfo, target_path: []const u8) bool {
    const tags = file.tree.nodes.items(.tag);

    for (file.tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        if (idx >= tags.len) continue;
        if (!isVarDeclTag(tags[idx])) continue;
        if (publicVarDeclImportsPath(&file.tree, @intCast(idx), file.path, target_path)) return true;
    }
    return publicUsingnamespaceImportsPath(&file.tree, file.path, target_path);
}

fn publicVarDeclImportsPath(
    tree: *const std.zig.Ast,
    node_idx: u32,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return false;
    if (!isPubToken(tree, full.visib_token)) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const init_idx = @intFromEnum(init_node);
    const tags = tree.nodes.items(.tag);
    if (init_idx >= tags.len) return false;

    switch (tags[init_idx]) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, init_idx) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        else => return false,
    }
}

fn isVarDeclTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .simple_var_decl,
        .aligned_var_decl,
        .global_var_decl,
        .local_var_decl,
        => true,
        else => false,
    };
}

fn isPublicAliasDecl(tree: *const std.zig.Ast, full: std.zig.Ast.full.VarDecl) bool {
    if (tree.tokenTag(full.ast.mut_token) != .keyword_const) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const init_idx = @intFromEnum(init_node);
    const tags = tree.nodes.items(.tag);
    if (init_idx >= tags.len) return false;

    const name_token = full.ast.mut_token + 1;
    if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) return false;
    const public_name = tree.tokenSlice(name_token);

    return switch (tags[init_idx]) {
        .identifier => isReexportAlias(public_name, identifierName(tree, init_idx) orelse return false),
        .field_access => isReexportAlias(public_name, fieldAccessName(tree, init_idx) orelse return false),
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => isImportBuiltinCall(tree, init_idx),
        else => false,
    };
}

fn isImportBuiltinCall(tree: *const std.zig.Ast, node_idx: usize) bool {
    return importPathFromBuiltinCall(tree, node_idx) != null;
}

fn importPathFromBuiltinCall(tree: *const std.zig.Ast, node_idx: usize) ?[]const u8 {
    const main_tokens = tree.nodes.items(.main_token);
    if (node_idx >= main_tokens.len) return null;
    const token = main_tokens[node_idx];
    if (token >= tree.tokens.len) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(token), "@import")) return null;

    const token_tags = tree.tokens.items(.tag);
    var scan_token = token + 1;
    const end_token = @min(token_tags.len, token + 6);
    while (scan_token < end_token) : (scan_token += 1) {
        if (token_tags[scan_token] != .string_literal) continue;
        const literal = tree.tokenSlice(scan_token);
        if (literal.len < 2) return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

fn importResolvesToPath(importer_path: []const u8, import_path: []const u8, target_path: []const u8) bool {
    if (std.mem.eql(u8, import_path, target_path)) return true;

    const importer_dir = std.fs.path.dirname(importer_path) orelse "";
    if (importer_dir.len == 0) return pathsEquivalent(import_path, target_path);

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ importer_dir, import_path }) catch return false;
    return pathsEquivalent(resolved, target_path);
}

fn classifyVarDecl(tree: *const std.zig.Ast, full: std.zig.Ast.full.VarDecl) DeclKind {
    if (full.ast.init_node.unwrap()) |init_node| {
        const tag = tree.nodes.items(.tag)[@intFromEnum(init_node)];
        if (isContainerTag(tag) or tag == .error_set_decl) return .type_decl;
    }
    const mut_tag = tree.tokenTag(full.ast.mut_token);
    if (mut_tag == .keyword_const) return .constant;
    if (mut_tag == .keyword_var) return .variable;
    return .declaration;
}

fn collectProjectUsedDecls(
    allocator: std.mem.Allocator,
    files: []const FileInfo,
    decls: []const DeclInfo,
) ![]bool {
    const used = try allocator.alloc(bool, decls.len);
    @memset(used, false);

    for (decls, 0..) |decl, decl_index| {
        if (isReferencedWithinDeclFile(files[decl.file_index], decl) or isReferencedFromAnotherFile(files, decl)) {
            used[decl_index] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (decls, 0..) |decl, decl_index| {
            if (!used[decl_index]) continue;
            if (try markPublicSurfaceReferences(files, decls, used, decl)) changed = true;
        }
    }

    return used;
}

fn isReferencedWithinDeclFile(file: FileInfo, decl: DeclInfo) bool {
    const tags = file.tree.nodes.items(.tag);
    const main_tokens = file.tree.nodes.items(.main_token);

    for (tags, 0..) |tag, node_index| {
        if (node_index == decl.node_index) continue;
        if (tag != .identifier) continue;
        if (node_index >= main_tokens.len) continue;

        const name = normalizeIdentifier(file.tree.tokenSlice(main_tokens[node_index]));
        if (std.mem.eql(u8, name, decl.normalized_name)) return true;
    }

    return false;
}

fn isReferencedFromAnotherFile(files: []const FileInfo, decl: DeclInfo) bool {
    const decl_file = files[decl.file_index];
    for (files, 0..) |*file, file_index| {
        if (file_index == decl.file_index) continue;
        if (std.mem.eql(u8, file.path, decl_file.path)) continue;
        if (fileReferencesDecl(files, file, decl_file.path, decl.normalized_name)) return true;
    }
    return false;
}

fn markPublicSurfaceReferences(
    files: []const FileInfo,
    decls: []const DeclInfo,
    used: []bool,
    decl: DeclInfo,
) !bool {
    const file = &files[decl.file_index];
    var scanner = PublicSurfaceScanner{
        .tree = &file.tree,
        .decls = decls,
        .used = used,
        .file_index = decl.file_index,
    };
    try scanner.scanDecl(decl.node_index);
    return scanner.changed;
}

const PublicSurfaceScanner = struct {
    tree: *const std.zig.Ast,
    decls: []const DeclInfo,
    used: []bool,
    file_index: usize,
    changed: bool = false,
    stop: bool = false,

    fn scanDecl(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        switch (tags[node]) {
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            => try self.scanVarDeclSurface(node),
            .fn_decl => {
                const data = self.tree.nodes.items(.data)[node];
                try self.scanFnProto(@intFromEnum(data.node_and_node[0]));
            },
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => try self.scanFnProto(node),
            else => {},
        }
    }

    fn scanVarDeclSurface(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
        try self.scanOptionalNode(full.ast.type_node);

        const init_node = full.ast.init_node.unwrap() orelse return;
        const init_idx = @intFromEnum(init_node);
        const tags = self.tree.nodes.items(.tag);
        if (init_idx < tags.len and isContainerTag(tags[init_idx])) {
            try self.scanContainerSurface(init_idx);
        } else {
            try self.scanNode(init_idx);
        }
    }

    fn scanFnProto(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[node]) {
            .fn_proto => self.tree.fnProto(@enumFromInt(node)),
            .fn_proto_simple => self.tree.fnProtoSimple(&buffer, @enumFromInt(node)),
            .fn_proto_one => self.tree.fnProtoOne(&buffer, @enumFromInt(node)),
            .fn_proto_multi => self.tree.fnProtoMulti(@enumFromInt(node)),
            else => return,
        };

        for (proto.ast.params) |param| try self.scanParam(@intFromEnum(param));
        try self.scanOptionalNode(proto.ast.return_type);
        try self.scanOptionalNode(proto.ast.align_expr);
        try self.scanOptionalNode(proto.ast.addrspace_expr);
        try self.scanOptionalNode(proto.ast.section_expr);
        try self.scanOptionalNode(proto.ast.callconv_expr);
    }

    fn scanParam(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        if (isVarDeclTag(tags[node])) {
            const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
            try self.scanOptionalNode(full.ast.type_node);
            return;
        }

        try self.scanNode(node);
    }

    fn scanContainerSurface(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        switch (tags[node]) {
            .container_decl,
            .container_decl_trailing,
            => try self.scanContainerDeclComponents(self.tree.containerDecl(@enumFromInt(node))),
            .container_decl_two,
            .container_decl_two_trailing,
            => {
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                try self.scanContainerDeclComponents(self.tree.containerDeclTwo(&buffer, @enumFromInt(node)));
            },
            .container_decl_arg,
            .container_decl_arg_trailing,
            => try self.scanContainerDeclComponents(self.tree.containerDeclArg(@enumFromInt(node))),
            .tagged_union,
            .tagged_union_trailing,
            => try self.scanContainerDeclComponents(self.tree.taggedUnion(@enumFromInt(node))),
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => try self.scanContainerDeclComponents(self.tree.taggedUnionEnumTag(@enumFromInt(node))),
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                try self.scanContainerDeclComponents(self.tree.taggedUnionTwo(&buffer, @enumFromInt(node)));
            },
            else => {},
        }
    }

    fn scanContainerDeclComponents(
        self: *PublicSurfaceScanner,
        container: std.zig.Ast.full.ContainerDecl,
    ) anyerror!void {
        if (container.ast.arg.unwrap()) |arg_node| try self.scanNode(@intFromEnum(arg_node));

        const tags = self.tree.nodes.items(.tag);
        for (container.ast.members) |member_node| {
            const member = @intFromEnum(member_node);
            if (member >= tags.len) continue;

            switch (tags[member]) {
                .container_field,
                .container_field_init,
                .container_field_align,
                => try self.scanContainerField(member),
                .simple_var_decl,
                .aligned_var_decl,
                .global_var_decl,
                => {
                    const full = self.tree.fullVarDecl(@enumFromInt(member)) orelse continue;
                    if (isPubToken(self.tree, full.visib_token)) try self.scanVarDeclSurface(member);
                },
                .fn_decl,
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => if (isPublicFnDecl(self.tree, member)) try self.scanDecl(member),
                else => {},
            }
        }
    }

    fn scanContainerField(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const field = self.tree.fullContainerField(@enumFromInt(node)) orelse return;
        try self.scanOptionalNode(field.ast.type_expr);
        try self.scanOptionalNode(field.ast.value_expr);
        try self.scanOptionalNode(field.ast.align_expr);
    }

    fn scanOptionalNode(self: *PublicSurfaceScanner, node_opt: std.zig.Ast.Node.OptionalIndex) anyerror!void {
        if (node_opt.unwrap()) |node| try self.scanNode(@intFromEnum(node));
    }

    fn scanNode(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        try ast_walk.walk(PublicSurfaceScanner, self.tree, node, self);
    }

    pub fn visit(
        self: *PublicSurfaceScanner,
        tree: *const std.zig.Ast,
        node: u32,
        tag: std.zig.Ast.Node.Tag,
    ) anyerror!void {
        if (tag != .identifier) return;

        const main_tokens = tree.nodes.items(.main_token);
        if (node >= main_tokens.len) return;
        self.markIdentifier(tree.tokenSlice(main_tokens[node]));
    }

    fn markIdentifier(self: *PublicSurfaceScanner, identifier: []const u8) void {
        const normalized = normalizeIdentifier(identifier);
        for (self.decls, 0..) |candidate, candidate_index| {
            if (candidate.file_index != self.file_index) continue;
            if (self.used[candidate_index]) continue;
            if (!std.mem.eql(u8, candidate.normalized_name, normalized)) continue;

            self.used[candidate_index] = true;
            self.changed = true;
        }
    }
};

fn fileReferencesDecl(files: []const FileInfo, file: *const FileInfo, decl_path: []const u8, normalized_name: []const u8) bool {
    if (fileReferencesDeclByFieldAccess(files, &file.tree, file.path, decl_path, normalized_name)) return true;
    if (fileUsingnamespaceImportsPath(&file.tree, file.path, decl_path) and fileReferencesBareName(&file.tree, normalized_name)) return true;
    return false;
}

fn fileReferencesDeclByFieldAccess(
    files: []const FileInfo,
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    decl_path: []const u8,
    normalized_name: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    for (tags, 0..) |tag, node_index| {
        if (tag != .field_access) continue;
        const field_token = datas[node_index].node_and_token[1];
        const slice = normalizeIdentifier(tree.tokenSlice(field_token));
        if (!std.mem.eql(u8, slice, normalized_name)) continue;

        const lhs = @intFromEnum(datas[node_index].node_and_token[0]);
        if (nodeImportsPath(files, tree, lhs, importer_path, decl_path)) return true;
    }
    return false;
}

fn fileReferencesBareName(tree: *const std.zig.Ast, normalized_name: []const u8) bool {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    for (tags, 0..) |tag, node_index| {
        if (tag != .identifier) continue;
        if (node_index >= main_tokens.len) continue;
        const name = normalizeIdentifier(tree.tokenSlice(main_tokens[node_index]));
        if (std.mem.eql(u8, name, normalized_name)) return true;
    }
    return false;
}

fn nodeImportsPath(
    files: []const FileInfo,
    tree: *const std.zig.Ast,
    node: usize,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    switch (tags[node]) {
        .identifier => {
            const name = identifierName(tree, node) orelse return false;
            return importAliasResolvesToPath(tree, importer_path, name, target_path);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, node) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        .field_access => {
            const datas = tree.nodes.items(.data);
            const lhs = @intFromEnum(datas[node].node_and_token[0]);
            const field_name = normalizeIdentifier(tree.tokenSlice(datas[node].node_and_token[1]));

            for (files) |*candidate| {
                if (!nodeImportsPath(files, tree, lhs, importer_path, candidate.path)) continue;
                if (filePublicMemberImportsPath(candidate, field_name, target_path)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn importAliasResolvesToPath(
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    alias_name: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);

    for (tags, 0..) |tag, node_index| {
        if (!isVarDeclTag(tag)) continue;
        const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
        const name_token = full.ast.mut_token + 1;
        if (name_token >= tree.tokens.len) continue;
        if (tree.tokenTag(name_token) != .identifier) continue;

        const name = normalizeIdentifier(tree.tokenSlice(name_token));
        if (!std.mem.eql(u8, name, alias_name)) continue;

        const init_node = full.ast.init_node.unwrap() orelse continue;
        if (initNodeImportsPath(tree, @intFromEnum(init_node), importer_path, target_path)) return true;
    }

    return false;
}

fn fileUsingnamespaceImportsPath(
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const token_tags = tree.tokens.items(.tag);

    for (token_tags, 0..) |_, token_index| {
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "usingnamespace")) continue;

        const import_token = nextNonCommentToken(token_tags, token_index + 1) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(import_token)), "@import")) continue;

        const import_path = importPathFromBuiltinToken(tree, import_token) orelse continue;
        if (importMayResolveToPath(importer_path, import_path, target_path)) return true;
    }

    return false;
}

fn publicUsingnamespaceImportsPath(
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const token_tags = tree.tokens.items(.tag);

    for (token_tags, 0..) |_, token_index| {
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "usingnamespace")) continue;

        const pub_token = prevNonCommentToken(token_tags, token_index) orelse continue;
        if (tree.tokenTag(@intCast(pub_token)) != .keyword_pub) continue;

        const import_token = nextNonCommentToken(token_tags, token_index + 1) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(import_token)), "@import")) continue;

        const import_path = importPathFromBuiltinToken(tree, import_token) orelse continue;
        if (importMayResolveToPath(importer_path, import_path, target_path)) return true;
    }

    return false;
}

fn importPathFromBuiltinToken(tree: *const std.zig.Ast, token: usize) ?[]const u8 {
    const token_tags = tree.tokens.items(.tag);
    const l_paren = nextNonCommentToken(token_tags, token + 1) orelse return null;
    if (token_tags[l_paren] != .l_paren) return null;

    const string_token = nextNonCommentToken(token_tags, l_paren + 1) orelse return null;
    if (token_tags[string_token] != .string_literal) return null;

    const literal = tree.tokenSlice(@intCast(string_token));
    if (literal.len < 2) return null;
    return literal[1 .. literal.len - 1];
}

fn initNodeImportsPath(
    tree: *const std.zig.Ast,
    node: usize,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    switch (tags[node]) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, node) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        else => {
            var scanner = ImportPathScanner{
                .importer_path = importer_path,
                .target_path = target_path,
            };
            ast_walk.walk(ImportPathScanner, tree, @intCast(node), &scanner) catch return false;
            return scanner.found;
        },
    }
}

const ImportPathScanner = struct {
    importer_path: []const u8,
    target_path: []const u8,
    found: bool = false,
    stop: bool = false,

    pub fn visit(
        self: *ImportPathScanner,
        tree: *const std.zig.Ast,
        node: u32,
        tag: std.zig.Ast.Node.Tag,
    ) anyerror!void {
        switch (tag) {
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const import_path = importPathFromBuiltinCall(tree, node) orelse return;
                if (importMayResolveToPath(self.importer_path, import_path, self.target_path)) {
                    self.found = true;
                    self.stop = true;
                }
            },
            else => {},
        }
    }
};

fn nextNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
    var index = start;
    while (index < token_tags.len) : (index += 1) {
        switch (token_tags[index]) {
            .container_doc_comment, .doc_comment => continue,
            else => return index,
        }
    }
    return null;
}

fn prevNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
    if (start == 0) return null;
    var index = start - 1;
    while (true) {
        switch (token_tags[index]) {
            .container_doc_comment, .doc_comment => {},
            else => return index,
        }
        if (index == 0) return null;
        index -= 1;
    }
}

fn identifierName(tree: *const std.zig.Ast, node: usize) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .identifier) return null;
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return null;
    return normalizeIdentifier(tree.tokenSlice(main_tokens[node]));
}

fn fieldAccessName(tree: *const std.zig.Ast, node: usize) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .field_access) return null;
    const datas = tree.nodes.items(.data);
    return normalizeIdentifier(tree.tokenSlice(datas[node].node_and_token[1]));
}

fn filePublicMemberImportsPath(file: *const FileInfo, member_name: []const u8, target_path: []const u8) bool {
    const tags = file.tree.nodes.items(.tag);

    for (file.tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        if (idx >= tags.len) continue;
        if (!isVarDeclTag(tags[idx])) continue;
        if (publicVarDeclNamedImportsPath(&file.tree, @intCast(idx), file.path, member_name, target_path)) return true;
    }
    return false;
}

fn publicVarDeclNamedImportsPath(
    tree: *const std.zig.Ast,
    node_idx: u32,
    importer_path: []const u8,
    expected_name: []const u8,
    target_path: []const u8,
) bool {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return false;
    if (!isPubToken(tree, full.visib_token)) return false;

    const name_token = full.ast.mut_token + 1;
    if (name_token >= tree.tokens.len) return false;
    if (tree.tokenTag(name_token) != .identifier) return false;
    const name = normalizeIdentifier(tree.tokenSlice(name_token));
    if (!std.mem.eql(u8, name, expected_name)) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const import_path = importPathFromBuiltinCall(tree, @intFromEnum(init_node)) orelse return false;
    return importMayResolveToPath(importer_path, import_path, target_path);
}

fn importMayResolveToPath(importer_path: []const u8, import_path: []const u8, target_path: []const u8) bool {
    if (importResolvesToPath(importer_path, import_path, target_path)) return true;
    return packageImportMayResolveToPath(import_path, target_path);
}

fn packageImportMayResolveToPath(import_path: []const u8, target_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, import_path, '/') != null) return false;
    if (std.mem.endsWith(u8, import_path, ".zig")) return false;

    const basename = std.fs.path.basename(target_path);
    if (!std.mem.endsWith(u8, basename, ".zig")) return false;
    const stem = basename[0 .. basename.len - ".zig".len];
    return std.mem.eql(u8, stem, import_path);
}

fn isReexportAlias(public_name: []const u8, referenced_name: []const u8) bool {
    const normalized_public = normalizeIdentifier(public_name);
    const normalized_referenced = normalizeIdentifier(referenced_name);
    if (std.mem.eql(u8, normalized_public, normalized_referenced)) return true;
    return isTypeLikeName(normalized_public) and isTypeLikeName(normalized_referenced);
}

fn isTypeLikeName(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.ascii.isUpper(name[0]);
}

fn pathsEquivalent(a: []const u8, b: []const u8) bool {
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized_a = normalizePath(&a_buf, a) catch return false;
    const normalized_b = normalizePath(&b_buf, b) catch return false;
    return std.mem.eql(u8, normalized_a, normalized_b);
}

fn normalizePath(buffer: []u8, path: []const u8) ![]const u8 {
    var segments: [128][]const u8 = undefined;
    var segment_count: usize = 0;

    var rest = path;
    while (rest.len > 0) {
        const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const segment = rest[0..slash_index];
        if (segment.len != 0 and !std.mem.eql(u8, segment, ".")) {
            if (std.mem.eql(u8, segment, "..") and segment_count > 0) {
                segment_count -= 1;
            } else {
                if (segment_count >= segments.len) return error.PathTooManySegments;
                segments[segment_count] = segment;
                segment_count += 1;
            }
        }
        if (slash_index == rest.len) break;
        rest = rest[slash_index + 1 ..];
    }

    var len: usize = 0;
    for (segments[0..segment_count]) |segment| {
        if (len != 0) {
            if (len >= buffer.len) return error.PathTooLong;
            buffer[len] = '/';
            len += 1;
        }
        if (len + segment.len > buffer.len) return error.PathTooLong;
        @memcpy(buffer[len..][0..segment.len], segment);
        len += segment.len;
    }

    return buffer[0..len];
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

fn isPublicFnDecl(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const proto = switch (tags[node]) {
        .fn_decl => blk: {
            const data = tree.nodes.items(.data)[node];
            const proto_node = @intFromEnum(data.node_and_node[0]);
            break :blk switch (tags[proto_node]) {
                .fn_proto => tree.fnProto(@enumFromInt(proto_node)),
                .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
                .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
                .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(proto_node)),
                else => return false,
            };
        },
        .fn_proto => tree.fnProto(@enumFromInt(node)),
        .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(node)),
        .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(node)),
        .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(node)),
        else => return false,
    };

    return isPubToken(tree, proto.visib_token);
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

test "project unused declarations recognize public entrypoint path" {
    try std.testing.expect(isPublicEntrypointPath("src/lib.zig"));
    try std.testing.expect(isPublicEntrypointPath("workspace/src/lib.zig"));
    try std.testing.expect(!isPublicEntrypointPath("src/main.zig"));
    try std.testing.expect(!isPublicEntrypointPath("test/fixtures/project_unused_decl/lib.zig"));
}
