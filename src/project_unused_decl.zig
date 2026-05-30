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

const ProjectContext = struct {
    allocator: std.mem.Allocator,
    files: []const FileInfo,
    api_roots: std.ArrayList(usize) = .empty,

    fn init(allocator: std.mem.Allocator, files: []const FileInfo) ProjectContext {
        return .{
            .allocator = allocator,
            .files = files,
        };
    }

    fn deinit(self: *ProjectContext) void {
        self.api_roots.deinit(self.allocator);
    }

    fn collectApiRoots(self: *ProjectContext) !void {
        for (self.files, 0..) |*file, file_index| {
            if (!std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig")) continue;
            try self.collectBuildRootSourceFiles(file_index);
        }
        try self.collectExternalBuildRootSourceFiles("build.zig");
    }

    fn isPublicApiFile(self: *const ProjectContext, file_index: usize) bool {
        if (self.containsApiRoot(file_index)) return true;

        const target_path = self.files[file_index].path;
        for (self.api_roots.items) |root_index| {
            if (filePubliclyImportsPath(self.files, &self.files[root_index], target_path)) return true;
        }
        return false;
    }

    fn containsApiRoot(self: *const ProjectContext, file_index: usize) bool {
        for (self.api_roots.items) |root_index| {
            if (root_index == file_index) return true;
        }
        return false;
    }

    fn appendApiRoot(self: *ProjectContext, file_index: usize) !void {
        if (self.containsApiRoot(file_index)) return;
        try self.api_roots.append(self.allocator, file_index);
    }

    fn collectBuildRootSourceFiles(self: *ProjectContext, build_file_index: usize) !void {
        try self.collectBuildRootSourceFilesFromTree(&self.files[build_file_index].tree, self.files[build_file_index].path);
    }

    fn collectExternalBuildRootSourceFiles(self: *ProjectContext, build_path: []const u8) !void {
        if (findFileIndexByPath(self.files, build_path) != null) return;

        const file = std.fs.cwd().openFile(build_path, .{}) catch return;
        defer file.close();

        const max_size = 10 * 1024 * 1024;
        // Sentinel needed for std.zig.Ast.parse; free accounts for sentinel byte below.
        // zwanzig-disable-next-line: sentinel-alloc
        const content = try file.readToEndAllocOptions(
            self.allocator,
            max_size,
            null,
            std.mem.Alignment.of(u8),
            0,
        );
        defer self.allocator.free(content.ptr[0 .. content.len + 1]);

        var tree = try std.zig.Ast.parse(self.allocator, content, .zig);
        defer tree.deinit(self.allocator);

        try self.collectBuildRootSourceFilesFromTree(&tree, build_path);
    }

    fn collectBuildRootSourceFilesFromTree(self: *ProjectContext, tree: *const std.zig.Ast, build_path: []const u8) !void {
        const token_tags = tree.tokens.items(.tag);
        for (token_tags, 0..) |_, token_index| {
            if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "root_source_file")) continue;

            var scan_token = token_index + 1;
            var remaining: usize = 24;
            while (scan_token < token_tags.len and remaining > 0) : ({
                scan_token += 1;
                remaining -= 1;
            }) {
                if (token_tags[scan_token] != .string_literal) continue;
                const literal = tree.tokenSlice(@intCast(scan_token));
                if (literal.len < 2) continue;
                const root_path = literal[1 .. literal.len - 1];
                if (resolveImportToFileIndex(self.files, build_path, root_path)) |root_index| {
                    try self.appendApiRoot(root_index);
                }
                break;
            }
        }
    }
};

const ResolvedType = struct {
    file_index: usize,
    type_name: ?[]const u8 = null,
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

    var project = ProjectContext.init(allocator, files.items);
    defer project.deinit();
    try project.collectApiRoots();

    var decls: std.ArrayList(DeclInfo) = .empty;
    defer {
        for (decls.items) |*decl| decl.deinit(allocator);
        decls.deinit(allocator);
    }

    for (files.items, 0..) |*file, file_index| {
        if (project.isPublicApiFile(file_index)) continue;
        try collectPublicRootDecls(allocator, &file.tree, file.path, file_index, &decls);
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
    return findFileIndexByPath(files, path) != null;
}

fn findFileIndexByPath(files: []const FileInfo, path: []const u8) ?usize {
    for (files, 0..) |file, file_index| {
        if (std.mem.eql(u8, file.path, path) or pathsEquivalent(file.path, path)) return file_index;
    }
    return null;
}

fn collectPublicRootDecls(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    path: []const u8,
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
            if (isIgnoredPublicDecl(path, decl.name)) {
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

fn filePubliclyImportsPath(files: []const FileInfo, file: *const FileInfo, target_path: []const u8) bool {
    const tags = file.tree.nodes.items(.tag);

    for (file.tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        if (idx >= tags.len) continue;
        if (!isVarDeclTag(tags[idx])) continue;
        if (publicVarDeclImportsPath(&file.tree, @intCast(idx), file.path, target_path)) return true;
    }
    return publicUsingnamespaceImportsPath(files, &file.tree, file.path, target_path);
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

fn isBuiltinCallTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

fn isRootDeclNode(tree: *const std.zig.Ast, node_index: usize) bool {
    for (tree.rootDecls()) |decl| {
        if (@intFromEnum(decl) == node_index) return true;
    }
    return false;
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
        if (isReferencedWithinDeclFile(files, decl) or isReferencedFromAnotherFile(files, decl)) {
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

fn isReferencedWithinDeclFile(files: []const FileInfo, decl: DeclInfo) bool {
    const file = files[decl.file_index];
    const tags = file.tree.nodes.items(.tag);
    const main_tokens = file.tree.nodes.items(.main_token);

    for (tags, 0..) |tag, node_index| {
        if (node_index == decl.node_index) continue;
        if (tag != .identifier) continue;
        if (node_index >= main_tokens.len) continue;

        const name = normalizeIdentifier(file.tree.tokenSlice(main_tokens[node_index]));
        if (std.mem.eql(u8, name, decl.normalized_name)) return true;
    }

    if (fileReferencesDeclByTypedReceiver(files, decl.file_index, decl.file_index, decl.normalized_name)) return true;

    return false;
}

fn isReferencedFromAnotherFile(files: []const FileInfo, decl: DeclInfo) bool {
    const decl_file = files[decl.file_index];
    for (files, 0..) |*file, file_index| {
        if (file_index == decl.file_index) continue;
        if (std.mem.eql(u8, file.path, decl_file.path)) continue;
        if (fileReferencesDecl(files, file_index, decl.file_index, decl_file.path, decl.normalized_name)) return true;
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

fn fileReferencesDecl(
    files: []const FileInfo,
    file_index: usize,
    decl_file_index: usize,
    decl_path: []const u8,
    normalized_name: []const u8,
) bool {
    const file = &files[file_index];
    if (fileReferencesDeclByFieldAccess(files, &file.tree, file.path, decl_path, normalized_name)) return true;
    if (fileReferencesDeclByTypedReceiver(files, file_index, decl_file_index, normalized_name)) return true;
    if (fileUsingnamespaceImportsPath(files, &file.tree, file.path, decl_path) and fileReferencesBareName(&file.tree, normalized_name)) return true;
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

fn fileReferencesDeclByTypedReceiver(
    files: []const FileInfo,
    file_index: usize,
    decl_file_index: usize,
    normalized_name: []const u8,
) bool {
    const file = &files[file_index];
    const tree = &file.tree;
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    var resolver = TypeResolver{
        .files = files,
        .file_index = file_index,
    };

    for (tags, 0..) |tag, node_index| {
        switch (tag) {
            .field_access => {
                const field_access = datas[node_index].node_and_token;
                const field_name = normalizeIdentifier(tree.tokenSlice(field_access[1]));
                if (!std.mem.eql(u8, field_name, normalized_name)) continue;

                const receiver = @intFromEnum(field_access[0]);
                if (resolver.resolveExprType(receiver)) |receiver_type| {
                    if (receiver_type.file_index == decl_file_index) return true;
                }
            },
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            .local_var_decl,
            => {
                const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
                if (resolver.varDeclInitializerReferencesExpectedTypeMethod(full, decl_file_index, normalized_name)) return true;
            },
            else => {},
        }
    }

    return false;
}

const TypeResolver = struct {
    files: []const FileInfo,
    file_index: usize,

    fn currentFile(self: TypeResolver) *const FileInfo {
        return &self.files[self.file_index];
    }

    fn resolveExprType(self: TypeResolver, node: usize) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const name = identifierName(tree, node) orelse return null;
                return self.resolveNameType(name, node);
            },
            .field_access => {
                const datas = tree.nodes.items(.data);
                const field_access = datas[node].node_and_token;
                const lhs = @intFromEnum(field_access[0]);
                const member_name = normalizeIdentifier(tree.tokenSlice(field_access[1]));
                const base_type = self.resolveExprType(lhs) orelse return null;
                return self.resolveMemberType(base_type, member_name);
            },
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => return self.resolveCallType(@intCast(node)),
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => return self.resolveStructInitType(@intCast(node)),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => return self.resolveBuiltinType(@intCast(node)),
            else => return null,
        }
    }

    fn resolveTypeNode(self: TypeResolver, node: usize) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const name = identifierName(tree, node) orelse return null;
                return self.resolveNameType(name, node);
            },
            .field_access => {
                const datas = tree.nodes.items(.data);
                const field_access = datas[node].node_and_token;
                const lhs = @intFromEnum(field_access[0]);
                const member_name = normalizeIdentifier(tree.tokenSlice(field_access[1]));
                const base_type = self.resolveTypeNode(lhs) orelse self.resolveExprType(lhs) orelse return null;
                return self.resolveMemberType(base_type, member_name);
            },
            .ptr_type,
            .ptr_type_aligned,
            .ptr_type_bit_range,
            .ptr_type_sentinel,
            => {
                const ptr = tree.fullPtrType(@enumFromInt(node)) orelse return null;
                return self.resolveTypeNode(@intFromEnum(ptr.ast.child_type));
            },
            .optional_type => return self.resolveTypeNode(@intFromEnum(tree.nodes.items(.data)[node].node)),
            .error_union => return self.resolveTypeNode(@intFromEnum(tree.nodes.items(.data)[node].node_and_node[1])),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => return self.resolveBuiltinType(@intCast(node)),
            else => return null,
        }
    }

    fn resolveNameType(self: TypeResolver, name: []const u8, reference_node: usize) ?ResolvedType {
        if (self.resolveNearestBindingType(name, reference_node)) |resolved| return resolved;
        if (self.resolveNamedDeclType(self.file_index, name)) |resolved| return resolved;
        if (std.mem.eql(u8, name, fileStem(self.currentFile().path))) {
            return .{ .file_index = self.file_index };
        }
        return null;
    }

    fn resolveNearestBindingType(self: TypeResolver, name: []const u8, reference_node: usize) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        const reference_start = nodeStart(tree, reference_node) orelse return null;

        var best_start: usize = 0;
        var best_type: ?ResolvedType = null;

        for (tags, 0..) |tag, node_index| {
            switch (tag) {
                .simple_var_decl,
                .aligned_var_decl,
                .global_var_decl,
                .local_var_decl,
                => {
                    const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
                    const name_token = full.ast.mut_token + 1;
                    if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
                    const decl_name = normalizeIdentifier(tree.tokenSlice(name_token));
                    if (!std.mem.eql(u8, decl_name, name)) continue;

                    const start = tree.tokens.items(.start)[name_token];
                    if (start > reference_start or start < best_start) continue;
                    if (self.resolveVarDeclType(full, node_index, decl_name)) |resolved| {
                        best_start = start;
                        best_type = resolved;
                    }
                },
                .fn_decl,
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => {
                    if (self.resolveFnParamBindingType(@intCast(node_index), name, reference_start, &best_start)) |resolved| {
                        best_type = resolved;
                    }
                },
                else => {},
            }
        }

        return best_type;
    }

    fn resolveFnParamBindingType(
        self: TypeResolver,
        node: u32,
        name: []const u8,
        reference_start: usize,
        best_start: *usize,
    ) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        if (tags[node] == .fn_decl) {
            const proto_node = @intFromEnum(tree.nodes.items(.data)[node].node_and_node[0]);
            return self.resolveFnParamBindingType(@intCast(proto_node), name, reference_start, best_start);
        }

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[node]) {
            .fn_proto => tree.fnProto(@enumFromInt(node)),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(node)),
            .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(node)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(node)),
            else => return null,
        };

        var best_type: ?ResolvedType = null;
        for (proto.ast.params) |param_node| {
            const param_index = @intFromEnum(param_node);
            if (param_index >= tags.len) continue;

            if (isVarDeclTag(tags[param_index])) {
                const full = tree.fullVarDecl(param_node) orelse continue;
                const name_token = full.ast.mut_token + 1;
                if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
                const param_name = normalizeIdentifier(tree.tokenSlice(name_token));
                if (!std.mem.eql(u8, param_name, name)) continue;

                const start = tree.tokens.items(.start)[name_token];
                if (start > reference_start or start < best_start.*) continue;
                if (self.resolveVarDeclType(full, param_index, param_name)) |resolved| {
                    best_start.* = start;
                    best_type = resolved;
                }
                continue;
            }

            const name_token = paramNameTokenBeforeType(tree, param_index) orelse continue;
            const param_name = normalizeIdentifier(tree.tokenSlice(@intCast(name_token)));
            if (!std.mem.eql(u8, param_name, name)) continue;

            const start = tree.tokens.items(.start)[name_token];
            if (start > reference_start or start < best_start.*) continue;
            if (self.resolveTypeNode(param_index)) |resolved| {
                best_start.* = start;
                best_type = resolved;
            }
        }
        return best_type;
    }

    fn varDeclInitializerReferencesExpectedTypeMethod(
        self: TypeResolver,
        full: std.zig.Ast.full.VarDecl,
        decl_file_index: usize,
        method_name: []const u8,
    ) bool {
        const type_node = full.ast.type_node.unwrap() orelse return false;
        const expected_type = self.resolveTypeNode(@intFromEnum(type_node)) orelse return false;
        if (expected_type.file_index != decl_file_index) return false;
        if (expected_type.type_name != null) return false;

        const init_node = full.ast.init_node.unwrap() orelse return false;
        return self.initializerReferencesExpectedTypeMethod(@intFromEnum(init_node), method_name);
    }

    fn resolveVarDeclType(
        self: TypeResolver,
        full: std.zig.Ast.full.VarDecl,
        node_index: usize,
        decl_name: []const u8,
    ) ?ResolvedType {
        if (full.ast.type_node.unwrap()) |type_node| {
            if (self.resolveTypeNode(@intFromEnum(type_node))) |resolved| return resolved;
        }

        const init_node = full.ast.init_node.unwrap() orelse return null;
        const init_index = @intFromEnum(init_node);
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (init_index >= tags.len) return null;
        if (isBuiltinCallTag(tags[init_index])) {
            return self.resolveBuiltinType(@intCast(init_index));
        }
        if (isContainerTag(tags[init_index])) {
            return .{ .file_index = self.file_index, .type_name = decl_name };
        }
        if (isRootDeclNode(tree, node_index)) return null;
        return self.resolveInitializerType(init_index);
    }

    fn resolveInitializerType(self: TypeResolver, node: usize) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        return switch (tags[node]) {
            .call, .call_comma, .call_one, .call_one_comma => self.resolveCallType(@intCast(node)),
            .@"try",
            .address_of,
            .deref,
            .optional_type,
            => self.resolveInitializerType(@intFromEnum(tree.nodes.items(.data)[node].node)),
            .grouped_expression,
            .unwrap_optional,
            => self.resolveInitializerType(@intFromEnum(tree.nodes.items(.data)[node].node_and_token[0])),
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => self.resolveStructInitType(@intCast(node)),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => self.resolveBuiltinType(@intCast(node)),
            else => null,
        };
    }

    fn initializerReferencesExpectedTypeMethod(
        self: TypeResolver,
        node: usize,
        method_name: []const u8,
    ) bool {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return false;

        return switch (tags[node]) {
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => self.callUsesImplicitResultMethod(@intCast(node), method_name),
            .@"try",
            .address_of,
            .deref,
            .optional_type,
            => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node), method_name),
            .grouped_expression,
            .unwrap_optional,
            => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node_and_token[0]), method_name),
            .@"catch" => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node_and_node[0]), method_name),
            else => false,
        };
    }

    fn callUsesImplicitResultMethod(self: TypeResolver, node: u32, method_name: []const u8) bool {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return false;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, @enumFromInt(node)) orelse return false;
        const callee = @intFromEnum(call.ast.fn_expr);
        if (callee >= tags.len or tags[callee] != .enum_literal) return false;

        const token = tree.nodes.items(.main_token)[callee];
        if (token >= tree.tokens.len) return false;
        return std.mem.eql(u8, normalizeIdentifier(tree.tokenSlice(token)), method_name);
    }

    fn resolveCallType(self: TypeResolver, node: u32) ?ResolvedType {
        const tree = &self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, @enumFromInt(node)) orelse return null;
        const callee = @intFromEnum(call.ast.fn_expr);
        if (callee >= tags.len) return null;
        if (tags[callee] == .field_access) {
            const lhs = @intFromEnum(tree.nodes.items(.data)[callee].node_and_token[0]);
            return self.resolveTypeNode(lhs) orelse self.resolveExprType(lhs);
        }
        return null;
    }

    fn resolveStructInitType(self: TypeResolver, node: u32) ?ResolvedType {
        const tree = &self.currentFile().tree;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, @enumFromInt(node)) orelse return null;
        const type_node = init.ast.type_expr.unwrap() orelse return null;
        return self.resolveTypeNode(@intFromEnum(type_node));
    }

    fn resolveBuiltinType(self: TypeResolver, node: u32) ?ResolvedType {
        const tree = &self.currentFile().tree;
        if (importPathFromBuiltinCall(tree, node)) |import_path| {
            if (resolveImportToFileIndex(self.files, self.currentFile().path, import_path)) |file_index| {
                return .{ .file_index = file_index };
            }
        }
        if (isThisBuiltinCall(tree, node)) {
            return .{ .file_index = self.file_index };
        }
        return null;
    }

    fn resolveMemberType(self: TypeResolver, base_type: ResolvedType, member_name: []const u8) ?ResolvedType {
        const member_resolver = TypeResolver{
            .files = self.files,
            .file_index = base_type.file_index,
        };
        if (member_resolver.resolveNamedDeclType(base_type.file_index, member_name)) |resolved| return resolved;
        return member_resolver.resolveFieldType(base_type, member_name);
    }

    fn resolveNamedDeclType(self: TypeResolver, file_index: usize, name: []const u8) ?ResolvedType {
        const file = &self.files[file_index];
        const tree = &file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len or !isVarDeclTag(tags[node_index])) continue;
            const full = tree.fullVarDecl(decl_idx) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
            const decl_name = normalizeIdentifier(tree.tokenSlice(name_token));
            if (!std.mem.eql(u8, decl_name, name)) continue;

            const nested_resolver = TypeResolver{ .files = self.files, .file_index = file_index };
            if (nested_resolver.resolveVarDeclType(full, node_index, decl_name)) |resolved| return resolved;
        }
        return null;
    }

    fn resolveFieldType(self: TypeResolver, base_type: ResolvedType, field_name: []const u8) ?ResolvedType {
        if (base_type.type_name) |container_name| {
            if (self.findNamedContainerNode(base_type.file_index, container_name)) |container_node| {
                return self.resolveContainerFieldType(base_type.file_index, container_node, field_name);
            }
        }
        return self.resolveRootFieldType(base_type.file_index, field_name);
    }

    fn findNamedContainerNode(self: TypeResolver, file_index: usize, name: []const u8) ?u32 {
        const file = &self.files[file_index];
        const tree = &file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len or !isVarDeclTag(tags[node_index])) continue;
            const full = tree.fullVarDecl(decl_idx) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
            if (!std.mem.eql(u8, normalizeIdentifier(tree.tokenSlice(name_token)), name)) continue;
            const init_node = full.ast.init_node.unwrap() orelse continue;
            const init_index = @intFromEnum(init_node);
            if (init_index < tags.len and isContainerTag(tags[init_index])) return @intCast(init_index);
        }
        return null;
    }

    fn resolveRootFieldType(self: TypeResolver, file_index: usize, field_name: []const u8) ?ResolvedType {
        const file = &self.files[file_index];
        const tree = &file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len) continue;
            switch (tags[node_index]) {
                .container_field,
                .container_field_init,
                .container_field_align,
                => if (self.resolveContainerFieldNodeType(file_index, @intCast(node_index), field_name)) |resolved| return resolved,
                else => {},
            }
        }
        return null;
    }

    fn resolveContainerFieldType(self: TypeResolver, file_index: usize, container_node: u32, field_name: []const u8) ?ResolvedType {
        const file = &self.files[file_index];
        const tree = &file.tree;

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, @enumFromInt(container_node)) orelse return null;
        for (container.ast.members) |member_node| {
            const member = @intFromEnum(member_node);
            if (self.resolveContainerFieldNodeType(file_index, @intCast(member), field_name)) |resolved| return resolved;
        }
        return null;
    }

    fn resolveContainerFieldNodeType(self: TypeResolver, file_index: usize, node: u32, field_name: []const u8) ?ResolvedType {
        const file = &self.files[file_index];
        const tree = &file.tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        const field = tree.fullContainerField(@enumFromInt(node)) orelse return null;
        if (field.ast.tuple_like) return null;
        const name_token = field.ast.main_token;
        if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) return null;
        if (!std.mem.eql(u8, normalizeIdentifier(tree.tokenSlice(name_token)), field_name)) return null;

        const nested_resolver = TypeResolver{ .files = self.files, .file_index = file_index };
        if (field.ast.type_expr.unwrap()) |type_node| {
            return nested_resolver.resolveTypeNode(@intFromEnum(type_node));
        }
        if (field.ast.value_expr.unwrap()) |value_node| {
            return nested_resolver.resolveInitializerType(@intFromEnum(value_node));
        }
        return null;
    }
};

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
    files: []const FileInfo,
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
        if (resolveImportToFileIndex(files, importer_path, import_path)) |file_index| {
            if (filePubliclyImportsPath(files, &files[file_index], target_path)) return true;
        }
    }

    return false;
}

fn publicUsingnamespaceImportsPath(
    files: []const FileInfo,
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
        if (resolveImportToFileIndex(files, importer_path, import_path)) |file_index| {
            if (filePubliclyImportsPath(files, &files[file_index], target_path)) return true;
        }
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

fn paramNameTokenBeforeType(tree: *const std.zig.Ast, type_node: usize) ?usize {
    const main_tokens = tree.nodes.items(.main_token);
    if (type_node >= main_tokens.len) return null;
    const token_tags = tree.tokens.items(.tag);
    const type_token = main_tokens[type_node];
    const colon_token = prevNonCommentToken(token_tags, type_token) orelse return null;
    if (token_tags[colon_token] != .colon) return null;
    const name_token = prevNonCommentToken(token_tags, colon_token) orelse return null;
    if (token_tags[name_token] != .identifier) return null;
    return name_token;
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

fn resolveImportToFileIndex(files: []const FileInfo, importer_path: []const u8, import_path: []const u8) ?usize {
    for (files, 0..) |file, file_index| {
        if (importMayResolveToPath(importer_path, import_path, file.path)) return file_index;
    }
    return null;
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

fn nodeStart(tree: *const std.zig.Ast, node: usize) ?usize {
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return null;
    const token = main_tokens[node];
    if (token >= tree.tokens.len) return null;
    return tree.tokens.items(.start)[token];
}

fn isThisBuiltinCall(tree: *const std.zig.Ast, node: usize) bool {
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return false;
    const token = main_tokens[node];
    if (token >= tree.tokens.len) return false;
    return std.mem.eql(u8, tree.tokenSlice(token), "@This");
}

fn fileStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, ".zig")) return basename[0 .. basename.len - ".zig".len];
    return basename;
}

fn isIgnoredPublicDecl(path: []const u8, name: []const u8) bool {
    if (isSpecialName(name)) return true;
    return std.mem.eql(u8, std.fs.path.basename(path), "build.zig") and std.mem.eql(u8, name, "build");
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

test "project unused declarations ignore Zig build entrypoint" {
    try std.testing.expect(isIgnoredPublicDecl("build.zig", "build"));
    try std.testing.expect(isIgnoredPublicDecl("workspace/build.zig", "build"));
    try std.testing.expect(!isIgnoredPublicDecl("src/lib.zig", "build"));
    try std.testing.expect(!isIgnoredPublicDecl("build.zig", "helper"));
}
