const std = @import("std");
const ir = @import("ir.zig");
const diagnostic = @import("diagnostic.zig");
const Source = @import("source.zig").Source;

pub const IrNode = ir.IrNode;
pub const IrTag = ir.IrTag;
pub const SourceRange = diagnostic.SourceRange;
pub const Location = diagnostic.Location;

/// Edge kind for CFG edges.
pub const EdgeKind = enum {
    /// Normal sequential control flow
    normal,
    /// Unconditional jump (e.g., from return)
    jump,
};

/// An edge in the control-flow graph.
pub const CfgEdge = struct {
    /// Source node index
    from: u32,
    /// Destination node index
    to: u32,
    /// Kind of edge
    kind: EdgeKind,

    pub fn init(from: u32, to: u32) CfgEdge {
        return .{
            .from = from,
            .to = to,
            .kind = .normal,
        };
    }

    pub fn initWithKind(from: u32, to: u32, kind: EdgeKind) CfgEdge {
        return .{
            .from = from,
            .to = to,
            .kind = kind,
        };
    }
};

/// A node in the control-flow graph.
pub const CfgNode = struct {
    /// The IR node at this CFG point
    ir_node: IrNode,
    /// Unique index of this node in the CFG
    index: u32,
};

/// A control-flow graph for a single function.
pub const Cfg = struct {
    allocator: std.mem.Allocator,
    /// All nodes in the CFG
    nodes: std.ArrayList(CfgNode),
    /// All edges in the CFG
    edges: std.ArrayList(CfgEdge),
    /// Index of the entry node (always 0)
    entry: u32,
    /// Index of the exit node
    exit: u32,
    /// Function name (if available)
    fn_name: ?[]const u8,
    /// AST node index of the function
    fn_ast_node: ?u32,

    pub fn init(allocator: std.mem.Allocator) Cfg {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .edges = .empty,
            .entry = 0,
            .exit = 0,
            .fn_name = null,
            .fn_ast_node = null,
        };
    }

    pub fn deinit(self: *Cfg) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }

    pub fn addNode(self: *Cfg, ir_node: IrNode) !u32 {
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .ir_node = ir_node,
            .index = index,
        });
        return index;
    }

    pub fn addEdge(self: *Cfg, from: u32, to: u32) !void {
        try self.edges.append(self.allocator, CfgEdge.init(from, to));
    }

    pub fn addEdgeWithKind(self: *Cfg, from: u32, to: u32, kind: EdgeKind) !void {
        try self.edges.append(self.allocator, CfgEdge.initWithKind(from, to, kind));
    }

    pub fn nodeCount(self: *const Cfg) usize {
        return self.nodes.items.len;
    }

    pub fn edgeCount(self: *const Cfg) usize {
        return self.edges.items.len;
    }

    pub fn getNode(self: *const Cfg, index: u32) ?*const CfgNode {
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    pub fn getSuccessors(self: *const Cfg, node_index: u32, result: *std.ArrayList(u32)) !void {
        for (self.edges.items) |edge| {
            if (edge.from == node_index) {
                try result.append(self.allocator, edge.to);
            }
        }
    }

    pub fn getPredecessors(self: *const Cfg, node_index: u32, result: *std.ArrayList(u32)) !void {
        for (self.edges.items) |edge| {
            if (edge.to == node_index) {
                try result.append(self.allocator, edge.from);
            }
        }
    }
};

/// Builds CFG from a Zig AST for a single function.
pub const CfgBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CfgBuilder {
        return .{ .allocator = allocator };
    }

    /// Build CFG for a function body starting at the given AST node.
    /// Returns null if the node is not a function or cannot be processed.
    pub fn buildFromFn(self: *CfgBuilder, source: *Source, fn_node: u32) !?Cfg {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);

        if (fn_node >= tags.len) return null;

        const tag = tags[fn_node];
        if (tag != .fn_decl) return null;

        var cfg = Cfg.init(self.allocator);
        errdefer cfg.deinit();

        cfg.fn_ast_node = fn_node;

        const entry_idx = try cfg.addNode(IrNode.init(.fn_entry));
        cfg.entry = entry_idx;

        const exit_idx = try cfg.addNode(IrNode.init(.fn_exit));
        cfg.exit = exit_idx;

        const fn_data = tree.nodes.items(.data)[fn_node];
        const body_node = fn_data.rhs;

        if (body_node == 0) {
            try cfg.addEdge(entry_idx, exit_idx);
            return cfg;
        }

        const last_node = try self.processNode(&cfg, source, body_node, entry_idx);
        if (last_node) |ln| {
            if (!self.isTerminator(&cfg, ln)) {
                try cfg.addEdge(ln, exit_idx);
            }
        } else {
            try cfg.addEdge(entry_idx, exit_idx);
        }

        return cfg;
    }

    fn isTerminator(self: *CfgBuilder, cfg: *const Cfg, node_idx: u32) bool {
        _ = self;
        if (cfg.getNode(node_idx)) |node| {
            return node.ir_node.tag == .ret;
        }
        return false;
    }

    fn processNode(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);

        if (ast_node == 0 or ast_node >= tags.len) {
            return null;
        }

        const tag = tags[ast_node];

        return switch (tag) {
            .block, .block_two, .block_two_semicolon => try self.processBlock(cfg, source, ast_node, prev_node),
            .@"return" => try self.processReturn(cfg, source, ast_node, prev_node),
            .simple_var_decl => try self.processVarDecl(cfg, source, ast_node, prev_node),
            .assign => try self.processAssign(cfg, source, ast_node, prev_node),
            .call, .call_one, .call_one_comma, .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => try self.processCall(cfg, source, ast_node, prev_node),
            else => try self.processGenericExpr(cfg, source, ast_node, prev_node),
        };
    }

    fn processBlock(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const tag = tags[ast_node];

        var stmts: []const u32 = &[_]u32{};
        var inline_stmts: [2]u32 = undefined;

        switch (tag) {
            .block, .block_two, .block_two_semicolon => {
                if (tag == .block) {
                    const extra_idx = data[ast_node].lhs;
                    const len = data[ast_node].rhs;
                    if (len > 0) {
                        stmts = tree.extra_data[extra_idx..][0..len];
                    }
                } else {
                    var count: usize = 0;
                    if (data[ast_node].lhs != 0) {
                        inline_stmts[count] = data[ast_node].lhs;
                        count += 1;
                    }
                    if (data[ast_node].rhs != 0) {
                        inline_stmts[count] = data[ast_node].rhs;
                        count += 1;
                    }
                    stmts = inline_stmts[0..count];
                }
            },
            else => return null,
        }

        if (stmts.len == 0) {
            const block_node_idx = try cfg.addNode(IrNode.initWithAst(.block, ast_node));
            try cfg.addEdge(prev_node, block_node_idx);
            return block_node_idx;
        }

        var current_prev = prev_node;
        var last_processed: ?u32 = null;

        for (stmts) |stmt| {
            const result = try self.processNode(cfg, source, stmt, current_prev);
            if (result) |node_idx| {
                last_processed = node_idx;
                current_prev = node_idx;

                if (self.isTerminator(cfg, node_idx)) {
                    break;
                }
            }
        }

        return last_processed;
    }

    fn processReturn(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const ret_node = try cfg.addNode(IrNode.initFull(.ret, ast_node, range));
        try cfg.addEdge(prev_node, ret_node);
        try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);
        return ret_node;
    }

    fn processVarDecl(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const decl_node = try cfg.addNode(IrNode.initFull(.var_decl, ast_node, range));
        try cfg.addEdge(prev_node, decl_node);
        return decl_node;
    }

    fn processAssign(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const assign_node = try cfg.addNode(IrNode.initFull(.assign, ast_node, range));
        try cfg.addEdge(prev_node, assign_node);
        return assign_node;
    }

    fn processCall(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const call_node = try cfg.addNode(IrNode.initFull(.call, ast_node, range));
        try cfg.addEdge(prev_node, call_node);
        return call_node;
    }

    fn processGenericExpr(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: u32,
    ) !?u32 {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const expr_node = try cfg.addNode(IrNode.initFull(.expr, ast_node, range));
        try cfg.addEdge(prev_node, expr_node);
        return expr_node;
    }
};

fn getSourceRange(source: *Source, ast_node: u32) !SourceRange {
    const tree = try source.ast();
    const token_starts = tree.tokens.items(.start);
    const main_tokens = tree.nodes.items(.main_token);

    if (ast_node >= main_tokens.len) {
        return SourceRange.fromSingleLocation(Location.init(1, 1));
    }

    const main_token = main_tokens[ast_node];
    if (main_token >= token_starts.len) {
        return SourceRange.fromSingleLocation(Location.init(1, 1));
    }

    const start_byte = token_starts[main_token];
    return source.byteRangeToSourceRange(start_byte, start_byte + 1);
}

test "Cfg basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    try testing.expectEqual(@as(u32, 0), entry);
    try testing.expectEqual(@as(usize, 1), cfg.nodeCount());

    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    try testing.expectEqual(@as(u32, 1), exit);

    try cfg.addEdge(entry, exit);
    try testing.expectEqual(@as(usize, 1), cfg.edgeCount());

    if (cfg.getNode(entry)) |node| {
        try testing.expectEqual(IrTag.fn_entry, node.ir_node.tag);
    } else {
        return error.TestExpectedEqual;
    }
}

test "Cfg successors and predecessors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const n0 = try cfg.addNode(IrNode.init(.fn_entry));
    const n1 = try cfg.addNode(IrNode.init(.var_decl));
    const n2 = try cfg.addNode(IrNode.init(.fn_exit));

    try cfg.addEdge(n0, n1);
    try cfg.addEdge(n1, n2);

    var succs: std.ArrayList(u32) = .empty;
    defer succs.deinit(allocator);

    try cfg.getSuccessors(n0, &succs);
    try testing.expectEqual(@as(usize, 1), succs.items.len);
    try testing.expectEqual(n1, succs.items[0]);

    succs.clearRetainingCapacity();
    try cfg.getSuccessors(n1, &succs);
    try testing.expectEqual(@as(usize, 1), succs.items.len);
    try testing.expectEqual(n2, succs.items[0]);

    var preds: std.ArrayList(u32) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(n2, &preds);
    try testing.expectEqual(@as(usize, 1), preds.items.len);
    try testing.expectEqual(n1, preds.items[0]);
}

test "CfgBuilder empty function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    try testing.expect(root_decls.len > 0);

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.nodeCount());
    try testing.expectEqual(@as(usize, 1), cfg.edgeCount());

    if (cfg.getNode(cfg.entry)) |entry| {
        try testing.expectEqual(IrTag.fn_entry, entry.ir_node.tag);
    }
    if (cfg.getNode(cfg.exit)) |exit| {
        try testing.expectEqual(IrTag.fn_exit, exit.ir_node.tag);
    }
}

test "CfgBuilder simple return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 3), cfg.nodeCount());

    var found_return = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) {
            found_return = true;
            break;
        }
    }
    try testing.expect(found_return);
}

test "CfgBuilder var decl and return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    const x = 10;
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 4), cfg.nodeCount());

    var found_var_decl = false;
    var found_return = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) found_var_decl = true;
        if (node.ir_node.tag == .ret) found_return = true;
    }
    try testing.expect(found_var_decl);
    try testing.expect(found_return);
}

test "CfgBuilder source range mapping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) {
            try testing.expect(node.ir_node.source_range != null);
            const range = node.ir_node.source_range.?;
            try testing.expectEqual(@as(usize, 2), range.start.line);
            break;
        }
    }
}

test "CfgBuilder non-function node returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const x = 42;
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    if (root_decls.len > 0) {
        const var_node = root_decls[0];
        const maybe_cfg = try builder.buildFromFn(&source, var_node);
        try testing.expect(maybe_cfg == null);
    }
}

test "CfgBuilder multiple statements" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    const a = 1;
        \\    const b = 2;
        \\    const c = 3;
        \\    return a + b + c;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 6), cfg.nodeCount());

    var var_decl_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) var_decl_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), var_decl_count);
}

test "CfgBuilder return terminates block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 1;
        \\    const x = 2;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = root_decls[0];
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 3), cfg.nodeCount());

    var found_var_decl = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) found_var_decl = true;
    }
    try testing.expect(!found_var_decl);
}
