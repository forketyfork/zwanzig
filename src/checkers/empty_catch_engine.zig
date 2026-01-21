const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Severity = checker_mod.Severity;
const Source = @import("../source.zig").Source;
const cfg_mod = @import("../cfg.zig");
const CfgBuilder = cfg_mod.CfgBuilder;
const Cfg = cfg_mod.Cfg;
const IrTag = cfg_mod.IrTag;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;

/// Engine-based checker that detects empty catch blocks using CFG and ProgramState.
/// This checker uses control-flow analysis to identify catch expressions where the
/// error handler body is empty (no statements).
///
/// Unlike the AST-based empty_catch rule, this checker:
/// - Uses CFG structure to identify catch nodes and their handlers
/// - Leverages the analysis engine's error state tracking
/// - Can be extended to support more sophisticated error-handling patterns
pub const EmptyCatchEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "empty-catch-engine",
        .default_severity = .warning,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        // Find all function declarations and analyze each one
        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .fn_decl) {
                try analyzeFunction(src, allocator, @intCast(i), diagnostics);
            }
        }
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: u32,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        var builder = CfgBuilder.init(allocator);

        // Build CFG for the function
        var cfg_opt = builder.buildFromFn(src, fn_node) catch return;
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            // Run the analysis engine
            var engine = AnalysisEngine.init(allocator, cfg);
            defer engine.deinit();
            engine.run() catch return;

            // Examine CFG nodes for catch_expr with empty handlers
            for (cfg.nodes.items) |cfg_node| {
                if (cfg_node.ir_node.tag == .catch_expr) {
                    if (hasEmptyHandler(cfg, cfg_node.index)) {
                        // Get source range from IR node
                        if (cfg_node.ir_node.source_range) |range| {
                            const message = allocator.dupe(u8, "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.") catch return;

                            diagnostics.append(allocator, Diagnostic.init(
                                src.getFilePath(),
                                "empty-catch-engine",
                                .warning,
                                message,
                                range,
                            )) catch return;
                        }
                    }
                }
            }
        }
    }

    /// Check if a catch_expr node has an empty handler.
    /// A catch handler is considered empty if the catch_error edge goes directly
    /// to the same merge node as catch_success (no intervening handler nodes).
    fn hasEmptyHandler(cfg: *const Cfg, catch_node_idx: u32) bool {
        // Find both catch_error and catch_success targets
        var catch_error_target: ?u32 = null;
        var catch_success_target: ?u32 = null;

        for (cfg.edges.items) |edge| {
            if (edge.from == catch_node_idx) {
                if (edge.kind == .catch_error) {
                    catch_error_target = edge.to;
                } else if (edge.kind == .catch_success) {
                    catch_success_target = edge.to;
                }
            }
        }

        // Empty handler: catch_error goes directly to the same merge node as catch_success
        if (catch_error_target != null and catch_success_target != null) {
            return catch_error_target.? == catch_success_target.?;
        }
        return false;
    }
};

test "empty_catch_engine - detects empty catch via CFG" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: empty catch block
    const code1: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch {};
        \\    _ = x;
        \\}
    ;
    var source1 = Source.init(allocator, "test.zig", code1);
    defer source1.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try EmptyCatchEngineChecker.checker.checkAst(&source1, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("empty-catch-engine", diagnostics.items[0].rule_id);
}

test "empty_catch_engine - no diagnostic for non-empty catch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: non-empty catch block
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() i32 {
        \\    const x = foo() catch {
        \\        return 0;
        \\    };
        \\    return x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "empty_catch_engine - detects catch with capture but empty body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch with error capture but empty body
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch |_| {};
        \\    _ = x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}
