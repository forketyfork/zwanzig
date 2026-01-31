const std = @import("std");
const log = std.log.scoped(.store_violations_engine);
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const TypeContext = @import("../type_context.zig").TypeContext;
const config_mod = @import("../config.zig");
const Config = config_mod.Config;
const ResourceModel = config_mod.ResourceModel;
const ids = @import("../ids.zig");
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
        var builder = context.createCfgBuilder(allocator);
        var cfg_opt = builder.buildFromFn(src, fn_node) catch return;
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            // Create a TypeContext for type-aware analysis
            var type_ctx = TypeContext.init(allocator, src);
            defer type_ctx.deinit();

            var engine = AnalysisEngine.initWithSource(allocator, cfg, src);
            defer engine.deinit();
            engine.setCheckerName("store-violations-engine");
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
            .free_without_alloc => "free without tracked allocation",
            .double_close => "double-close detected for resource",
            .close_without_open => "close without tracked open",
            .use_after_free => "use after free",
            .use_after_close => "use after close",
            .resource_leak => "resource leak: allocation or open not released",
        };

        const token = violation.call_token orelse ids.varIndex(violation.region);
        const loc = src.tokenLocation(token) catch |err| {
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

test "store_violations_engine reports free without alloc" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    var buf = [_]u8{0};
        \\    var ptr = buf[0..];
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
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "free without tracked allocation") != null);
}

test "store_violations_engine reports use after free" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.alloc(u8, 1);
        \\    allocator.free(ptr);
        \\    _ = ptr;
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
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "use after free") != null);
}

test "store_violations_engine reports leak" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.alloc(u8, 1);
        \\    _ = ptr;
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
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "resource leak") != null);
}

test "store_violations_engine detects config-driven resource model" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const MyPool = struct {
        \\    fn acquire(_: *MyPool) i32 { return 42; }
        \\};
        \\fn foo() void {
        \\    var pool = MyPool{};
        \\    var res = pool.acquire();
        \\    // Missing pool.release(res) - should detect as leak based on config model
        \\    _ = res;
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

    // Create a config with a custom resource model that treats "acquire" as an open
    const cfg = Config{
        .rule_filter = .none,
        .resource_models = &.{
            ResourceModel{ .kind = .open, .method_name = "acquire", .receiver_type = "MyPool" },
        },
    };

    const context = checker_mod.CheckerContext{
        .build_metadata = null,
        .type_context = null,
        .config = &cfg,
    };
    try StoreViolationsEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    // Should detect a leak because acquire() is recognized as an open based on config
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("store-violations-engine", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "resource leak") != null);
}

test "store_violations_engine detects config-driven fqn model with field access chain" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const MyPool = struct {
        \\    fn acquire(_: *MyPool) i32 { return 42; }
        \\};
        \\const Context = struct {
        \\    pool: MyPool,
        \\};
        \\fn foo() void {
        \\    var ctx = Context{ .pool = MyPool{} };
        \\    const res = ctx.pool.acquire();
        \\    _ = res;
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

    const cfg = Config{
        .rule_filter = .none,
        .resource_models = &.{
            ResourceModel{ .kind = .open, .fqn = "ctx.pool.acquire" },
        },
    };

    const context = checker_mod.CheckerContext{
        .build_metadata = null,
        .type_context = null,
        .config = &cfg,
    };
    try StoreViolationsEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("store-violations-engine", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "resource leak") != null);
}
