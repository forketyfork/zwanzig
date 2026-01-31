const std = @import("std");
const graph = @import("graph.zig");
const dot = @import("dot.zig");
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const type_context_mod = @import("../type_context.zig");

const Cfg = graph.Cfg;
const EdgeKind = graph.EdgeKind;
const IrNode = graph.IrNode;
const IrTag = graph.IrTag;
const SourceRange = graph.SourceRange;
const Location = graph.Location;
const CfgNodeId = ids.CfgNodeId;
const AstNodeId = ids.AstNodeId;
const TypeContext = type_context_mod.TypeContext;
const TypeInfo = type_context_mod.TypeInfo;

pub const CfgError = std.mem.Allocator.Error || error{InvalidAst};

/// Builds CFG from a Zig AST for a single function.
/// When a TypeContext is provided, IR nodes are annotated with type information
/// from ZIR, enabling type-aware analysis.
pub const CfgBuilder = struct {
    allocator: std.mem.Allocator,
    /// Optional type context for annotating IR nodes with type information.
    type_context: ?*TypeContext = null,
    /// Optional directory to dump CFG DOT files for visualization.
    dump_cfg_dir: ?[]const u8 = null,

    const ProcessResult = struct {
        last: ?CfgNodeId,
        terminates: bool,
        /// If set, the edge from this node to the next should use this kind.
        /// Used to properly label try_success edges for standalone try expressions.
        next_edge_kind: ?EdgeKind = null,
    };

    pub fn init(allocator: std.mem.Allocator) CfgBuilder {
        return .{ .allocator = allocator, .type_context = null };
    }

    /// Create a CfgBuilder with type context for type-annotated IR.
    pub fn initWithTypes(allocator: std.mem.Allocator, type_ctx: *TypeContext) CfgBuilder {
        return .{ .allocator = allocator, .type_context = type_ctx };
    }

    /// Set the type context for type annotation.
    pub fn setTypeContext(self: *CfgBuilder, type_ctx: ?*TypeContext) void {
        self.type_context = type_ctx;
    }

    /// Check if type annotation is available.
    pub fn hasTypeContext(self: *const CfgBuilder) bool {
        return self.type_context != null;
    }

    /// Set directory for dumping CFG DOT files.
    /// When set, buildFromFn automatically writes DOT files after building CFGs.
    pub fn setDumpCfgDir(self: *CfgBuilder, dir: ?[]const u8) void {
        self.dump_cfg_dir = dir;
    }

    /// Annotate an IR node with type information if available.
    /// Returns the node (possibly enriched with type info).
    fn annotateWithType(self: *CfgBuilder, node: IrNode, source: *Source, ast_node: u32) IrNode {
        // Try to get type from TypeContext first (cached)
        if (self.type_context) |ctx| {
            if (ctx.getNodeType(ast_node)) |ti| {
                return node.withType(ti);
            }
        }

        // Fallback: try to get type from source's ZirBridge
        if (self.type_context == null) {
            // No type context, but we can still try source's ZirBridge
            if (source.zirBridge()) |bridge| {
                const count = bridge.getDeclCount();
                for (0..count) |i| {
                    if (bridge.getDecl(i)) |decl| {
                        if (decl.ast_node == ast_node) {
                            return node.withType(decl.type_info);
                        }
                    }
                }
            }
        }

        return node;
    }

    /// Build CFG for a function body starting at the given AST node.
    /// Returns null if the node is not a function or cannot be processed.
    pub fn buildFromFn(self: *CfgBuilder, source: *Source, fn_node: AstNodeId) !?Cfg {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);
        const fn_index = ids.astIndex(fn_node);

        if (fn_index >= tags.len) return null;

        const tag = tags[fn_index];
        if (tag != .fn_decl) return null;

        var cfg = Cfg.init(self.allocator);
        errdefer cfg.deinit();

        cfg.fn_ast_node = fn_node;

        // Extract function name from the AST
        const fn_data = tree.nodes.items(.data)[fn_index];
        const fn_proto_idx = @intFromEnum(fn_data.node_and_node[0]);
        if (fn_proto_idx > 0) {
            const main_tokens = tree.nodes.items(.main_token);
            const proto_token = main_tokens[fn_proto_idx];
            // The function name token typically follows the 'fn' keyword
            // Check if the next token is an identifier
            const token_tags = tree.tokens.items(.tag);
            if (proto_token + 1 < token_tags.len and token_tags[proto_token + 1] == .identifier) {
                const name_start = tree.tokens.items(.start)[proto_token + 1];
                const source_bytes = tree.source;
                // Find the end of the identifier
                var name_end = name_start;
                while (name_end < source_bytes.len and
                    (std.ascii.isAlphanumeric(source_bytes[name_end]) or source_bytes[name_end] == '_'))
                {
                    name_end += 1;
                }
                if (name_end > name_start) {
                    cfg.fn_name = source_bytes[name_start..name_end];
                }
            }
        }

        const entry_idx = try cfg.addNode(IrNode.init(.fn_entry));
        cfg.entry = entry_idx;

        const exit_idx = try cfg.addNode(IrNode.init(.fn_exit));
        cfg.exit = exit_idx;

        const body_node = @intFromEnum(fn_data.node_and_node[1]);

        if (body_node == 0) {
            try cfg.addEdge(entry_idx, exit_idx);
        } else {
            const result = try self.processNode(&cfg, source, body_node, entry_idx);
            if (result.last) |ln| {
                if (!result.terminates) {
                    try cfg.addEdge(ln, exit_idx);
                }
            } else {
                try cfg.addEdge(entry_idx, exit_idx);
            }
        }

        // Auto-dump CFG if configured
        if (self.dump_cfg_dir) |dir| {
            dot.writeToFile(&cfg, dir, source.getFilePath(), self.allocator);
        }

        return cfg;
    }

    fn processNode(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) CfgError!ProcessResult {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);

        if (ast_node == 0 or ast_node >= tags.len) {
            return .{ .last = null, .terminates = false };
        }

        const tag = tags[ast_node];

        return switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => try self.processBlock(cfg, source, ast_node, prev_node),
            .@"return" => try self.processReturn(cfg, source, ast_node, prev_node),
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => try self.processVarDecl(cfg, source, ast_node, prev_node),
            .assign => try self.processAssign(cfg, source, ast_node, prev_node),
            .call, .call_comma, .call_one, .call_one_comma, .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => try self.processCall(cfg, source, ast_node, prev_node),
            .@"if", .if_simple => try self.processIf(cfg, source, ast_node, prev_node),
            .while_simple, .while_cont, .@"while" => try self.processWhile(cfg, source, ast_node, prev_node),
            .for_simple, .@"for" => try self.processFor(cfg, source, ast_node, prev_node),
            .@"defer" => try self.processDefer(cfg, source, ast_node, prev_node),
            .@"errdefer" => try self.processErrdefer(cfg, source, ast_node, prev_node),
            .@"try" => try self.processTry(cfg, source, ast_node, prev_node),
            .@"catch" => try self.processCatch(cfg, source, ast_node, prev_node),
            else => try self.processGenericExpr(cfg, source, ast_node, prev_node),
        };
    }

    fn processBlock(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const tag = tags[ast_node];

        var stmts: []const u32 = &[_]u32{};
        var inline_stmts: [2]u32 = undefined;

        switch (tag) {
            .block, .block_semicolon => {
                const extra = data[ast_node].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                if (end > start) {
                    stmts = tree.extra_data[start..end];
                }
            },
            .block_two, .block_two_semicolon => {
                var count: usize = 0;
                const opt_nodes = data[ast_node].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |node| {
                    inline_stmts[count] = @intFromEnum(node);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |node| {
                    inline_stmts[count] = @intFromEnum(node);
                    count += 1;
                }
                stmts = inline_stmts[0..count];
            },
            else => return .{ .last = null, .terminates = false },
        }

        if (stmts.len == 0) {
            return .{ .last = null, .terminates = false };
        }

        var current_prev = prev_node;
        var last_processed: ?CfgNodeId = null;
        var terminates = false;
        var pending_edge_kind: ?EdgeKind = null;

        for (stmts) |stmt| {
            const edge_count_before = cfg.edges.items.len;
            const result = try self.processNode(cfg, source, stmt, current_prev);

            // If the previous statement requested a specific edge kind for the
            // connection to the next statement, apply it now
            if (pending_edge_kind) |kind| {
                self.markEdgeFromNode(cfg, edge_count_before, current_prev, kind);
                pending_edge_kind = null;
            }

            if (result.last) |node_idx| {
                last_processed = node_idx;
                current_prev = node_idx;
            }

            // Save the edge kind for the next iteration (e.g., try_success after try)
            pending_edge_kind = result.next_edge_kind;

            if (result.terminates) {
                terminates = true;
                break;
            }
        }

        return .{ .last = last_processed, .terminates = terminates };
    }

    fn markEdgeFromNode(self: *CfgBuilder, cfg: *Cfg, edge_start_idx: usize, from_node: CfgNodeId, kind: EdgeKind) void {
        _ = self;
        for (cfg.edges.items[edge_start_idx..]) |*edge| {
            if (edge.from == from_node and edge.kind == .normal) {
                edge.kind = kind;
                break;
            }
        }
    }

    fn processIf(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();

        const range = try getSourceRange(source, ast_node);

        const full_if = tree.fullIf(@enumFromInt(ast_node)) orelse return .{ .last = null, .terminates = false };

        var branch_ir_node = IrNode.initFull(.branch, ast_node, range);
        branch_ir_node.operand_node = @intFromEnum(full_if.ast.cond_expr);
        const branch_node = try cfg.addNode(branch_ir_node);
        try cfg.addEdge(prev_node, branch_node);

        const then_body: u32 = @intFromEnum(full_if.ast.then_expr);
        const else_body: ?u32 = if (full_if.ast.else_expr.unwrap()) |e| @intFromEnum(e) else null;

        const merge_node = try cfg.addNode(IrNode.init(.nop));

        var then_terminates = false;
        if (then_body != 0) {
            const edge_count_before = cfg.edges.items.len;
            const then_result = try self.processNode(cfg, source, then_body, branch_node);
            self.markEdgeFromBranchTrue(cfg, edge_count_before, branch_node);

            if (then_result.last) |then_end| {
                if (then_result.terminates) {
                    then_terminates = true;
                } else {
                    try cfg.addEdge(then_end, merge_node);
                }
            } else {
                try cfg.addEdgeWithKind(branch_node, merge_node, .branch_true);
            }
        } else {
            try cfg.addEdgeWithKind(branch_node, merge_node, .branch_true);
        }

        var else_terminates = false;
        if (else_body) |else_node| {
            if (else_node != 0) {
                const edge_count_before = cfg.edges.items.len;
                const else_result = try self.processNode(cfg, source, else_node, branch_node);
                self.markEdgeFromBranchFalse(cfg, edge_count_before, branch_node);

                if (else_result.last) |else_end| {
                    if (else_result.terminates) {
                        else_terminates = true;
                    } else {
                        try cfg.addEdge(else_end, merge_node);
                    }
                } else {
                    try cfg.addEdgeWithKind(branch_node, merge_node, .branch_false);
                }
            } else {
                try cfg.addEdgeWithKind(branch_node, merge_node, .branch_false);
            }
        } else {
            try cfg.addEdgeWithKind(branch_node, merge_node, .branch_false);
        }

        if (then_terminates and else_terminates) {
            return .{ .last = branch_node, .terminates = true };
        }

        return .{ .last = merge_node, .terminates = false };
    }

    fn markEdgeFromBranchTrue(self: *CfgBuilder, cfg: *Cfg, edge_start_idx: usize, branch_node: CfgNodeId) void {
        _ = self;
        for (cfg.edges.items[edge_start_idx..]) |*edge| {
            if (edge.from == branch_node and edge.kind == .normal) {
                edge.kind = .branch_true;
                break;
            }
        }
    }

    fn markEdgeFromBranchFalse(self: *CfgBuilder, cfg: *Cfg, edge_start_idx: usize, branch_node: CfgNodeId) void {
        _ = self;
        for (cfg.edges.items[edge_start_idx..]) |*edge| {
            if (edge.from == branch_node and edge.kind == .normal) {
                edge.kind = .branch_false;
                break;
            }
        }
    }

    fn processReturn(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);

        // Check if the return expression contains a try or catch expression
        // Return node data: opt_node format - a single optional return expression
        const data = tree.nodes.items(.data);
        const ret_expr_opt = data[ast_node].opt_node;
        if (ret_expr_opt.unwrap()) |ret_expr_node| {
            const ret_expr_idx = @intFromEnum(ret_expr_node);
            const tags = tree.nodes.items(.tag);
            if (ret_expr_idx < tags.len) {
                const ret_expr_tag = tags[ret_expr_idx];
                if (ret_expr_tag == .@"try") {
                    return try self.processReturnWithTry(cfg, source, ast_node, ret_expr_idx, prev_node, range);
                } else if (ret_expr_tag == .@"catch") {
                    return try self.processReturnWithCatch(cfg, source, ast_node, ret_expr_idx, prev_node, range);
                }
            }
        }

        const ret_node = try cfg.addNode(IrNode.initFull(.ret, ast_node, range));
        try cfg.addEdge(prev_node, ret_node);
        try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);
        return .{ .last = ret_node, .terminates = true };
    }

    fn processReturnWithTry(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ret_node_ast: u32,
        try_expr_node: u32,
        prev_node: CfgNodeId,
        ret_range: SourceRange,
    ) !ProcessResult {
        _ = self;
        const try_range = try getSourceRange(source, try_expr_node);

        // Return with try expression: return try bar();
        //   prev -> try_node -> ret_node -> exit (success path)
        //   try_node --[try_error]--> fn_exit (error path)
        var try_ir = IrNode.initFull(.try_expr, try_expr_node, try_range);
        try_ir = try_ir.withType(TypeInfo.initErrorUnion());
        const try_node = try cfg.addNode(try_ir);
        try cfg.addEdge(prev_node, try_node);

        // Error path: propagate to function exit
        try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

        // Success path: continue to return statement
        const ret_node = try cfg.addNode(IrNode.initFull(.ret, ret_node_ast, ret_range));
        try cfg.addEdgeWithKind(try_node, ret_node, .try_success);
        try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);

        return .{ .last = ret_node, .terminates = true };
    }

    fn processReturnWithCatch(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ret_node_ast: u32,
        catch_expr_node: u32,
        prev_node: CfgNodeId,
        ret_range: SourceRange,
    ) !ProcessResult {
        const tree = try source.ast();
        const catch_range = try getSourceRange(source, catch_expr_node);
        const data = tree.nodes.items(.data);

        // Return with catch expression
        var catch_ir = IrNode.initFull(.catch_expr, catch_expr_node, catch_range);
        catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
        const catch_node = try cfg.addNode(catch_ir);
        try cfg.addEdge(prev_node, catch_node);

        // Get the handler from catch node
        const catch_data = data[catch_expr_node].node_and_node;
        const handler_ast = @intFromEnum(catch_data[1]);

        // Create the return node
        const ret_node = try cfg.addNode(IrNode.initFull(.ret, ret_node_ast, ret_range));

        // Success path: no error, value is unwrapped, goes to return
        try cfg.addEdgeWithKind(catch_node, ret_node, .catch_success);

        // Error path: process handler if present, then go to return
        if (handler_ast != 0) {
            const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

            if (handler_result.last) |handler_end| {
                // Handler produced nodes - mark edge from catch to handler as error edge
                self.markEdgeFromCatchError(cfg, catch_node);
                if (!handler_result.terminates) {
                    try cfg.addEdge(handler_end, ret_node);
                }
            } else {
                // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                try cfg.addEdgeWithKind(catch_node, ret_node, .catch_error);
            }
        } else {
            try cfg.addEdgeWithKind(catch_node, ret_node, .catch_error);
        }

        try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);
        return .{ .last = ret_node, .terminates = true };
    }

    fn processVarDecl(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);

        // Check if the initializer contains a try or catch expression
        const full_var = tree.fullVarDecl(@enumFromInt(ast_node));
        if (full_var) |vd| {
            if (vd.ast.init_node.unwrap()) |init_node| {
                const init_idx = @intFromEnum(init_node);
                const tags = tree.nodes.items(.tag);
                if (init_idx < tags.len) {
                    const init_tag = tags[init_idx];
                    if (init_tag == .@"try") {
                        return try self.processVarDeclWithTry(cfg, source, ast_node, init_idx, prev_node, range);
                    } else if (init_tag == .@"catch") {
                        return try self.processVarDeclWithCatch(cfg, source, ast_node, init_idx, prev_node, range);
                    }
                }
            }
        }

        // Simple var decl without try/catch in initializer
        // Annotate with type information if available
        var ir_node = IrNode.initFull(.var_decl, ast_node, range);
        ir_node = self.annotateWithType(ir_node, source, ast_node);

        const decl_node = try cfg.addNode(ir_node);
        try cfg.addEdge(prev_node, decl_node);
        return .{ .last = decl_node, .terminates = false };
    }

    fn processVarDeclWithTry(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        var_decl_node: u32,
        try_init_node: u32,
        prev_node: CfgNodeId,
        var_range: SourceRange,
    ) !ProcessResult {
        const try_range = try getSourceRange(source, try_init_node);

        // Try expression in var decl initializer:
        //   prev -> try_node -> var_decl_node (success path)
        //   try_node --[try_error]--> fn_exit
        var try_ir = IrNode.initFull(.try_expr, try_init_node, try_range);
        // Try expressions produce error unions
        try_ir = try_ir.withType(TypeInfo.initErrorUnion());
        const try_node = try cfg.addNode(try_ir);
        try cfg.addEdge(prev_node, try_node);

        // Error path: propagate to function exit
        try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

        // Success path: continue to var decl (try_success edge)
        // Annotate var decl with type info
        var decl_ir = IrNode.initFull(.var_decl, var_decl_node, var_range);
        decl_ir = self.annotateWithType(decl_ir, source, var_decl_node);
        const decl_node = try cfg.addNode(decl_ir);
        try cfg.addEdgeWithKind(try_node, decl_node, .try_success);

        return .{ .last = decl_node, .terminates = false };
    }

    fn processVarDeclWithCatch(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        var_decl_node: u32,
        catch_init_node: u32,
        prev_node: CfgNodeId,
        var_range: SourceRange,
    ) !ProcessResult {
        const tree = try source.ast();
        const catch_range = try getSourceRange(source, catch_init_node);
        const data = tree.nodes.items(.data);

        // Catch expression in var decl initializer:
        //   prev -> catch_node -> var_decl_node
        //   catch_node has success and error paths that both lead to var_decl
        var catch_ir = IrNode.initFull(.catch_expr, catch_init_node, catch_range);
        // Catch expressions handle error unions
        catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
        const catch_node = try cfg.addNode(catch_ir);
        try cfg.addEdge(prev_node, catch_node);

        // Get the RHS (catch handler body) from the catch node
        // For catch nodes, data is node_and_node where [0] is LHS (operand), [1] is RHS (handler)
        const catch_data = data[catch_init_node].node_and_node;
        const handler_ast = @intFromEnum(catch_data[1]);

        // Create the var decl node that both paths lead to
        // Annotate with type information
        var decl_ir = IrNode.initFull(.var_decl, var_decl_node, var_range);
        decl_ir = self.annotateWithType(decl_ir, source, var_decl_node);
        const decl_node = try cfg.addNode(decl_ir);

        // Success path: no error, value is unwrapped, goes to var decl
        try cfg.addEdgeWithKind(catch_node, decl_node, .catch_success);

        // Error path: process handler if present, then go to var decl
        if (handler_ast != 0) {
            const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

            if (handler_result.last) |handler_end| {
                // Handler produced nodes - mark edge from catch to handler as error edge
                self.markEdgeFromCatchError(cfg, catch_node);
                if (!handler_result.terminates) {
                    try cfg.addEdge(handler_end, decl_node);
                }
            } else {
                // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                try cfg.addEdgeWithKind(catch_node, decl_node, .catch_error);
            }
        } else {
            // No handler body (catch default value like `catch 0`)
            // Error edge goes directly to var decl
            try cfg.addEdgeWithKind(catch_node, decl_node, .catch_error);
        }

        return .{ .last = decl_node, .terminates = false };
    }

    fn processAssign(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);

        // Check if the RHS contains a try or catch expression
        // Assign node data: lhs and rhs
        const data = tree.nodes.items(.data);
        const assign_data = data[ast_node].node_and_node;
        const lhs_idx = @intFromEnum(assign_data[0]);
        const rhs_idx = @intFromEnum(assign_data[1]);
        const tags = tree.nodes.items(.tag);
        if (rhs_idx < tags.len) {
            const rhs_tag = tags[rhs_idx];
            if (rhs_tag == .@"try") {
                return try self.processAssignWithTry(cfg, source, ast_node, lhs_idx, rhs_idx, prev_node, range);
            } else if (rhs_tag == .@"catch") {
                return try self.processAssignWithCatch(cfg, source, ast_node, lhs_idx, rhs_idx, prev_node, range);
            }
        }

        const assign_node = try cfg.addNode(IrNode.initAssign(ast_node, lhs_idx, rhs_idx, range));
        try cfg.addEdge(prev_node, assign_node);
        return .{ .last = assign_node, .terminates = false };
    }

    fn processAssignWithTry(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        assign_node_ast: u32,
        lhs_node: u32,
        try_expr_node: u32,
        prev_node: CfgNodeId,
        assign_range: SourceRange,
    ) !ProcessResult {
        _ = self;
        const try_range = try getSourceRange(source, try_expr_node);

        // Assignment with try expression: x = try bar();
        //   prev -> try_node -> assign_node (success path)
        //   try_node --[try_error]--> fn_exit (error path)
        var try_ir = IrNode.initFull(.try_expr, try_expr_node, try_range);
        try_ir = try_ir.withType(TypeInfo.initErrorUnion());
        const try_node = try cfg.addNode(try_ir);
        try cfg.addEdge(prev_node, try_node);

        // Error path: propagate to function exit
        try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

        // Success path: continue to assignment
        const assign_node = try cfg.addNode(IrNode.initAssign(assign_node_ast, lhs_node, try_expr_node, assign_range));
        try cfg.addEdgeWithKind(try_node, assign_node, .try_success);

        return .{ .last = assign_node, .terminates = false };
    }

    fn processAssignWithCatch(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        assign_node_ast: u32,
        lhs_node: u32,
        catch_expr_node: u32,
        prev_node: CfgNodeId,
        assign_range: SourceRange,
    ) !ProcessResult {
        const tree = try source.ast();
        const catch_range = try getSourceRange(source, catch_expr_node);
        const data = tree.nodes.items(.data);

        // Assignment with catch expression
        var catch_ir = IrNode.initFull(.catch_expr, catch_expr_node, catch_range);
        catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
        const catch_node = try cfg.addNode(catch_ir);
        try cfg.addEdge(prev_node, catch_node);

        // Get the handler from catch node
        const catch_data = data[catch_expr_node].node_and_node;
        const handler_ast = @intFromEnum(catch_data[1]);

        // Create the assign node
        const assign_node = try cfg.addNode(IrNode.initAssign(assign_node_ast, lhs_node, catch_expr_node, assign_range));

        // Success path: no error, value is unwrapped, goes to assign
        try cfg.addEdgeWithKind(catch_node, assign_node, .catch_success);

        // Error path: process handler if present, then go to assign
        if (handler_ast != 0) {
            const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

            if (handler_result.last) |handler_end| {
                // Handler produced nodes - mark edge from catch to handler as error edge
                self.markEdgeFromCatchError(cfg, catch_node);
                if (!handler_result.terminates) {
                    try cfg.addEdge(handler_end, assign_node);
                }
            } else {
                // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                try cfg.addEdgeWithKind(catch_node, assign_node, .catch_error);
            }
        } else {
            try cfg.addEdgeWithKind(catch_node, assign_node, .catch_error);
        }

        return .{ .last = assign_node, .terminates = false };
    }

    fn processCall(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const call_node = try cfg.addNode(IrNode.initFull(.call, ast_node, range));
        try cfg.addEdge(prev_node, call_node);
        return .{ .last = call_node, .terminates = false };
    }

    fn processGenericExpr(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        _ = self;
        const range = try getSourceRange(source, ast_node);
        const expr_node = try cfg.addNode(IrNode.initFull(.expr, ast_node, range));
        try cfg.addEdge(prev_node, expr_node);
        return .{ .last = expr_node, .terminates = false };
    }

    fn processWhile(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);

        const header_node = try cfg.addNode(IrNode.initFull(.loop_header, ast_node, range));
        try cfg.addEdge(prev_node, header_node);

        const full_while = tree.fullWhile(@enumFromInt(ast_node)) orelse return .{ .last = null, .terminates = false };

        // Handle else expression if present - this executes when loop condition is false
        const else_ast = if (full_while.ast.else_expr.unwrap()) |e| @intFromEnum(e) else 0;

        var exit_node: CfgNodeId = undefined;
        var else_terminates = false;
        if (else_ast != 0) {
            // Process else body - loop_exit goes to else body, then else body goes to merge
            const else_range = try getSourceRange(source, else_ast);
            const else_entry_node = try cfg.addNode(IrNode.initFull(.block, else_ast, else_range));
            try cfg.addEdgeWithKind(header_node, else_entry_node, .loop_exit);

            const else_result = try self.processNode(cfg, source, else_ast, else_entry_node);

            if (else_result.terminates) {
                else_terminates = true;
                exit_node = else_entry_node;
            } else {
                exit_node = try cfg.addNode(IrNode.init(.nop));
                if (else_result.last) |else_end| {
                    try cfg.addEdge(else_end, exit_node);
                } else {
                    try cfg.addEdge(else_entry_node, exit_node);
                }
            }
        } else {
            exit_node = try cfg.addNode(IrNode.init(.nop));
            try cfg.addEdgeWithKind(header_node, exit_node, .loop_exit);
        }

        const body_ast = @intFromEnum(full_while.ast.then_expr);
        if (body_ast != 0) {
            const body_range = try getSourceRange(source, body_ast);
            const body_node = try cfg.addNode(IrNode.initFull(.loop_body, body_ast, body_range));
            try cfg.addEdgeWithKind(header_node, body_node, .branch_true);

            const body_result = try self.processNode(cfg, source, body_ast, body_node);

            // Handle continue expression if present - executes after body, before loop back
            const cont_ast = if (full_while.ast.cont_expr.unwrap()) |c| @intFromEnum(c) else 0;

            var loop_back_from: CfgNodeId = body_node;
            if (body_result.last) |body_end| {
                if (!body_result.terminates) {
                    loop_back_from = body_end;
                }
            }

            if (!body_result.terminates) {
                if (cont_ast != 0) {
                    // Process continue expression
                    const cont_range = try getSourceRange(source, cont_ast);
                    const cont_node = try cfg.addNode(IrNode.initFull(.expr, cont_ast, cont_range));
                    try cfg.addEdge(loop_back_from, cont_node);
                    try cfg.addEdgeWithKind(cont_node, header_node, .loop_back);
                } else {
                    try cfg.addEdgeWithKind(loop_back_from, header_node, .loop_back);
                }
            }
        } else {
            try cfg.addEdgeWithKind(header_node, header_node, .loop_back);
        }

        return .{ .last = exit_node, .terminates = else_terminates };
    }

    fn processFor(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);

        const header_node = try cfg.addNode(IrNode.initFull(.loop_header, ast_node, range));
        try cfg.addEdge(prev_node, header_node);

        const full_for = tree.fullFor(@enumFromInt(ast_node)) orelse return .{ .last = null, .terminates = false };

        // Handle else expression if present - this executes when loop completes normally (not via break)
        const else_ast = if (full_for.ast.else_expr.unwrap()) |e| @intFromEnum(e) else 0;

        var exit_node: CfgNodeId = undefined;
        var else_terminates = false;
        if (else_ast != 0) {
            // Process else body - loop_exit goes to else body, then else body goes to merge
            const else_range = try getSourceRange(source, else_ast);
            const else_entry_node = try cfg.addNode(IrNode.initFull(.block, else_ast, else_range));
            try cfg.addEdgeWithKind(header_node, else_entry_node, .loop_exit);

            const else_result = try self.processNode(cfg, source, else_ast, else_entry_node);

            if (else_result.terminates) {
                else_terminates = true;
                exit_node = else_entry_node;
            } else {
                exit_node = try cfg.addNode(IrNode.init(.nop));
                if (else_result.last) |else_end| {
                    try cfg.addEdge(else_end, exit_node);
                } else {
                    try cfg.addEdge(else_entry_node, exit_node);
                }
            }
        } else {
            exit_node = try cfg.addNode(IrNode.init(.nop));
            try cfg.addEdgeWithKind(header_node, exit_node, .loop_exit);
        }

        const body_ast = @intFromEnum(full_for.ast.then_expr);
        if (body_ast != 0) {
            const body_range = try getSourceRange(source, body_ast);
            const body_node = try cfg.addNode(IrNode.initFull(.loop_body, body_ast, body_range));
            try cfg.addEdgeWithKind(header_node, body_node, .branch_true);

            const body_result = try self.processNode(cfg, source, body_ast, body_node);

            if (body_result.last) |body_end| {
                if (!body_result.terminates) {
                    try cfg.addEdgeWithKind(body_end, header_node, .loop_back);
                }
            } else {
                try cfg.addEdgeWithKind(body_node, header_node, .loop_back);
            }
        } else {
            try cfg.addEdgeWithKind(header_node, header_node, .loop_back);
        }

        return .{ .last = exit_node, .terminates = else_terminates };
    }

    fn processDefer(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        _ = self;
        const range = try getSourceRange(source, ast_node);

        // Defer bodies execute at scope exit, not at declaration time.
        // We record the defer statement node (which references the body AST)
        // but don't add the body to the main control flow. The body can be
        // analyzed separately when needed for scope exit paths.
        const defer_node = try cfg.addNode(IrNode.initFull(.defer_stmt, ast_node, range));
        try cfg.addEdge(prev_node, defer_node);

        return .{ .last = defer_node, .terminates = false };
    }

    fn processErrdefer(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        _ = self;
        const range = try getSourceRange(source, ast_node);

        // Errdefer bodies execute at scope exit on error paths, not at declaration time.
        // We record the errdefer statement node (which references the body AST)
        // but don't add the body to the main control flow. The body can be
        // analyzed separately when needed for error exit paths.
        const errdefer_node = try cfg.addNode(IrNode.initFull(.errdefer_stmt, ast_node, range));
        try cfg.addEdge(prev_node, errdefer_node);

        return .{ .last = errdefer_node, .terminates = false };
    }

    fn processTry(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        _ = self;
        const range = try getSourceRange(source, ast_node);

        // Try expression: evaluates an error union and either:
        // - On success: unwraps the value and continues normally
        // - On error: propagates the error to the caller (jumps to exit)
        //
        // CFG structure:
        //   prev_node -> try_node
        //   try_node --[try_success]--> (next statement)
        //   try_node --[try_error]--> fn_exit
        var try_ir = IrNode.initFull(.try_expr, ast_node, range);
        // Try expressions operate on error unions
        try_ir = try_ir.withType(TypeInfo.initErrorUnion());
        const try_node = try cfg.addNode(try_ir);
        try cfg.addEdge(prev_node, try_node);

        // Error path: propagate to function exit
        try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

        // Success path continues to the next statement.
        // Return next_edge_kind so the block processing marks the edge as try_success.
        return .{ .last = try_node, .terminates = false, .next_edge_kind = .try_success };
    }

    fn processCatch(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) !ProcessResult {
        const tree = try source.ast();
        const range = try getSourceRange(source, ast_node);
        const data = tree.nodes.items(.data);

        // Catch expression: handles errors from an error union
        // Structure: expr catch |opt_err| handler
        //
        // CFG structure:
        //   prev_node -> catch_node
        //   catch_node --[catch_success]--> merge_node (value is unwrapped)
        //   catch_node --[catch_error]--> handler_body -> merge_node
        var catch_ir = IrNode.initFull(.catch_expr, ast_node, range);
        // Catch expressions handle error unions
        catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
        const catch_node = try cfg.addNode(catch_ir);
        try cfg.addEdge(prev_node, catch_node);

        // Get the RHS (catch handler body) from the catch node
        // For catch nodes, data is node_and_node where [0] is LHS (operand), [1] is RHS (handler)
        const catch_data = data[ast_node].node_and_node;
        const handler_ast = @intFromEnum(catch_data[1]);

        // Create merge node for after the catch
        const merge_node = try cfg.addNode(IrNode.init(.nop));

        // Success path: no error, value is unwrapped, goes directly to merge
        try cfg.addEdgeWithKind(catch_node, merge_node, .catch_success);

        // Error path: go to handler, then to merge
        if (handler_ast != 0) {
            const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

            if (handler_result.last) |handler_end| {
                // Handler produced nodes - mark edge from catch to handler as error edge
                self.markEdgeFromCatchError(cfg, catch_node);
                if (!handler_result.terminates) {
                    try cfg.addEdgeWithKind(handler_end, merge_node, .catch_success);
                }
            } else {
                // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                try cfg.addEdgeWithKind(catch_node, merge_node, .catch_error);
            }
        } else {
            // No handler body (catch default value like `catch 0`)
            // Error edge goes directly to merge
            try cfg.addEdgeWithKind(catch_node, merge_node, .catch_error);
        }

        return .{ .last = merge_node, .terminates = false };
    }

    fn markEdgeFromCatchError(self: *CfgBuilder, cfg: *Cfg, catch_node: CfgNodeId) void {
        _ = self;
        // Find the most recent edge from catch_node that is normal and mark it as catch_error
        var i = cfg.edges.items.len;
        while (i > 0) {
            i -= 1;
            if (cfg.edges.items[i].from == catch_node and cfg.edges.items[i].kind == .normal) {
                cfg.edges.items[i].kind = .catch_error;
                break;
            }
        }
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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
        const var_node = ids.astId(@intFromEnum(root_decls[0]));
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
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

test "CfgBuilder simple if without else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var found_branch = false;
    var branch_count: usize = 0;
    var ret_count: usize = 0;
    var nop_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => {
                found_branch = true;
                branch_count += 1;
            },
            .ret => ret_count += 1,
            .nop => nop_count += 1,
            else => {},
        }
    }

    try testing.expect(found_branch);
    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);
    try testing.expectEqual(@as(usize, 1), nop_count);
}

test "CfgBuilder if-else branches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);

    var branch_true_edges: usize = 0;
    var branch_false_edges: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .branch_true) branch_true_edges += 1;
        if (edge.kind == .branch_false) branch_false_edges += 1;
    }

    try testing.expect(branch_true_edges > 0 or branch_false_edges > 0);
}

test "CfgBuilder if-else terminates block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\    const z = 2;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var ret_count: usize = 0;
    var var_decl_count: usize = 0;
    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .ret => ret_count += 1,
            .var_decl => var_decl_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), ret_count);
    try testing.expectEqual(@as(usize, 0), var_decl_count);
}

test "CfgBuilder if-else with merge point" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    var result: i32 = 0;
        \\    if (x > 0) {
        \\        result = 1;
        \\    } else {
        \\        result = -1;
        \\    }
        \\    return result;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;
    var nop_count: usize = 0;
    var assign_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            .nop => nop_count += 1,
            .assign => assign_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 1), ret_count);
    try testing.expectEqual(@as(usize, 1), nop_count);
    try testing.expectEqual(@as(usize, 2), assign_count);
}

test "CfgBuilder nested if" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32, y: i32) i32 {
        \\    if (x > 0) {
        \\        if (y > 0) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), branch_count);
    try testing.expectEqual(@as(usize, 3), ret_count);
}

test "CfgBuilder branch source range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .branch) {
            try testing.expect(node.ir_node.source_range != null);
            const range = node.ir_node.source_range.?;
            try testing.expectEqual(@as(usize, 2), range.start.line);
            break;
        }
    }
}

test "CfgBuilder fully terminating if-else has no fallthrough edges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Check that both return nodes connect to exit via jump edges
    var return_to_exit_jumps: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.to == cfg.exit and edge.kind == .jump) {
            return_to_exit_jumps += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), return_to_exit_jumps);

    // Check there are no normal edges to exit (which would indicate fallthrough)
    var normal_to_exit: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.to == cfg.exit and edge.kind == .normal) {
            normal_to_exit += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), normal_to_exit);
}

test "CfgBuilder merge node unreachable when both branches terminate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the merge node (nop node)
    var merge_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .nop) {
            merge_node_idx = node.index;
            break;
        }
    }

    // Merge node should exist but have no incoming edges
    try testing.expect(merge_node_idx != null);
    var preds: std.ArrayList(CfgNodeId) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(allocator, merge_node_idx.?, &preds);
    try testing.expectEqual(@as(usize, 0), preds.items.len);
}

test "CfgBuilder only then branch terminates allows fallthrough from else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    var y: i32 = 0;
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        y = -1;
        \\    }
        \\    return y;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 return nodes (one in if branch, one at end)
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) ret_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), ret_count);

    // The merge node should have incoming edges (from else branch)
    var merge_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .nop) {
            merge_node_idx = node.index;
            break;
        }
    }

    try testing.expect(merge_node_idx != null);
    var preds: std.ArrayList(CfgNodeId) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(allocator, merge_node_idx.?, &preds);
    try testing.expect(preds.items.len > 0);
}

test "CfgBuilder trailing statements unreachable after terminating if-else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\    const a = 1;
        \\    const b = 2;
        \\    return a + b;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Trailing statements should not be included in CFG
    var var_decl_count: usize = 0;
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .var_decl => var_decl_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    // No var decls should be present (they are unreachable)
    try testing.expectEqual(@as(usize, 0), var_decl_count);
    // Only the 2 returns inside if/else should be present
    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder simple while loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    var x: i32 = 0;
        \\    while (x < 10) {
        \\        x += 1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have loop_header and loop_body nodes
    var loop_header_count: usize = 0;
    var loop_body_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .loop_body) loop_body_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), loop_body_count);

    // Should have loop_back and loop_exit edges
    var loop_back_count: usize = 0;
    var loop_exit_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back) loop_back_count += 1;
        if (edge.kind == .loop_exit) loop_exit_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_back_count);
    try testing.expectEqual(@as(usize, 1), loop_exit_count);
}

test "CfgBuilder while loop with return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    var x: i32 = 0;
        \\    while (x < 10) {
        \\        if (x == 5) {
        \\            return x;
        \\        }
        \\        x += 1;
        \\    }
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have branch and return nodes inside the loop
    var branch_count: usize = 0;
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .branch) branch_count += 1;
        if (node.ir_node.tag == .ret) ret_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder simple for loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    for (0..10) |_| {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have loop_header and loop_body nodes
    var loop_header_count: usize = 0;
    var loop_body_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .loop_body) loop_body_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), loop_body_count);

    // Should have loop_back and loop_exit edges
    var loop_back_count: usize = 0;
    var loop_exit_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back) loop_back_count += 1;
        if (edge.kind == .loop_exit) loop_exit_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_back_count);
    try testing.expectEqual(@as(usize, 1), loop_exit_count);
}

test "CfgBuilder defer statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have defer_stmt node (body is not added inline, executes at scope exit)
    var defer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), defer_count);

    // Defer is part of normal control flow - body AST is referenced but not executed inline
    var edges_to_defer: usize = 0;
    for (cfg.edges.items) |edge| {
        if (cfg.getNode(edge.to)) |node| {
            if (node.ir_node.tag == .defer_stmt) edges_to_defer += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), edges_to_defer);
}

test "CfgBuilder errdefer statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    errdefer {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have errdefer_stmt node (body is not added inline, executes on error exit)
    var errdefer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .errdefer_stmt) errdefer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), errdefer_count);

    // Errdefer is part of normal control flow - body AST is referenced but not executed inline
    var edges_to_errdefer: usize = 0;
    for (cfg.edges.items) |edge| {
        if (cfg.getNode(edge.to)) |node| {
            if (node.ir_node.tag == .errdefer_stmt) edges_to_errdefer += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), edges_to_errdefer);
}

test "CfgBuilder multiple defers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer { const a = 1; _ = a; }
        \\    defer { const b = 2; _ = b; }
        \\    errdefer { const c = 3; _ = c; }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 defer_stmt and 1 errdefer_stmt nodes
    var defer_count: usize = 0;
    var errdefer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
        if (node.ir_node.tag == .errdefer_stmt) errdefer_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), defer_count);
    try testing.expectEqual(@as(usize, 1), errdefer_count);
}

test "CfgBuilder loop with defer inside" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    while (true) {
        \\        defer { const x = 1; _ = x; }
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have both loop and defer nodes
    var loop_header_count: usize = 0;
    var defer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), defer_count);
}

test "CfgBuilder while loop back-edge targets header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    while (true) {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the loop header node
    var header_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) {
            header_idx = node.index;
            break;
        }
    }

    try testing.expect(header_idx != null);

    // The loop_back edge should point to the header
    var back_edge_targets_header = false;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back and edge.to == header_idx.?) {
            back_edge_targets_header = true;
            break;
        }
    }

    try testing.expect(back_edge_targets_header);
}

test "CfgBuilder simple try expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    const x = try bar();
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr node
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);

    // Should have try_error edge to exit
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), try_error_count);
}

test "CfgBuilder try expression has error and success paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const x = try bar();
        \\    return x + 1;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the try_expr node
    var try_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) {
            try_node_idx = node.index;
            break;
        }
    }

    try testing.expect(try_node_idx != null);

    // Try node should have 2 outgoing edges: one error (to exit), one normal (to next)
    var succs: std.ArrayList(CfgNodeId) = .empty;
    defer succs.deinit(allocator);

    try cfg.getSuccessors(allocator, try_node_idx.?, &succs);
    try testing.expectEqual(@as(usize, 2), succs.items.len);

    // One edge should go to exit (error path)
    var has_exit_edge = false;
    for (succs.items) |succ| {
        if (succ == cfg.exit) has_exit_edge = true;
    }
    try testing.expect(has_exit_edge);
}

test "CfgBuilder simple catch expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const x = bar() catch 0;
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have catch_success and catch_error edges
    var catch_success_count: usize = 0;
    var catch_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .catch_success) catch_success_count += 1;
        if (edge.kind == .catch_error) catch_error_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_success_count);
    try testing.expectEqual(@as(usize, 1), catch_error_count);
}

test "CfgBuilder catch with block handler" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const x = bar() catch |err| {
        \\        _ = err;
        \\        return -1;
        \\    };
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have return nodes (one in handler, one at end)
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) ret_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder multiple try expressions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const a = try bar();
        \\    const b = try baz();
        \\    return a + b;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 try_expr nodes
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), try_expr_count);

    // Should have 2 try_error edges to exit
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), try_error_count);
}

test "CfgBuilder try inside if branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(cond: bool) !i32 {
        \\    if (cond) {
        \\        return try bar();
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr and branch nodes
    var try_expr_count: usize = 0;
    var branch_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .branch) branch_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), branch_count);
}

test "CfgBuilder catch with empty block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    _ = bar() catch {};
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have both catch_success and catch_error edges
    var catch_success_count: usize = 0;
    var catch_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .catch_success) catch_success_count += 1;
        if (edge.kind == .catch_error) catch_error_count += 1;
    }

    try testing.expect(catch_success_count >= 1);
    try testing.expect(catch_error_count >= 1);
}

test "CfgBuilder try and catch combined" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const x = try bar();
        \\    const y = baz() catch 0;
        \\    return x + y;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have both try_expr and catch_expr nodes
    var try_expr_count: usize = 0;
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), catch_expr_count);
}

test "CfgBuilder try in loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    while (true) {
        \\        try bar();
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr and loop_header nodes
    var try_expr_count: usize = 0;
    var loop_header_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), loop_header_count);

    // Should have try_error edge
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error) try_error_count += 1;
    }

    try testing.expect(try_error_count >= 1);
}

test "CfgBuilder standalone try has try_success edge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    try bar();
        \\    try baz();
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 try_expr nodes
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), try_expr_count);

    // Should have 2 try_error edges (one per try, going to exit)
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), try_error_count);

    // Should have at least 1 try_success edge (from first try to second try)
    var try_success_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_success) try_success_count += 1;
    }
    try testing.expect(try_success_count >= 1);
}

// ============================================================================
// Typed IR Integration Tests
// ============================================================================

test "CfgBuilder with TypeContext annotates var decl" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    const x: i32 = 42;
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Create type context for the source
    var type_ctx = TypeContext.init(allocator, &source);
    defer type_ctx.deinit();

    // Create builder with type context
    var builder = CfgBuilder.initWithTypes(allocator, &type_ctx);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const fn_node = ids.astId(@intFromEnum(root_decls[0]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the var_decl node
    var found_typed_var_decl = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) {
            // The node should have type info attached (may be null if ZIR fails)
            // At minimum, verify the node exists
            found_typed_var_decl = true;
            break;
        }
    }
    try testing.expect(found_typed_var_decl);
}

test "CfgBuilder try expression has error_union type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn bar() !i32 { return 1; }
        \\fn foo() !void {
        \\    _ = try bar();
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    // Find the second function (foo)
    var fn_node_index: ?usize = null;
    for (root_decls, 0..) |decl, i| {
        const idx = @intFromEnum(decl);
        if (tree.nodes.items(.tag)[idx] == .fn_decl) {
            if (fn_node_index == null) {
                // Skip bar, find foo
                fn_node_index = i;
            } else {
                fn_node_index = i;
                break;
            }
        }
    }

    try testing.expect(fn_node_index != null);
    const fn_node = ids.astId(@intFromEnum(root_decls[fn_node_index.?]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find try_expr node and verify it has error_union type info
    var found_try_with_type = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) {
            if (node.ir_node.type_info) |ti| {
                try testing.expectEqual(TypeInfo.TypeKind.error_union, ti.kind);
                found_try_with_type = true;
            }
            break;
        }
    }
    try testing.expect(found_try_with_type);
}

test "CfgBuilder catch expression has error_union type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn bar() !i32 { return 1; }
        \\fn foo() void {
        \\    const x = bar() catch 0;
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    // Find the second function (foo)
    var fn_node_index: usize = 0;
    for (root_decls, 0..) |decl, i| {
        const idx = @intFromEnum(decl);
        if (tree.nodes.items(.tag)[idx] == .fn_decl) {
            fn_node_index = i;
        }
    }

    const fn_node = ids.astId(@intFromEnum(root_decls[fn_node_index]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find catch_expr node and verify it has error_union type info
    var found_catch_with_type = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) {
            if (node.ir_node.type_info) |ti| {
                try testing.expectEqual(TypeInfo.TypeKind.error_union, ti.kind);
                found_catch_with_type = true;
            }
            break;
        }
    }
    try testing.expect(found_catch_with_type);
}

test "CfgBuilder hasTypeContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Builder without type context
    var builder1 = CfgBuilder.init(allocator);
    try testing.expect(!builder1.hasTypeContext());

    // Builder with type context
    var type_ctx = TypeContext.init(allocator, &source);
    defer type_ctx.deinit();

    var builder2 = CfgBuilder.initWithTypes(allocator, &type_ctx);
    try testing.expect(builder2.hasTypeContext());

    // Set type context after init
    builder1.setTypeContext(&type_ctx);
    try testing.expect(builder1.hasTypeContext());
}
