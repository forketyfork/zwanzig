const std = @import("std");
const assertions = @import("../assertions.zig");
const ast_walk = @import("../ast_walk.zig");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const TypeContext = @import("../type_context.zig").TypeContext;
const ids = @import("../ids.zig");
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const cfg_mod = @import("../cfg.zig");
const Cfg = cfg_mod.Cfg;

const log = std.log.scoped(.optional_unwrap);

/// Maximum number of statements to scan in a block for guard pattern detection.
/// If a block exceeds this limit, a warning is logged and later statements are not analyzed.
const max_block_statements = 64;

/// Engine-based checker that detects forced optional unwraps (.?) that may panic at runtime.
/// Uses CFG analysis to track when optionals have been checked for null.
///
/// Safe patterns (no warning):
/// - `if (x != null) { x.? }` - null check guards the unwrap
/// - `if (x) |val| { ... }` - payload capture pattern
/// - `orelse` - provides fallback value
///
/// Warned patterns:
/// - `x.?` without prior null check on the same path
pub const OptionalUnwrapEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "optional-unwrap",
        .default_severity = .warning,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        // Track reported AST nodes across all functions to avoid duplicates
        var reported: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(allocator);
        defer reported.deinit();

        for (0..tags.len) |i| {
            if (tags[i] == .fn_decl or tags[i] == .test_decl) {
                try analyzeFunction(src, allocator, ids.astId(@intCast(i)), diagnostics, context, &reported);
            }
        }
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: ids.AstNodeId,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
        reported: *std.AutoHashMap(u32, void),
    ) CheckerError!void {
        var builder = context.createCfgBuilder(allocator);
        var cfg_opt = builder.buildFromFn(src, fn_node) catch return;
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            // Create a TypeContext for type-aware analysis
            var type_ctx = TypeContext.init(allocator, src);
            defer type_ctx.deinit();

            var engine = AnalysisEngine.initWithSource(allocator, cfg, src);
            defer engine.deinit();
            engine.setCheckerName("optional-unwrap");
            engine.setTypeContext(&type_ctx);
            if (context.build_metadata) |metadata| {
                engine.setBuildMetadata(metadata);
            }
            if (context.config) |config| {
                engine.setConfig(config);
            }
            if (context.analysis_limits.max_worklist_steps) |steps| {
                engine.setMaxWorklistSteps(steps);
            }
            if (context.analysis_limits.max_states_per_point) |max| {
                engine.setMaxStatesPerPoint(max);
            }
            if (context.analysis_limits.use_widening) |use_w| {
                engine.setUseWidening(use_w);
            }
            var run_ok = true;
            engine.run() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisLimitExceeded => run_ok = false,
            };
            if (context.analysis_stats) |stats| {
                stats.recordRun(engine.getGraph().getDroppedStateCount());
                stats.recordWidening(engine.getGraph().getWidenedNodeCount(), engine.getGraph().getWideningConvergedCount());
            }

            // Dump visualizations if requested
            if (context.dump_exploded_graph_dir) |dir| {
                engine_mod.dot.writeExplodedGraphToFile(engine.getGraph(), dir, src.getFilePath(), cfg.fn_name, allocator);
            }
            if (context.dump_annotated_cfg_dir) |dir| {
                engine_mod.dot.writeAnnotatedCfgToFile(engine.getGraph(), dir, src.getFilePath(), cfg.fn_name, allocator);
            }
            if (context.dump_path_trace_dir) |dir| {
                engine_mod.dot.writePathTracesToFile(engine.getGraph(), dir, src.getFilePath(), cfg.fn_name, allocator);
            }

            if (!run_ok) return;

            // Scan AST for unwrap_optional nodes and check nullability
            const tree = src.ast() catch return;
            try scanForUnsafeUnwraps(src, allocator, diagnostics, tree, &engine, cfg, reported, fn_node);
        }
    }

    fn scanForUnsafeUnwraps(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        engine: *AnalysisEngine,
        cfg: *const Cfg,
        reported: *std.AutoHashMap(u32, void),
        fn_node: ids.AstNodeId,
    ) CheckerError!void {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);
        const datas = tree.nodes.items(.data);

        // Scan only the AST nodes that are part of this function's body
        // We do this by walking the function body's AST subtree
        const fn_index = ids.astIndex(fn_node);
        if (fn_index >= tags.len) return;

        const parent_map = try allocator.alloc(u32, tags.len);
        defer allocator.free(parent_map);
        @memset(parent_map, 0);
        ast_walk.fillParentMap(tree, fn_index, parent_map);

        const allow_bare = tags[fn_index] == .test_decl;
        var assertion_scope = try assertions.buildAssertionScope(allocator, tree, fn_index, allow_bare);
        defer assertion_scope.deinit(allocator);

        // Collect all unwrap_optional nodes within this function's body
        var unwraps: std.ArrayList(u32) = .empty;
        defer unwraps.deinit(allocator);

        try collectUnwrapsInSubtree(tree, fn_index, allocator, &unwraps);

        for (unwraps.items) |ast_node| {
            // Skip if already reported
            if (reported.contains(ast_node)) continue;

            // Skip unwraps inside test assertion calls (expectEqual, expectEqualStrings, etc.)
            // These are intentional - the test will panic if the value is null
            if (isInsideTestAssertion(tree, ast_node, parent_map, &assertion_scope)) continue;

            // Skip unwraps inside comptime type expressions (@typeInfo, @TypeOf, etc.)
            // These are evaluated at compile time and will produce a compile error, not a runtime panic
            if (isInsideComptimeTypeExpr(tree, ast_node, parent_map)) continue;

            // Get the variable being unwrapped
            const unwrapped_node = @intFromEnum(datas[ast_node].node_and_token[0]);

            // Check if the unwrap is guarded by short-circuit evaluation (and/or operators)
            // or by a ternary if expression. These are AST-level guards that the CFG
            // doesn't track because short-circuit evaluation is implicit.
            if (isGuardedByShortCircuit(tree, ast_node, unwrapped_node, parent_map)) continue;

            // Check if this is a lazy initialization pattern where we initialize
            // the optional before unwrapping it
            if (isGuardedByLazyInit(tree, ast_node, unwrapped_node, parent_map)) continue;

            // Check if this is an early exit pattern where a null check leads to
            // continue/break/return, making subsequent code only reachable when non-null
            if (isGuardedByEarlyExit(tree, ast_node, unwrapped_node, parent_map)) continue;

            // Check if this is an assignment followed by immediate unwrap pattern
            // e.g., `x = foo() orelse return error; x.?`
            if (isGuardedByPriorAssignment(tree, ast_node, unwrapped_node, parent_map)) continue;

            // Check if this is a method call with catch/early exit that ensures the field
            // e.g., `self.ensureTexture() catch return; ... self.texture.?`
            if (isGuardedByMethodCallWithCatch(tree, ast_node, unwrapped_node, parent_map, fn_node)) continue;

            // Find the CFG node containing this AST node
            const cfg_node_idx = findCfgNodeForAst(cfg, ast_node, tree);
            const node_idx = cfg_node_idx orelse {
                // AST node not in CFG (possibly unreachable code) - report conservatively
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
                continue;
            };

            // Check if the variable is proven non-null at this point
            if (!isProvenNonNull(engine, node_idx, unwrapped_node, cfg, fn_node)) {
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
            }
        }
    }

    /// Check if an unwrap_optional AST node is inside a test assertion call.
    /// Test assertions like expectEqual, expectEqualStrings, etc. are intentional
    /// uses where a panic is acceptable (the test would fail anyway).
    fn isInsideTestAssertion(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        parent_map: []const u32,
        scope: *const assertions.AssertionScope,
    ) bool {
        const tags = tree.nodes.items(.tag);
        var node = unwrap_node;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;
            switch (tags[parent]) {
                .call, .call_comma, .call_one, .call_one_comma => {
                    if (isTestAssertionCall(tree, parent, scope)) {
                        return true;
                    }
                },
                else => {},
            }
            node = parent;
        }

        return false;
    }

    fn isTestAssertionCall(tree: *const std.zig.Ast, call_node: u32, scope: *const assertions.AssertionScope) bool {
        const tags = tree.nodes.items(.tag);

        if (call_node >= tags.len) return false;

        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(call_node)) orelse return false;

        return assertions.resolveAssertionName(tree, full.ast.fn_expr, scope) != null;
    }

    /// Check if an unwrap is inside a comptime type expression.
    /// Type expressions like `@typeInfo(@TypeOf(x)).@"fn".return_type.?` are evaluated
    /// at compile time, so a failed unwrap produces a compile error, not a runtime panic.
    fn isInsideComptimeTypeExpr(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        parent_map: []const u32,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const datas = tree.nodes.items(.data);

        // First check: walk up the structural parent chain for direct containment
        var node = unwrap_node;
        var depth: u32 = 0;
        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            switch (tags[parent]) {
                .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                    if (isComptimeTypeBuiltin(tree, parent, main_tokens)) {
                        return true;
                    }
                },
                .fn_decl => {
                    // Check if the unwrap is in the return type position
                    const fn_proto_node = @intFromEnum(datas[parent].node_and_node[0]);
                    if (fn_proto_node < tags.len and isInFnReturnType(tree, fn_proto_node, node)) {
                        return true;
                    }
                },
                else => {},
            }
            node = parent;
        }

        // Second check: for expressions like `@typeInfo(...).field.?`, walk down the operand
        // chain from the unwrap to find if the root expression is a comptime type builtin
        if (unwrap_node >= tags.len) return false;
        if (tags[unwrap_node] != .unwrap_optional) return false;

        // The operand of unwrap_optional is in data[0]
        const operand = @intFromEnum(datas[unwrap_node].node_and_token[0]);
        return exprRootIsComptimeTypeBuiltin(tree, operand, tags, main_tokens, datas);
    }

    /// Walk down through field accesses to find the root expression and check if it's a comptime type builtin
    fn exprRootIsComptimeTypeBuiltin(
        tree: *const std.zig.Ast,
        node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        main_tokens: []const u32,
        datas: []const std.zig.Ast.Node.Data,
    ) bool {
        if (node >= tags.len) return false;

        return switch (tags[node]) {
            .field_access => {
                // Field access: walk down to the object being accessed
                const obj = @intFromEnum(datas[node].node_and_token[0]);
                return exprRootIsComptimeTypeBuiltin(tree, obj, tags, main_tokens, datas);
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                return isComptimeTypeBuiltin(tree, node, main_tokens);
            },
            else => false,
        };
    }

    /// Check if a builtin call is a comptime type-related builtin
    fn isComptimeTypeBuiltin(tree: *const std.zig.Ast, node: u32, main_tokens: []const u32) bool {
        if (node >= main_tokens.len) return false;
        const token = main_tokens[node];
        const builtin_name = tree.tokenSlice(token);
        return std.mem.eql(u8, builtin_name, "@typeInfo") or
            std.mem.eql(u8, builtin_name, "@TypeOf") or
            std.mem.eql(u8, builtin_name, "@Type") or
            std.mem.eql(u8, builtin_name, "@compileError");
    }

    /// Check if a node is in the return type position of a function prototype
    fn isInFnReturnType(tree: *const std.zig.Ast, fn_proto_node: u32, target_node: u32) bool {
        const tags = tree.nodes.items(.tag);
        if (fn_proto_node >= tags.len) return false;

        // Get the full function prototype
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const fn_proto = tree.fullFnProto(&buf, @enumFromInt(fn_proto_node)) orelse return false;

        // Check if target_node is in the return type expression
        const return_type = @intFromEnum(fn_proto.ast.return_type);
        if (return_type == 0) return false;

        return isInSubtree(tree, return_type, target_node) or return_type == target_node;
    }

    /// Extract statements from a block node into a buffer.
    /// Returns the number of statements, or null if the node is not a block.
    /// Logs a warning if the block has more statements than the buffer can hold.
    fn getBlockStatements(
        tree: *const std.zig.Ast,
        block: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        stmts_buf: *[max_block_statements]u32,
    ) ?usize {
        if (block >= tags.len) return null;

        var stmt_count: usize = 0;

        switch (tags[block]) {
            .block, .block_semicolon => {
                const extra = datas[block].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                const total_stmts = end - start;
                if (total_stmts > max_block_statements) {
                    log.warn("block has {d} statements, exceeding limit of {d}; guard detection may be incomplete", .{ total_stmts, max_block_statements });
                }
                const len = @min(total_stmts, max_block_statements);
                for (0..len) |i| {
                    stmts_buf[i] = tree.extra_data[start + i];
                    stmt_count += 1;
                }
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = datas[block].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    stmts_buf[stmt_count] = @intFromEnum(n);
                    stmt_count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    stmts_buf[stmt_count] = @intFromEnum(n);
                    stmt_count += 1;
                }
            },
            else => return null,
        }

        return stmt_count;
    }

    /// Check if an unwrap follows a lazy initialization pattern.
    /// Pattern: `if (x == null) { x = init(); } ... x.?`
    /// After the if block, x is guaranteed to be non-null.
    fn isGuardedByLazyInit(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        unwrapped_var: u32,
        parent_map: []const u32,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        // Find the containing block
        var node = unwrap_node;
        var block_node: ?u32 = null;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            if (tags[parent] == .block or tags[parent] == .block_two or
                tags[parent] == .block_two_semicolon)
            {
                block_node = parent;
                break;
            }
            node = parent;
        }

        const block = block_node orelse return false;

        // Scan the block for lazy init pattern
        return scanBlockForLazyInit(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
    }

    /// Scan a block for lazy initialization pattern
    fn scanBlockForLazyInit(
        tree: *const std.zig.Ast,
        block: u32,
        unwrap_node: u32,
        unwrapped_var: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        token_starts: []const u32,
    ) bool {
        if (block >= tags.len) return false;

        // Get position of the unwrap node
        if (unwrap_node >= main_tokens.len) return false;
        const unwrap_pos = token_starts[main_tokens[unwrap_node]];

        // Get statements from the block
        var stmts_buf: [max_block_statements]u32 = undefined;
        const stmt_count = getBlockStatements(tree, block, tags, datas, &stmts_buf) orelse return false;

        // Look for an if statement before the unwrap that initializes the variable
        for (stmts_buf[0..stmt_count]) |stmt| {
            if (stmt >= tags.len) continue;
            if (stmt >= main_tokens.len) continue;

            const stmt_pos = token_starts[main_tokens[stmt]];

            // Only look at statements before the unwrap
            if (stmt_pos >= unwrap_pos) continue;

            // Check if this is an if statement
            if (tags[stmt] != .@"if" and tags[stmt] != .if_simple) continue;

            // Check if the condition is `var == null`
            const full = tree.fullIf(@enumFromInt(stmt)) orelse continue;
            const cond = @intFromEnum(full.ast.cond_expr);

            if (!checksNull(tree, cond, unwrapped_var)) continue;

            // Check if the then branch assigns to the variable
            const then_expr = @intFromEnum(full.ast.then_expr);
            if (assignsToVariable(tree, then_expr, unwrapped_var, tags, datas)) {
                return true;
            }
        }

        return false;
    }

    /// Check if an expression or block assigns to a specific variable
    fn assignsToVariable(
        tree: *const std.zig.Ast,
        node: u32,
        var_node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
    ) bool {
        if (node >= tags.len) return false;

        switch (tags[node]) {
            .assign => {
                const lhs = @intFromEnum(datas[node].node_and_node[0]);
                return sameVariable(tree, lhs, var_node);
            },
            .block, .block_semicolon => {
                const extra = datas[node].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                for (start..end) |i| {
                    const stmt = tree.extra_data[i];
                    if (assignsToVariable(tree, stmt, var_node, tags, datas)) {
                        return true;
                    }
                }
                return false;
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = datas[node].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    if (assignsToVariable(tree, @intFromEnum(n), var_node, tags, datas)) {
                        return true;
                    }
                }
                if (opt_nodes[1].unwrap()) |n| {
                    if (assignsToVariable(tree, @intFromEnum(n), var_node, tags, datas)) {
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if an unwrap is guarded by an early exit pattern.
    /// Pattern: `if (x == null) continue/break/return;` before the unwrap
    /// After this check, the code is only reachable when x is non-null.
    fn isGuardedByEarlyExit(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        unwrapped_var: u32,
        parent_map: []const u32,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        // Find the containing block (could be loop body or function body)
        var node = unwrap_node;
        var block_node: ?u32 = null;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            if (tags[parent] == .block or tags[parent] == .block_two or
                tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
            {
                block_node = parent;
                break;
            }
            node = parent;
        }

        const block = block_node orelse return false;

        // Scan the block for early exit pattern
        return scanBlockForEarlyExit(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
    }

    /// Scan a block for early exit pattern (if null then continue/break/return)
    fn scanBlockForEarlyExit(
        tree: *const std.zig.Ast,
        block: u32,
        unwrap_node: u32,
        unwrapped_var: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        token_starts: []const u32,
    ) bool {
        if (block >= tags.len) return false;

        // Get position of the unwrap node
        if (unwrap_node >= main_tokens.len) return false;
        const unwrap_pos = token_starts[main_tokens[unwrap_node]];

        // Get statements from the block
        var stmts_buf: [max_block_statements]u32 = undefined;
        const stmt_count = getBlockStatements(tree, block, tags, datas, &stmts_buf) orelse return false;

        // Look for an if statement before the unwrap that exits on null
        for (stmts_buf[0..stmt_count]) |stmt| {
            if (stmt >= tags.len) continue;
            if (stmt >= main_tokens.len) continue;

            const stmt_pos = token_starts[main_tokens[stmt]];

            // Only look at statements before the unwrap
            if (stmt_pos >= unwrap_pos) continue;

            // Check if this is an if statement
            if (tags[stmt] != .@"if" and tags[stmt] != .if_simple) continue;

            // Check if the condition is `var == null`
            const full = tree.fullIf(@enumFromInt(stmt)) orelse continue;
            const cond = @intFromEnum(full.ast.cond_expr);

            if (!checksNull(tree, cond, unwrapped_var)) continue;

            // Check if the then branch is an early exit (continue, break, return)
            const then_expr = @intFromEnum(full.ast.then_expr);
            if (isEarlyExitExpr(tree, then_expr, tags, datas)) {
                return true;
            }
        }

        return false;
    }

    /// Check if an expression is an early exit (continue, break, return)
    fn isEarlyExitExpr(
        tree: *const std.zig.Ast,
        node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
    ) bool {
        if (node >= tags.len) return false;

        return switch (tags[node]) {
            .@"continue", .@"break", .@"return" => true,
            // Handle blocks that contain a single early exit statement
            .block, .block_semicolon => {
                const extra = datas[node].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                if (end > start) {
                    // Check if any statement in the block is an early exit
                    for (start..end) |i| {
                        const stmt = tree.extra_data[i];
                        if (stmt < tags.len) {
                            switch (tags[stmt]) {
                                .@"continue", .@"break", .@"return" => return true,
                                else => {},
                            }
                        }
                    }
                }
                return false;
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = datas[node].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    const n_idx = @intFromEnum(n);
                    if (n_idx < tags.len) {
                        switch (tags[n_idx]) {
                            .@"continue", .@"break", .@"return" => return true,
                            else => {},
                        }
                    }
                }
                if (opt_nodes[1].unwrap()) |n| {
                    const n_idx = @intFromEnum(n);
                    if (n_idx < tags.len) {
                        switch (tags[n_idx]) {
                            .@"continue", .@"break", .@"return" => return true,
                            else => {},
                        }
                    }
                }
                return false;
            },
            else => false,
        };
    }

    /// Check if an unwrap is guarded by a prior assignment that guarantees non-null.
    /// Pattern: `x = foo() orelse return error;` followed by `x.?`
    /// After the assignment, x is guaranteed to be non-null because the orelse
    /// handles the null case.
    fn isGuardedByPriorAssignment(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        unwrapped_var: u32,
        parent_map: []const u32,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        // Find the containing block
        var node = unwrap_node;
        var block_node: ?u32 = null;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            if (tags[parent] == .block or tags[parent] == .block_two or
                tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
            {
                block_node = parent;
                break;
            }
            node = parent;
        }

        const block = block_node orelse return false;

        return scanBlockForPriorAssignment(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
    }

    /// Scan a block for prior assignment pattern
    fn scanBlockForPriorAssignment(
        tree: *const std.zig.Ast,
        block: u32,
        unwrap_node: u32,
        unwrapped_var: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        token_starts: []const u32,
    ) bool {
        if (block >= tags.len) return false;

        // Get position of the unwrap node
        if (unwrap_node >= main_tokens.len) return false;
        const unwrap_pos = token_starts[main_tokens[unwrap_node]];

        // Get statements from the block
        var stmts_buf: [max_block_statements]u32 = undefined;
        const stmt_count = getBlockStatements(tree, block, tags, datas, &stmts_buf) orelse return false;

        // Look for an assignment statement before the unwrap
        // Start from the statement closest to the unwrap and work backwards
        var i: usize = stmt_count;
        while (i > 0) {
            i -= 1;
            const stmt = stmts_buf[i];
            if (stmt >= tags.len) continue;
            if (stmt >= main_tokens.len) continue;

            const stmt_pos = token_starts[main_tokens[stmt]];

            // Only look at statements before the unwrap
            if (stmt_pos >= unwrap_pos) continue;

            // Check if this is an assignment to the variable
            if (tags[stmt] == .assign) {
                const lhs = @intFromEnum(datas[stmt].node_and_node[0]);
                const rhs = @intFromEnum(datas[stmt].node_and_node[1]);

                if (sameVariable(tree, lhs, unwrapped_var)) {
                    // Check if RHS is an orelse with early exit
                    if (isOrelseWithEarlyExit(rhs, tags, datas)) {
                        return true;
                    }
                    // Check if RHS is a try expression - try only succeeds with non-null value
                    if (rhs < tags.len and tags[rhs] == .@"try") {
                        return true;
                    }
                    // Check if RHS is an identifier that was assigned via `try` earlier
                    if (isNonNullIdentifier(tree, rhs, block, stmt_pos, tags, datas, main_tokens, token_starts)) {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    /// Check if an expression is an orelse with an early exit handler
    fn isOrelseWithEarlyExit(
        node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
    ) bool {
        if (node >= tags.len) return false;

        // Check for orelse expression
        if (tags[node] != .@"orelse") return false;

        // The RHS of orelse is in data[1]
        const rhs = @intFromEnum(datas[node].node_and_node[1]);
        if (rhs >= tags.len) return false;

        // Check if the RHS is an early exit
        return switch (tags[rhs]) {
            .@"return" => true,
            .@"break" => true,
            .@"continue" => true,
            // Also handle error_value for `orelse return error.Foo`
            .error_value => true,
            else => false,
        };
    }

    /// Check if an identifier was assigned a non-null value via `try` or `orelse` earlier.
    /// Pattern: `var x = try foo();` or `var x = foo() orelse return;` followed by using `x`
    fn isNonNullIdentifier(
        tree: *const std.zig.Ast,
        node: u32,
        block: u32,
        use_pos: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        token_starts: []const u32,
    ) bool {
        if (node >= tags.len) return false;

        // The node must be an identifier
        if (tags[node] != .identifier) return false;

        // Get the identifier's token text
        const ident_token = main_tokens[node];
        const ident_text = tree.tokenSlice(ident_token);

        // Scan the block for a prior declaration of this identifier with `try` or `orelse`
        var stmts_buf: [max_block_statements]u32 = undefined;
        const stmt_count = getBlockStatements(tree, block, tags, datas, &stmts_buf) orelse return false;

        for (0..stmt_count) |idx| {
            const stmt = stmts_buf[idx];
            if (stmt >= tags.len or stmt >= main_tokens.len) continue;

            const stmt_pos = token_starts[main_tokens[stmt]];
            if (stmt_pos >= use_pos) break; // Only look at statements before the use

            // Check for var decls: `var x = ...` or `const x = ...`
            if (tags[stmt] == .simple_var_decl or tags[stmt] == .local_var_decl or
                tags[stmt] == .aligned_var_decl)
            {
                // Use fullVarDecl to get the name token and init node
                const full = tree.fullVarDecl(@enumFromInt(stmt)) orelse continue;
                const name_token = full.ast.mut_token + 1;
                const token_tags = tree.tokens.items(.tag);
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const decl_name = tree.tokenSlice(name_token);
                if (std.mem.eql(u8, decl_name, ident_text)) {
                    const init_node = @intFromEnum(full.ast.init_node);
                    if (init_node != 0 and init_node < tags.len) {
                        if (tags[init_node] == .@"try") {
                            return true;
                        }
                        // Check for orelse with early exit
                        if (isOrelseWithEarlyExit(init_node, tags, datas)) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Check if an unwrap is guarded by a method call with catch/early exit.
    /// Pattern: `self.ensureX() catch return;` followed by `self.x.?`
    /// This uses interprocedural analysis to check if the method assigns to the field.
    fn isGuardedByMethodCallWithCatch(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        unwrapped_var: u32,
        parent_map: []const u32,
        fn_node: ids.AstNodeId,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        // First, check if the unwrapped variable is a field access on self (e.g., self.texture)
        if (unwrapped_var >= tags.len) return false;
        if (tags[unwrapped_var] != .field_access) return false;

        // Get the object being accessed and the field name
        const obj = @intFromEnum(datas[unwrapped_var].node_and_token[0]);
        const field_token = datas[unwrapped_var].node_and_token[1];
        const field_name = tree.tokenSlice(field_token);

        // Check if the object is `self`
        if (obj >= tags.len) return false;
        if (tags[obj] != .identifier) return false;
        const obj_name = tree.tokenSlice(main_tokens[obj]);
        if (!std.mem.eql(u8, obj_name, "self")) return false;

        // Find the containing block
        var node = unwrap_node;
        var block_node: ?u32 = null;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            if (tags[parent] == .block or tags[parent] == .block_two or
                tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
            {
                block_node = parent;
                break;
            }
            node = parent;
        }

        const block = block_node orelse return false;

        // Scan for method calls with catch before the unwrap
        return scanBlockForMethodCallWithCatch(tree, block, unwrap_node, field_name, tags, datas, main_tokens, token_starts, fn_node);
    }

    /// Scan a block for method call with catch pattern
    fn scanBlockForMethodCallWithCatch(
        tree: *const std.zig.Ast,
        block: u32,
        unwrap_node: u32,
        field_name: []const u8,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        token_starts: []const u32,
        fn_node: ids.AstNodeId,
    ) bool {
        if (block >= tags.len) return false;

        // Get position of the unwrap node
        if (unwrap_node >= main_tokens.len) return false;
        const unwrap_pos = token_starts[main_tokens[unwrap_node]];

        // Get statements from the block
        var stmts_buf: [max_block_statements]u32 = undefined;
        const stmt_count = getBlockStatements(tree, block, tags, datas, &stmts_buf) orelse return false;

        // Look for catch expressions before the unwrap
        for (stmts_buf[0..stmt_count]) |stmt| {
            if (stmt >= tags.len) continue;
            if (stmt >= main_tokens.len) continue;

            const stmt_pos = token_starts[main_tokens[stmt]];

            // Only look at statements before the unwrap
            if (stmt_pos >= unwrap_pos) continue;

            // Check if this is a catch expression with early exit handler
            if (tags[stmt] != .@"catch") continue;

            // Get the operand and handler
            const operand = @intFromEnum(datas[stmt].node_and_node[0]);
            const handler = @intFromEnum(datas[stmt].node_and_node[1]);

            // Check if handler is an early exit
            if (handler >= tags.len) continue;
            const handler_tag = tags[handler];
            if (handler_tag != .@"return" and handler_tag != .@"continue" and handler_tag != .@"break") continue;

            // Check if the operand is a method call on self
            if (!isMethodCallOnSelf(operand, tags, datas, main_tokens, tree)) continue;

            // Get the method name from the call
            const method_name = getMethodNameFromCall(operand, tags, datas, tree) orelse continue;

            // Look up the method and check if it assigns to self.field_name
            if (methodAssignsToField(tree, method_name, field_name, fn_node)) {
                return true;
            }
        }

        return false;
    }

    /// Check if a node is a method call on self (self.method(...))
    fn isMethodCallOnSelf(
        node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        tree: *const std.zig.Ast,
    ) bool {
        if (node >= tags.len) return false;

        // Node should be a call expression
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(node)) orelse return false;

        // The fn_expr should be a field_access (self.method)
        const fn_expr = @intFromEnum(full.ast.fn_expr);
        if (fn_expr >= tags.len) return false;
        if (tags[fn_expr] != .field_access) return false;

        // Get the object being accessed
        const obj = @intFromEnum(datas[fn_expr].node_and_token[0]);
        if (obj >= tags.len) return false;
        if (tags[obj] != .identifier) return false;

        // Check if it's `self`
        const obj_name = tree.tokenSlice(main_tokens[obj]);
        return std.mem.eql(u8, obj_name, "self");
    }

    /// Get the method name from a call expression
    fn getMethodNameFromCall(
        node: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        tree: *const std.zig.Ast,
    ) ?[]const u8 {
        if (node >= tags.len) return null;

        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(node)) orelse return null;

        const fn_expr = @intFromEnum(full.ast.fn_expr);
        if (fn_expr >= tags.len) return null;
        if (tags[fn_expr] != .field_access) return null;

        const method_token = datas[fn_expr].node_and_token[1];
        return tree.tokenSlice(method_token);
    }

    /// Check if a method in the same struct assigns to self.field_name
    fn methodAssignsToField(
        tree: *const std.zig.Ast,
        method_name: []const u8,
        field_name: []const u8,
        fn_node: ids.AstNodeId,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);

        // Find the struct containing this function
        // Walk up from fn_node to find container_decl
        const fn_idx = ids.astIndex(fn_node);
        if (fn_idx >= tags.len) return false;

        // Find all fn_decl nodes in the file and look for one with matching name
        for (0..tags.len) |i| {
            if (tags[i] != .fn_decl) continue;

            // Get the function prototype
            const fn_proto_idx = @intFromEnum(datas[i].node_and_node[0]);
            if (fn_proto_idx >= tags.len) continue;

            // Get the function name
            var proto_buf: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = tree.fullFnProto(&proto_buf, @enumFromInt(fn_proto_idx)) orelse continue;
            const name_token = fn_proto.name_token orelse continue;
            const fn_name = tree.tokenSlice(name_token);

            if (!std.mem.eql(u8, fn_name, method_name)) continue;

            // Found the method, now check its body for assignments to self.field_name
            const body_idx = @intFromEnum(datas[i].node_and_node[1]);
            if (body_idx == 0 or body_idx >= tags.len) continue;

            if (bodyAssignsToSelfField(tree, body_idx, field_name, tags, datas, main_tokens)) {
                return true;
            }
        }

        return false;
    }

    /// Check if a function body assigns to self.field_name
    fn bodyAssignsToSelfField(
        tree: *const std.zig.Ast,
        body: u32,
        field_name: []const u8,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
    ) bool {
        if (body >= tags.len) return false;

        return switch (tags[body]) {
            .assign => {
                // Check if LHS is self.field_name
                const lhs = @intFromEnum(datas[body].node_and_node[0]);
                return isSelfFieldAccess(lhs, field_name, tags, datas, main_tokens, tree);
            },
            .block, .block_semicolon => {
                const extra = datas[body].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                for (start..end) |i| {
                    const stmt = tree.extra_data[i];
                    if (bodyAssignsToSelfField(tree, stmt, field_name, tags, datas, main_tokens)) {
                        return true;
                    }
                }
                return false;
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = datas[body].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    if (bodyAssignsToSelfField(tree, @intFromEnum(n), field_name, tags, datas, main_tokens)) {
                        return true;
                    }
                }
                if (opt_nodes[1].unwrap()) |n| {
                    if (bodyAssignsToSelfField(tree, @intFromEnum(n), field_name, tags, datas, main_tokens)) {
                        return true;
                    }
                }
                return false;
            },
            .@"if", .if_simple => {
                const full = tree.fullIf(@enumFromInt(body)) orelse return false;
                const then_expr = @intFromEnum(full.ast.then_expr);
                if (bodyAssignsToSelfField(tree, then_expr, field_name, tags, datas, main_tokens)) {
                    return true;
                }
                if (full.ast.else_expr.unwrap()) |else_idx| {
                    const else_node = @intFromEnum(else_idx);
                    if (bodyAssignsToSelfField(tree, else_node, field_name, tags, datas, main_tokens)) {
                        return true;
                    }
                }
                return false;
            },
            else => false,
        };
    }

    /// Check if a node is self.field_name
    fn isSelfFieldAccess(
        node: u32,
        field_name: []const u8,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const u32,
        tree: *const std.zig.Ast,
    ) bool {
        if (node >= tags.len) return false;
        if (tags[node] != .field_access) return false;

        const obj = @intFromEnum(datas[node].node_and_token[0]);
        const token = datas[node].node_and_token[1];

        // Check field name
        const access_name = tree.tokenSlice(token);
        if (!std.mem.eql(u8, access_name, field_name)) return false;

        // Check if object is `self`
        if (obj >= tags.len) return false;
        if (tags[obj] != .identifier) return false;
        const obj_name = tree.tokenSlice(main_tokens[obj]);
        return std.mem.eql(u8, obj_name, "self");
    }

    /// Check if an unwrap is guarded by short-circuit evaluation or ternary if expression.
    ///
    /// Short-circuit patterns:
    /// - `a != null and a.?` - the RHS is only evaluated when a is non-null
    /// - `a == null or a.?` - the RHS is only evaluated when a is non-null
    ///
    /// Ternary if patterns:
    /// - `if (a != null) a.? else ...` - then branch is only taken when a is non-null
    /// - `if (a == null) ... else a.?` - else branch is only taken when a is non-null
    fn isGuardedByShortCircuit(
        tree: *const std.zig.Ast,
        unwrap_node: u32,
        unwrapped_var: u32,
        parent_map: []const u32,
    ) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        var node = unwrap_node;
        var depth: u32 = 0;

        while (node < parent_map.len and depth < 64) : (depth += 1) {
            const parent = parent_map[node];
            if (parent == 0 or parent >= tags.len) break;

            switch (tags[parent]) {
                .bool_and => {
                    // Pattern: `guard and expr_with_unwrap`
                    // If unwrap is in the RHS, check if LHS guards it
                    const lhs = @intFromEnum(datas[parent].node_and_node[0]);
                    const rhs = @intFromEnum(datas[parent].node_and_node[1]);
                    if (isInSubtree(tree, rhs, node) and checksNotNull(tree, lhs, unwrapped_var)) {
                        return true;
                    }
                    // For chained `and`: `a != null and b != null and a.? + b.?`
                    // Continue walking up to find more guards
                },
                .bool_or => {
                    // Pattern: `guard or expr_with_unwrap`
                    // If unwrap is in the RHS, check if LHS guards it
                    // For `a == null or a.?`, if LHS is true we short-circuit, so RHS only runs when a != null
                    const lhs = @intFromEnum(datas[parent].node_and_node[0]);
                    const rhs = @intFromEnum(datas[parent].node_and_node[1]);
                    if (isInSubtree(tree, rhs, node) and checksNull(tree, lhs, unwrapped_var)) {
                        return true;
                    }
                },
                .@"if", .if_simple => {
                    // If statement/expression: `if (cond) then else otherwise`
                    // Check if the unwrap is in a guarded branch
                    const full = tree.fullIf(@enumFromInt(parent)) orelse continue;
                    const cond = @intFromEnum(full.ast.cond_expr);
                    const then_expr = @intFromEnum(full.ast.then_expr);

                    // If unwrap is in then branch and condition is `var != null`
                    if (isInSubtree(tree, then_expr, node) and checksNotNull(tree, cond, unwrapped_var)) {
                        return true;
                    }
                    // If unwrap is in else branch and condition is `var == null`
                    if (full.ast.else_expr.unwrap()) |else_idx| {
                        const else_node = @intFromEnum(else_idx);
                        if (isInSubtree(tree, else_node, node) and checksNull(tree, cond, unwrapped_var)) {
                            return true;
                        }
                    }
                },
                else => {},
            }
            node = parent;
        }

        return false;
    }

    /// Check if target_node is within the subtree rooted at root_node
    fn isInSubtree(tree: *const std.zig.Ast, root_node: u32, target_node: u32) bool {
        if (root_node == target_node) return true;

        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        if (root_node >= tags.len) return false;

        // Simple recursive check - for binary operators and common nodes
        const tag = tags[root_node];
        switch (tag) {
            .bool_and, .bool_or, .bang_equal, .equal_equal, .add, .sub, .mul, .div => {
                const lhs = @intFromEnum(datas[root_node].node_and_node[0]);
                const rhs = @intFromEnum(datas[root_node].node_and_node[1]);
                return isInSubtree(tree, lhs, target_node) or isInSubtree(tree, rhs, target_node);
            },
            .unwrap_optional => {
                const inner = @intFromEnum(datas[root_node].node_and_token[0]);
                return isInSubtree(tree, inner, target_node);
            },
            .field_access => {
                const obj = @intFromEnum(datas[root_node].node_and_token[0]);
                return isInSubtree(tree, obj, target_node);
            },
            .grouped_expression => {
                const inner = @intFromEnum(datas[root_node].node_and_node[0]);
                return isInSubtree(tree, inner, target_node);
            },
            else => return false,
        }
    }

    /// Check if cond_node is a null check (== null) for the given variable
    fn checksNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
        return checkNullComparison(tree, cond_node, var_node, true);
    }

    /// Check if cond_node is a non-null check (!= null) for the given variable
    fn checksNotNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
        return checkNullComparison(tree, cond_node, var_node, false);
    }

    /// Check if cond_node compares var_node to null
    /// is_null_check: true for `== null`, false for `!= null`
    fn checkNullComparison(tree: *const std.zig.Ast, cond_node: u32, var_node: u32, is_null_check: bool) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (cond_node >= tags.len) return false;

        const tag = tags[cond_node];

        // Handle chained conditions: `a != null and b != null`
        // For checking if var_node is guarded, we need to find it in any part of the chain
        if (tag == .bool_and and !is_null_check) {
            // For `!= null` checks, both sides of `and` contribute guards
            const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
            const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);
            return checkNullComparison(tree, lhs, var_node, false) or
                checkNullComparison(tree, rhs, var_node, false);
        }

        if (tag == .bool_or and is_null_check) {
            // For `== null` checks, both sides of `or` contribute guards
            const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
            const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);
            return checkNullComparison(tree, lhs, var_node, true) or
                checkNullComparison(tree, rhs, var_node, true);
        }

        // Direct comparison check
        if ((tag == .equal_equal and is_null_check) or (tag == .bang_equal and !is_null_check)) {
            const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
            const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);

            const lhs_is_null = isNullIdentifier(tree, lhs);
            const rhs_is_null = isNullIdentifier(tree, rhs);

            // Check if one side is null and the other matches our variable
            if (lhs_is_null and sameVariable(tree, rhs, var_node)) return true;
            if (rhs_is_null and sameVariable(tree, lhs, var_node)) return true;
        }

        return false;
    }

    /// Check if a node is the `null` identifier
    fn isNullIdentifier(tree: *const std.zig.Ast, node: u32) bool {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (node >= tags.len) return false;
        if (tags[node] != .identifier) return false;

        const token = main_tokens[node];
        const token_slice = tree.tokenSlice(token);
        return std.mem.eql(u8, token_slice, "null");
    }

    /// Check if two nodes refer to the same variable
    fn sameVariable(tree: *const std.zig.Ast, node1: u32, node2: u32) bool {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const datas = tree.nodes.items(.data);

        if (node1 >= tags.len or node2 >= tags.len) return false;

        // Both should be identifiers or field accesses
        const tag1 = tags[node1];
        const tag2 = tags[node2];

        if (tag1 == .identifier and tag2 == .identifier) {
            const token1 = main_tokens[node1];
            const token2 = main_tokens[node2];
            const slice1 = tree.tokenSlice(token1);
            const slice2 = tree.tokenSlice(token2);
            return std.mem.eql(u8, slice1, slice2);
        }

        // Handle field access: a.b == a.b
        if (tag1 == .field_access and tag2 == .field_access) {
            const obj1 = @intFromEnum(datas[node1].node_and_token[0]);
            const obj2 = @intFromEnum(datas[node2].node_and_token[0]);
            const token1 = datas[node1].node_and_token[1];
            const token2 = datas[node2].node_and_token[1];
            const slice1 = tree.tokenSlice(token1);
            const slice2 = tree.tokenSlice(token2);
            return std.mem.eql(u8, slice1, slice2) and sameVariable(tree, obj1, obj2);
        }

        return false;
    }

    fn collectUnwrapsInSubtree(
        tree: *const std.zig.Ast,
        node: u32,
        allocator: std.mem.Allocator,
        unwraps: *std.ArrayList(u32),
    ) CheckerError!void {
        try ast_walk.collectNodesByTag(allocator, tree, node, .unwrap_optional, unwraps);
    }

    fn findCfgNodeForAst(cfg: *const Cfg, ast_node: u32, tree: *const std.zig.Ast) ?ids.CfgNodeId {
        const token_starts = tree.tokens.items(.start);
        const main_tokens = tree.nodes.items(.main_token);

        // Get the byte position of the target AST node
        if (ast_node >= main_tokens.len) return null;
        const target_pos = token_starts[main_tokens[ast_node]];

        // Find the CFG node that directly matches this AST node
        for (cfg.nodes.items, 0..) |node, idx| {
            if (node.ir_node.ast_node) |node_ast| {
                if (node_ast == ast_node) {
                    return ids.cfgId(@intCast(idx));
                }
            }
        }

        // If no direct match, find the CFG node whose AST span contains this node
        // by finding the CFG node that starts closest to (but before) the target position
        var best_match: ?ids.CfgNodeId = null;
        var best_start: u32 = 0;

        for (cfg.nodes.items, 0..) |node, idx| {
            if (node.ir_node.ast_node) |node_ast| {
                if (node_ast >= main_tokens.len) continue;

                const cfg_pos = token_starts[main_tokens[node_ast]];
                // Find CFG nodes that start at or before the target position
                // and pick the one that starts closest to the target
                if (cfg_pos <= target_pos and cfg_pos >= best_start) {
                    best_start = cfg_pos;
                    best_match = ids.cfgId(@intCast(idx));
                }
            }
        }

        return best_match;
    }

    fn isProvenNonNull(
        engine: *AnalysisEngine,
        cfg_node_idx: ids.CfgNodeId,
        unwrapped_node: u32,
        cfg: *const Cfg,
        fn_node: ids.AstNodeId,
    ) bool {
        _ = fn_node;
        // Get all states reaching this CFG node
        const graph = engine.getGraph();

        // Find the variable ID for the unwrapped expression using the engine's resolver
        const var_id = engine.resolveVarIdFromExpr(unwrapped_node, cfg);

        // Track if we found any states at this CFG node
        var found_states = false;
        var all_paths_safe = true;

        // Check all exploded nodes at this CFG location
        for (graph.nodes.items) |exploded_node| {
            if (exploded_node.point.node_index != cfg_node_idx) continue;

            found_states = true;

            // Check if this state proves the variable is non-null
            if (var_id) |vid| {
                const state = &exploded_node.state;

                // Check environment for non-null value
                if (state.getVar(vid)) |val| {
                    if (val.isNonNull()) {
                        continue; // This path is safe
                    }
                    if (!val.isUnknown() and !val.isNull()) {
                        // Concrete values (ints, bools) are non-null
                        continue;
                    }
                }

                // Check constraints for null_check with is_null=false
                if (state.hasNonNullConstraint(vid)) {
                    continue; // This path is safe
                }

                // This path has an unguarded unwrap
                all_paths_safe = false;
            } else {
                // Couldn't resolve the variable - be conservative
                all_paths_safe = false;
            }
        }

        // If we found no states at this point, be conservative
        if (!found_states) {
            return false;
        }

        return all_paths_safe;
    }

    fn reportUnsafeUnwrap(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        main_token: u32,
        token_starts: []const u32,
    ) CheckerError!void {
        if (main_token >= token_starts.len) return;

        const unwrap_offset = token_starts[main_token];
        const loc = src.byteToLocation(unwrap_offset) catch return;
        const diag = Diagnostic.initAtLocation(
            allocator,
            src.getFilePath(),
            "optional-unwrap",
            .warning,
            "forced optional unwrap can panic at runtime",
            loc.line,
            loc.column,
        ) catch return;
        try diagnostics.append(allocator, diag);
    }
};

// Tests
test "OptionalUnwrapEngineChecker initialization" {
    const testing = std.testing;
    try testing.expectEqualStrings("optional-unwrap", OptionalUnwrapEngineChecker.checker.name);
    try testing.expectEqual(checker_mod.Severity.warning, OptionalUnwrapEngineChecker.checker.default_severity);
}
