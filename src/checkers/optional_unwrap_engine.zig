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

        for (0..tags.len) |i| {
            if (tags[i] == .fn_decl) {
                try analyzeFunction(src, allocator, ids.astId(@intCast(i)), diagnostics, context);
            }
        }
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: ids.AstNodeId,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
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
            try scanForUnsafeUnwraps(src, allocator, diagnostics, tree, &engine, cfg);
        }
    }

    fn scanForUnsafeUnwraps(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        engine: *const AnalysisEngine,
        cfg: *const Cfg,
    ) CheckerError!void {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);
        const datas = tree.nodes.items(.data);

        // Track reported locations to avoid duplicates
        var reported: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(allocator);
        defer reported.deinit();

        for (tags, 0..) |tag, i| {
            if (tag != .unwrap_optional) continue;

            const ast_node: u32 = @intCast(i);

            // Skip if already reported
            if (reported.contains(ast_node)) continue;

            // Get the variable being unwrapped
            const unwrapped_node = @intFromEnum(datas[ast_node].node_and_token[0]);

            // Find the CFG node containing this AST node
            const cfg_node_idx = findCfgNodeForAst(cfg, ast_node);
            if (cfg_node_idx == null) {
                // AST node not in CFG (possibly unreachable code) - report conservatively
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
                continue;
            }

            // Check if the variable is proven non-null at this point
            if (!isProvenNonNull(engine, cfg_node_idx.?, unwrapped_node, tree, cfg)) {
                try reportUnsafeUnwrap(src, allocator, diagnostics, main_tokens[ast_node], token_starts);
                try reported.put(ast_node, {});
            }
        }
    }

    fn findCfgNodeForAst(cfg: *const Cfg, ast_node: u32) ?ids.CfgNodeId {
        for (cfg.nodes.items, 0..) |node, idx| {
            if (node.ir_node.ast_node) |node_ast| {
                if (node_ast == ast_node) {
                    return ids.cfgId(@intCast(idx));
                }
            }
            // Also check if the AST node is contained in the expression represented by this CFG node
            if (containsAstNode(cfg, node.ir_node.ast_node, ast_node)) {
                return ids.cfgId(@intCast(idx));
            }
        }
        return null;
    }

    fn containsAstNode(cfg: *const Cfg, parent: ?u32, target: u32) bool {
        _ = cfg;
        // Simple containment check - in practice we'd need to walk the AST
        if (parent == null) return false;
        return parent.? == target;
    }

    fn isProvenNonNull(
        engine: *const AnalysisEngine,
        cfg_node_idx: ids.CfgNodeId,
        unwrapped_node: u32,
        tree: *const std.zig.Ast,
        cfg: *const Cfg,
    ) bool {
        // Get all states reaching this CFG node
        const graph = engine.getGraph();
        const tags = tree.nodes.items(.tag);

        // Find the variable ID for the unwrapped expression
        const var_id = resolveVarId(unwrapped_node, tree, cfg);

        // Check all exploded nodes at this CFG location
        for (graph.nodes.items) |exploded_node| {
            if (exploded_node.point.node_index != cfg_node_idx) continue;

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

                // This path has an unguarded unwrap - but we only report if ALL paths are unsafe
                // For now, be conservative and check if ANY path is unsafe
            }

            // Check if unwrapped expression is in a comparison context
            // e.g., if the parent is `.if` and the condition checks this variable
            if (isInGuardedContext(unwrapped_node, tree, tags)) {
                continue;
            }

            // Found an unsafe path - report it
            return false;
        }

        // If we found no states at this point, be conservative
        if (graph.nodes.items.len == 0) {
            return false;
        }

        return true;
    }

    fn resolveVarId(node: u32, tree: *const std.zig.Ast, cfg: *const Cfg) ?ids.VarId {
        _ = cfg;
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (node >= tags.len) return null;

        if (tags[node] == .identifier) {
            return ids.varId(main_tokens[node]);
        }

        return null;
    }

    fn isInGuardedContext(node: u32, tree: *const std.zig.Ast, tags: []const std.zig.Ast.Node.Tag) bool {
        _ = tree;
        // Simple heuristic: if the unwrap is inside an if's then-block where
        // the condition is a null check on the same variable, it's guarded.
        // This is a simplified check - full implementation would trace control flow.
        _ = node;
        _ = tags;
        return false;
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
