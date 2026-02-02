const std = @import("std");
const scan = @import("optional_unwrap/scan.zig");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;

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

            var engine = AnalysisEngine.initWithSource(allocator, cfg, src);
            defer engine.deinit();
            engine.setCheckerName("optional-unwrap");
            if (context.type_context) |type_ctx| {
                engine.setTypeContext(type_ctx);
            }
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
            try scan.scanForUnsafeUnwraps(src, allocator, diagnostics, tree, &engine, cfg, reported, fn_node);
        }
    }
};

// Tests
test "OptionalUnwrapEngineChecker initialization" {
    const testing = std.testing;
    try testing.expectEqualStrings("optional-unwrap", OptionalUnwrapEngineChecker.checker.name);
    try testing.expectEqual(checker_mod.Severity.warning, OptionalUnwrapEngineChecker.checker.default_severity);
}
