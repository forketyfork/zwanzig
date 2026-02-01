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

            // Get the variable being unwrapped
            const unwrapped_node = @intFromEnum(datas[ast_node].node_and_token[0]);

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
