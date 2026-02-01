const std = @import("std");
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

        // Collect all unwrap_optional nodes within this function's body
        var unwraps: std.ArrayList(u32) = .empty;
        defer unwraps.deinit(allocator);

        try collectUnwrapsInSubtree(tree, fn_index, allocator, &unwraps);

        for (unwraps.items) |ast_node| {
            // Skip if already reported
            if (reported.contains(ast_node)) continue;

            // Skip unwraps inside test assertion calls (expectEqual, expectEqualStrings, etc.)
            // These are intentional - the test will panic if the value is null
            if (isInsideTestAssertion(tree, ast_node, fn_index)) continue;

            // Get the variable being unwrapped
            const unwrapped_node = @intFromEnum(datas[ast_node].node_and_token[0]);

            // Find the CFG node containing this AST node
            const cfg_node_idx = findCfgNodeForAst(cfg, ast_node, tree);
            if (cfg_node_idx == null) {
                // AST node not in CFG (possibly unreachable code) - report conservatively
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
                continue;
            }

            // Check if the variable is proven non-null at this point
            if (!isProvenNonNull(engine, cfg_node_idx.?, unwrapped_node, cfg, fn_node)) {
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
            }
        }
    }

    /// Check if an unwrap_optional AST node is inside a test assertion call.
    /// Test assertions like expectEqual, expectEqualStrings, etc. are intentional
    /// uses where a panic is acceptable (the test would fail anyway).
    fn isInsideTestAssertion(tree: *const std.zig.Ast, unwrap_node: u32, fn_root: u32) bool {
        // Walk up the AST to find if this unwrap is inside a call to a test assertion
        // We do this by checking parent nodes for call expressions
        return findParentAssertionCall(tree, unwrap_node, fn_root, 0);
    }

    fn findParentAssertionCall(tree: *const std.zig.Ast, node: u32, fn_root: u32, depth: u32) bool {
        // Limit recursion depth to avoid infinite loops
        if (depth > 20) return false;

        const tags = tree.nodes.items(.tag);

        if (node >= tags.len) return false;
        if (node == fn_root) return false;

        // Check if this node is a call to a test assertion
        switch (tags[node]) {
            .call, .call_comma, .call_one, .call_one_comma => {
                if (isTestAssertionCall(tree, node)) {
                    return true;
                }
            },
            else => {},
        }

        // Walk up to parent by checking which nodes contain this one
        // This is expensive but we limit the search depth
        for (0..tags.len) |i| {
            const parent: u32 = @intCast(i);
            if (parent == node) continue;
            if (nodeContainsChild(tree, parent, node)) {
                if (findParentAssertionCall(tree, parent, fn_root, depth + 1)) {
                    return true;
                }
            }
        }

        return false;
    }

    fn nodeContainsChild(tree: *const std.zig.Ast, parent: u32, child: u32) bool {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (parent >= tags.len) return false;

        const tag = tags[parent];
        switch (tag) {
            // Two children
            .bool_and, .bool_or, .assign, .bang_equal, .equal_equal, .@"orelse", .@"catch", .array_access => {
                const pair = datas[parent].node_and_node;
                return @intFromEnum(pair[0]) == child or @intFromEnum(pair[1]) == child;
            },
            // Single child via node
            .bool_not, .negation, .address_of, .@"try", .deref => {
                return @intFromEnum(datas[parent].node) == child;
            },
            // node_and_token
            .unwrap_optional, .grouped_expression, .field_access => {
                return @intFromEnum(datas[parent].node_and_token[0]) == child;
            },
            // Call expressions
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const full = tree.fullCall(&buf, @enumFromInt(parent)) orelse return false;
                if (@intFromEnum(full.ast.fn_expr) == child) return true;
                for (full.ast.params) |param| {
                    if (@intFromEnum(param) == child) return true;
                }
                return false;
            },
            // Builtin calls
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buf, @enumFromInt(parent)) orelse return false;
                for (params) |param| {
                    if (@intFromEnum(param) == child) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn isTestAssertionCall(tree: *const std.zig.Ast, call_node: u32) bool {
        const tags = tree.nodes.items(.tag);

        if (call_node >= tags.len) return false;

        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(call_node)) orelse return false;

        // Get the function name being called
        const fn_expr = @intFromEnum(full.ast.fn_expr);
        if (fn_expr >= tags.len) return false;

        // Handle field access: testing.expectEqual, std.testing.expect, etc.
        if (tags[fn_expr] == .field_access) {
            const field_token = tree.nodes.items(.data)[fn_expr].node_and_token[1];
            const field_name = tree.tokenSlice(field_token);
            return isTestAssertionName(field_name);
        }

        // Handle direct identifier
        if (tags[fn_expr] == .identifier) {
            const main_token = tree.nodes.items(.main_token)[fn_expr];
            const name = tree.tokenSlice(main_token);
            return isTestAssertionName(name);
        }

        return false;
    }

    fn isTestAssertionName(name: []const u8) bool {
        // Common test assertion function names
        const assertion_names = [_][]const u8{
            "expect",
            "expectEqual",
            "expectEqualStrings",
            "expectEqualSlices",
            "expectEqualDeep",
            "expectApproxEqAbs",
            "expectApproxEqRel",
            "expectError",
            "expectFmt",
            "assert",
        };
        for (assertion_names) |assertion_name| {
            if (std.mem.eql(u8, name, assertion_name)) return true;
        }
        return false;
    }

    fn collectUnwrapsInSubtree(
        tree: *const std.zig.Ast,
        node: u32,
        allocator: std.mem.Allocator,
        unwraps: *std.ArrayList(u32),
    ) CheckerError!void {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (node >= tags.len) return;

        if (tags[node] == .unwrap_optional) {
            try unwraps.append(allocator, node);
        }

        // Handle block nodes specially since they can have many children
        switch (tags[node]) {
            .block, .block_semicolon => {
                const extra_range = datas[node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                const statements = tree.extra_data[start..end];
                for (statements) |stmt| {
                    try collectUnwrapsInSubtree(tree, stmt, allocator, unwraps);
                }
                return;
            },
            else => {},
        }

        // Recursively scan child nodes
        const children = getChildNodes(tree, node);
        for (children) |child| {
            try collectUnwrapsInSubtree(tree, child, allocator, unwraps);
        }
    }

    fn getChildNodes(tree: *const std.zig.Ast, node: u32) []const u32 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (node >= tags.len) return &[_]u32{};

        // Use a static buffer for child nodes (most nodes have <= 8 children)
        const S = struct {
            threadlocal var buffer: [8]u32 = undefined;
        };

        const tag = tags[node];
        var count: usize = 0;

        switch (tag) {
            // Nodes with node_and_node data (two children)
            .bool_and, .bool_or, .assign, .bang_equal, .equal_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .add, .sub, .mul, .div, .mod, .@"orelse", .@"catch", .array_access => {
                const pair = datas[node].node_and_node;
                if (@intFromEnum(pair[0]) != 0) {
                    S.buffer[count] = @intFromEnum(pair[0]);
                    count += 1;
                }
                if (@intFromEnum(pair[1]) != 0) {
                    S.buffer[count] = @intFromEnum(pair[1]);
                    count += 1;
                }
            },

            // Nodes with single node child
            .bool_not, .negation, .address_of, .@"try", .deref, .@"defer", .@"comptime", .@"nosuspend" => {
                const child = @intFromEnum(datas[node].node);
                if (child != 0) {
                    S.buffer[count] = child;
                    count += 1;
                }
            },

            // Nodes with node_and_token data (one child node)
            .unwrap_optional, .grouped_expression, .field_access => {
                const child = @intFromEnum(datas[node].node_and_token[0]);
                if (child != 0) {
                    S.buffer[count] = child;
                    count += 1;
                }
            },

            // Return statement with optional expression
            .@"return" => {
                if (datas[node].opt_node.unwrap()) |ret_node| {
                    S.buffer[count] = @intFromEnum(ret_node);
                    count += 1;
                }
            },

            // Block statements - need to handle specially
            .block, .block_semicolon => {
                // These use extra_data range, return empty for now as they're handled separately
            },
            .block_two, .block_two_semicolon => {
                const pair = datas[node].opt_node_and_opt_node;
                if (pair[0].unwrap()) |n| {
                    S.buffer[count] = @intFromEnum(n);
                    count += 1;
                }
                if (pair[1].unwrap()) |n| {
                    S.buffer[count] = @intFromEnum(n);
                    count += 1;
                }
            },

            // Function/test declarations - get the body
            .fn_decl => {
                const body = @intFromEnum(datas[node].node_and_node[1]);
                if (body != 0) {
                    S.buffer[count] = body;
                    count += 1;
                }
            },
            .test_decl => {
                const body = @intFromEnum(datas[node].opt_token_and_node[1]);
                if (body != 0) {
                    S.buffer[count] = body;
                    count += 1;
                }
            },

            // Variable declarations
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                const full = tree.fullVarDecl(@enumFromInt(node)) orelse return S.buffer[0..0];
                if (full.ast.init_node.unwrap()) |init| {
                    S.buffer[count] = @intFromEnum(init);
                    count += 1;
                }
            },

            // If statements
            .@"if", .if_simple => {
                const full = tree.fullIf(@enumFromInt(node)) orelse return S.buffer[0..0];
                S.buffer[count] = @intFromEnum(full.ast.cond_expr);
                count += 1;
                S.buffer[count] = @intFromEnum(full.ast.then_expr);
                count += 1;
                if (full.ast.else_expr.unwrap()) |else_node| {
                    S.buffer[count] = @intFromEnum(else_node);
                    count += 1;
                }
            },

            // While loops
            .@"while", .while_simple, .while_cont => {
                const full = tree.fullWhile(@enumFromInt(node)) orelse return S.buffer[0..0];
                S.buffer[count] = @intFromEnum(full.ast.cond_expr);
                count += 1;
                S.buffer[count] = @intFromEnum(full.ast.then_expr);
                count += 1;
                if (full.ast.else_expr.unwrap()) |else_node| {
                    S.buffer[count] = @intFromEnum(else_node);
                    count += 1;
                }
                if (full.ast.cont_expr.unwrap()) |cont| {
                    S.buffer[count] = @intFromEnum(cont);
                    count += 1;
                }
            },

            // For loops
            .@"for", .for_simple => {
                const full = tree.fullFor(@enumFromInt(node)) orelse return S.buffer[0..0];
                for (full.ast.inputs) |input| {
                    if (count < S.buffer.len) {
                        S.buffer[count] = @intFromEnum(input);
                        count += 1;
                    }
                }
                S.buffer[count] = @intFromEnum(full.ast.then_expr);
                count += 1;
                if (full.ast.else_expr.unwrap()) |else_node| {
                    S.buffer[count] = @intFromEnum(else_node);
                    count += 1;
                }
            },

            // Call expressions
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const full = tree.fullCall(&buf, @enumFromInt(node)) orelse return S.buffer[0..0];
                S.buffer[count] = @intFromEnum(full.ast.fn_expr);
                count += 1;
                for (full.ast.params) |param| {
                    if (count < S.buffer.len) {
                        S.buffer[count] = @intFromEnum(param);
                        count += 1;
                    }
                }
            },

            // Switch
            .@"switch", .switch_comma => {
                const full = tree.switchFull(@enumFromInt(node));
                S.buffer[count] = @intFromEnum(full.ast.condition);
                count += 1;
                for (full.ast.cases) |case| {
                    if (count < S.buffer.len) {
                        S.buffer[count] = @intFromEnum(case);
                        count += 1;
                    }
                }
            },

            // Errdefer
            .@"errdefer" => {
                const body = @intFromEnum(datas[node].opt_token_and_node[1]);
                if (body != 0) {
                    S.buffer[count] = body;
                    count += 1;
                }
            },

            else => {
                // For other nodes, try to find children using the data union
                // This is a fallback for nodes we haven't explicitly handled
            },
        }

        return S.buffer[0..count];
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
