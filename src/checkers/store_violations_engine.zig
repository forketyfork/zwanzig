const std = @import("std");
const log = std.log.scoped(.store_violations_engine);
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const cfg_mod = @import("../cfg.zig");
const CfgBuilder = cfg_mod.CfgBuilder;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const store_mod = @import("../engine/store.zig");
const StoreViolation = store_mod.StoreViolation;

/// Engine-based checker that reports store violations (double-free, free without alloc).
pub const StoreViolationsEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "store-violations-engine",
        .default_severity = .err,
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
        var builder = CfgBuilder.init(allocator);
        var cfg_opt = builder.buildFromFn(src, fn_node) catch return;
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            var engine = AnalysisEngine.initWithSource(allocator, cfg, src);
            defer engine.deinit();
            engine.setMaxWorklistSteps(100_000);
            engine.setCheckerName("store-violations-engine");
            if (context.build_metadata) |metadata| {
                engine.setBuildMetadata(metadata);
            }
            engine.run() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AnalysisLimitExceeded => return,
            };

            var reported: std.ArrayList(StoreViolation) = .empty;
            defer reported.deinit(allocator);

            for (engine.getGraph().nodes.items) |node| {
                for (node.state.getStoreViolations()) |violation| {
                    if (isReported(reported.items, violation)) continue;
                    try reported.append(allocator, violation);
                    try emitViolationDiagnostic(src, allocator, diagnostics, violation);
                }
            }
        }
    }

    fn isReported(reported: []const StoreViolation, violation: StoreViolation) bool {
        for (reported) |existing| {
            if (existing.eql(violation)) return true;
        }
        return false;
    }

    fn emitViolationDiagnostic(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        violation: StoreViolation,
    ) CheckerError!void {
        const message = switch (violation.kind) {
            .double_free => "double-free detected for resource",
            .free_without_alloc => return,
        };

        const loc = src.tokenLocation(ids.varIndex(violation.region)) catch |err| {
            log.warn("failed to map store violation location: {}", .{err});
            return;
        };

        const diag = Diagnostic.initAtLocation(
            allocator,
            src.getFilePath(),
            "store-violations-engine",
            .err,
            message,
            loc.line,
            loc.column,
        ) catch return;

        diagnostics.append(allocator, diag) catch return;
    }
};

test "store_violations_engine reports double free" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.alloc(u8, 1);
        \\    allocator.free(ptr);
        \\    allocator.free(ptr);
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try StoreViolationsEngineChecker.checker.checkAst(&source, allocator, &diagnostics, .{ .build_metadata = null, .type_context = null });
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("store-violations-engine", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "double-free") != null);
}
