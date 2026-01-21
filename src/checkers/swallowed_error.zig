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
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;
const IrTag = cfg_mod.IrTag;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const ErrorState = engine_mod.ErrorState;

/// Engine-based checker that detects catch blocks that swallow errors.
/// An error is considered "swallowed" when:
/// - The catch block has a non-empty handler body
/// - The handler does NOT rethrow the error (return error or propagate)
/// - The handler does NOT log the error (call to std.debug/log functions)
/// - The handler simply ignores the error and continues execution
///
/// This checker uses the CFG and analysis engine to trace error handling paths
/// and identify catch handlers that swallow errors without proper handling.
pub const SwallowedErrorChecker = struct {
    pub const checker: Checker = .{
        .name = "swallowed-error",
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

            // Run the analysis engine to track error states
            var engine = AnalysisEngine.init(allocator, cfg);
            defer engine.deinit();
            engine.run() catch return;

            // Examine CFG nodes for catch_expr with swallowed errors
            for (cfg.nodes.items) |cfg_node| {
                if (cfg_node.ir_node.tag == .catch_expr) {
                    if (try isErrorSwallowed(cfg, cfg_node.index, &engine, allocator)) {
                        // Get source range from IR node
                        if (cfg_node.ir_node.source_range) |range| {
                            const message = allocator.dupe(u8, "Error is swallowed without logging or rethrowing. Consider handling the error properly.") catch return;

                            diagnostics.append(allocator, Diagnostic.init(
                                src.getFilePath(),
                                "swallowed-error",
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

    /// Check if a catch_expr swallows an error.
    /// An error is swallowed if:
    /// 1. The catch handler is non-empty (has actual statements)
    /// 2. The handler does NOT return an error
    /// 3. The handler does NOT appear to log the error
    /// 4. The handler completes normally (reaches merge point)
    fn isErrorSwallowed(cfg: *const Cfg, catch_node_idx: u32, engine: *const AnalysisEngine, allocator: std.mem.Allocator) CheckerError!bool {
        // Find the catch_error edge
        var handler_entry: ?u32 = null;
        var merge_node: ?u32 = null;

        for (cfg.edges.items) |edge| {
            if (edge.from == catch_node_idx) {
                if (edge.kind == .catch_error) {
                    handler_entry = edge.to;
                } else if (edge.kind == .catch_success) {
                    // Track the merge node (where catch_success goes)
                    merge_node = edge.to;
                }
            }
        }

        // If no handler entry, no swallowed error (empty catch is handled separately)
        const entry = handler_entry orelse return false;

        // If handler entry is directly the merge node, it's empty (not swallowed)
        // This is the correct way to detect empty handlers - comparing to merge node
        if (merge_node != null and entry == merge_node.?) {
            return false;
        }

        // Trace through the handler to see if it:
        // 1. Returns an error (good)
        // 2. Contains a call (potentially logging)
        // 3. Just falls through (swallowed error)
        var has_return = false;
        var has_call = false;
        var current_nodes: std.ArrayList(u32) = .empty;
        defer current_nodes.deinit(allocator);
        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();

        try current_nodes.append(allocator, entry);

        while (current_nodes.items.len > 0) {
            const node_idx = current_nodes.pop() orelse continue;

            if (visited.contains(node_idx)) continue;
            try visited.put(node_idx, {});

            // Stop if we reach the merge node
            if (merge_node != null and node_idx == merge_node.?) {
                continue;
            }

            const cfg_node = cfg.getNode(node_idx) orelse continue;

            switch (cfg_node.ir_node.tag) {
                .ret => {
                    has_return = true;
                },
                .call => {
                    has_call = true;
                },
                else => {},
            }

            // Find successors within the handler
            for (cfg.edges.items) |edge| {
                if (edge.from == node_idx) {
                    // Don't follow edges that leave the handler context
                    if (edge.kind != .catch_success) {
                        try current_nodes.append(allocator, edge.to);
                    }
                }
            }
        }

        // Check using the analysis engine for error state paths
        const graph = engine.getGraph();

        // Look for exploded nodes at the merge point with error_handled state
        var reaches_merge_from_error = false;
        if (merge_node) |merge| {
            for (graph.nodes.items) |exploded_node| {
                if (exploded_node.point.node_index == merge and
                    exploded_node.point.kind == .pre)
                {
                    // This node reached the merge - check if it came from error handler
                    // by looking at predecessors
                    for (exploded_node.predecessors.items) |pred_idx| {
                        if (graph.getNode(pred_idx)) |pred_node| {
                            if (pred_node.state.getErrorState() == .error_handled) {
                                reaches_merge_from_error = true;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Error is swallowed if:
        // - Handler reaches merge without return
        // - Handler doesn't have a call (potential logging)
        // - Analysis shows error path reaches normal completion
        if (!has_return and !has_call and reaches_merge_from_error) {
            return true;
        }

        // Also flag as swallowed if there's no return and no call even without engine check
        // This catches cases where the CFG structure shows a non-empty handler that
        // doesn't do anything useful
        if (!has_return and !has_call and handler_entry != merge_node) {
            // Verify the handler actually has statements by checking it's not just going to merge
            var nodes_in_handler: u32 = 0;
            var iter = visited.iterator();
            while (iter.next()) |_| {
                nodes_in_handler += 1;
            }
            // If we visited more than just the entry node, there's a handler body
            if (nodes_in_handler > 1) {
                return true;
            }
        }

        return false;
    }
};

test "swallowed_error - no diagnostic for catch that returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that returns error (not swallowed)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() !i32 {
        \\    const x = foo() catch |err| {
        \\        return err;
        \\    };
        \\    return x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for catch with call (logging)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that logs (has a call - not swallowed)
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() i32 {
        \\    const x = foo() catch |err| {
        \\        std.debug.print("Error: {}\n", .{err});
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

    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for empty catch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: empty catch (handled by empty-catch rule, not swallowed-error)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch {};
        \\    _ = x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - detects swallowed error with assignment only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that just assigns to a variable (swallowed)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() i32 {
        \\    var y: i32 = 0;
        \\    const x = foo() catch |_| {
        \\        y = 1;
        \\    };
        \\    _ = x;
        \\    return y;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("swallowed-error", diagnostics.items[0].rule_id);
}
