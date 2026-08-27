const std = @import("std");
const fixture_runner = @import("fixture_runner.zig");
const runFixturesInDir = fixture_runner.runFixturesInDir;
const runCheckerFixturesInDir = fixture_runner.runCheckerFixturesInDir;

// Import all rules from the src module
const src = @import("src");
const compat = src.compat;
const DupeImportRule = src.rules.dupe_import.DupeImportRule;
const TodoCommentRule = src.rules.todo_comment.TodoCommentRule;
const EmptyErrdeferRule = src.rules.empty_errdefer.EmptyErrdeferRule;
const EmptyDeferRule = src.rules.empty_defer.EmptyDeferRule;
const UnreachableCodeRule = src.rules.unreachable_code.UnreachableCodeRule;
const FileAsStructRule = src.rules.file_as_struct.FileAsStructRule;
const UnusedDeclRule = src.rules.unused_decl.UnusedDeclRule;
const ShadowedVariableRule = src.rules.shadowed_variable.ShadowedVariableRule;
const IdentifierStyleRule = src.rules.identifier_style.IdentifierStyleRule;
const SentinelAllocRule = src.rules.sentinel_alloc.SentinelAllocRule;
const UnusedParameterRule = src.rules.unused_parameter.UnusedParameterRule;
const ReturnLocalPointerRule = src.rules.return_local_pointer.ReturnLocalPointerRule;
const DeinitLifecycleRule = src.rules.deinit_lifecycle.DeinitLifecycleRule;
const OptionalUnwrapEngineChecker = src.checkers.optional_unwrap_engine.OptionalUnwrapEngineChecker;
const UnreachableCodeChecker = src.checkers.unreachable_code_checker.UnreachableCodeChecker;
const StoreViolationsEngineChecker = src.checkers.store_violations_engine.StoreViolationsEngineChecker;
const StackEscapeEngineChecker = src.checkers.stack_escape_engine.StackEscapeEngineChecker;
const DivideByZeroEngineChecker = src.checkers.divide_by_zero_engine.DivideByZeroEngineChecker;
const SliceBoundsEngineChecker = src.checkers.slice_bounds_engine.SliceBoundsEngineChecker;

fn frontendFixtureName(frontend: compat.Frontend) []const u8 {
    return switch (frontend) {
        .zig_0_15 => "zig_0_15.zig",
        .zig_0_16 => "zig_0_16.zig",
    };
}

fn runFrontendTypeInfoFixture(
    allocator: std.mem.Allocator,
    fixture_name: []const u8,
    expected_type_info: bool,
) !void {
    const io_context = compat.defaultContext();
    const fixture_path = try std.fmt.allocPrint(allocator, "test/fixtures/frontend_matrix/{s}", .{fixture_name});
    defer allocator.free(fixture_path);

    const content = try compat.readFileAlloc(io_context, allocator, fixture_path, 1024 * 1024);
    defer allocator.free(content);

    var source = src.Source.init(allocator, fixture_path, content);
    defer source.deinit();

    try std.testing.expectEqual(expected_type_info, source.hasTypeInfo());
}

test "frontend matrix preserves shared rule diagnostics" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();
    const fixture_path = "test/fixtures/frontend_matrix/shared.zig";
    const content = try compat.readFileAlloc(io_context, allocator, fixture_path, 1024 * 1024);
    defer allocator.free(content);

    try fixture_runner.runFixture(allocator, &TodoCommentRule.rule, fixture_path, content);
}

test "frontend matrix provides type information only for the matching frontend" {
    const allocator = std.testing.allocator;
    const matching_fixture = frontendFixtureName(compat.frontend);
    const mismatching_fixture = frontendFixtureName(switch (compat.frontend) {
        .zig_0_15 => .zig_0_16,
        .zig_0_16 => .zig_0_15,
    });

    try runFrontendTypeInfoFixture(allocator, matching_fixture, true);
    try runFrontendTypeInfoFixture(allocator, mismatching_fixture, false);
}

test "dupe_import fixtures" {
    try runFixturesInDir(std.testing.allocator, &DupeImportRule.rule, "test/fixtures/dupe_import");
}

test "todo_comment fixtures" {
    try runFixturesInDir(std.testing.allocator, &TodoCommentRule.rule, "test/fixtures/todo_comment");
}

test "empty_errdefer fixtures" {
    try runFixturesInDir(std.testing.allocator, &EmptyErrdeferRule.rule, "test/fixtures/empty_errdefer");
}

test "empty_defer fixtures" {
    try runFixturesInDir(std.testing.allocator, &EmptyDeferRule.rule, "test/fixtures/empty_defer");
}

test "unreachable_code fixtures" {
    try runFixturesInDir(std.testing.allocator, &UnreachableCodeRule.rule, "test/fixtures/unreachable_code");
}

test "file_as_struct fixtures" {
    try runFixturesInDir(std.testing.allocator, &FileAsStructRule.rule, "test/fixtures/file_as_struct");
}

test "unused_decl fixtures" {
    try runFixturesInDir(std.testing.allocator, &UnusedDeclRule.rule, "test/fixtures/unused_decl");
}

test "shadowed_variable fixtures" {
    try runFixturesInDir(std.testing.allocator, &ShadowedVariableRule.rule, "test/fixtures/shadowed_variable");
}

test "project-wide unused declarations" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/main.zig",
        "test/fixtures/project_unused_decl/api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expectEqualStrings("unused-decl", analyzer.diagnostics.items[0].rule_id);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unusedByProject") != null);
}

test "project-wide unused declarations ignore duplicate names and paths" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/duplicate_a.zig",
        "test/fixtures/project_unused_decl/duplicate_a.zig",
        "test/fixtures/project_unused_decl/duplicate_b.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 2), analyzer.diagnostics.items.len);
    try std.testing.expectEqualStrings("test/fixtures/project_unused_decl/duplicate_a.zig", analyzer.diagnostics.items[0].file_path);
    try std.testing.expectEqualStrings("test/fixtures/project_unused_decl/duplicate_b.zig", analyzer.diagnostics.items[1].file_path);
}

test "project-wide unused declarations ignore public aliases" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/alias.zig",
        "test/fixtures/project_unused_decl/alias_inner.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 2), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "RegularType") != null);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[1].message, "unusedFunction") != null);
}

test "project-wide unused declarations follow public API surfaces" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/api_surface_main.zig",
        "test/fixtures/project_unused_decl/api_surface.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 2), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unusedApi") != null);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[1].message, "unusedFunction") != null);
}

test "project-wide unused declarations ignore package API entrypoints" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/build.zig",
        "test/fixtures/project_unused_decl/src/lib.zig",
        "test/fixtures/project_unused_decl/src/public_api.zig",
        "test/fixtures/project_unused_decl/src/private_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "hiddenUnused") != null);
}

test "project-wide unused declarations ignore package usingnamespace entrypoints" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/usingnamespace_pkg/build.zig",
        "test/fixtures/project_unused_decl/usingnamespace_pkg/src/lib.zig",
        "test/fixtures/project_unused_decl/usingnamespace_pkg/src/public_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 0), analyzer.diagnostics.items.len);
}

test "project-wide unused declarations use build root source file" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/custom_root_pkg/build.zig",
        "test/fixtures/project_unused_decl/custom_root_pkg/custom_root.zig",
        "test/fixtures/project_unused_decl/custom_root_pkg/custom_public_api.zig",
        "test/fixtures/project_unused_decl/custom_root_pkg/custom_private.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expectEqualStrings("test/fixtures/project_unused_decl/custom_root_pkg/custom_private.zig", analyzer.diagnostics.items[0].file_path);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "hiddenUnused") != null);
}

test "project-wide unused declarations ignore duplicate-only inputs" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/duplicate_a.zig",
        "test/fixtures/project_unused_decl/duplicate_a.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 0), analyzer.diagnostics.items.len);
}

test "project-wide unused declarations follow typed receiver calls" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/typed_receiver_main.zig",
        "test/fixtures/project_unused_decl/typed_receiver_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unused") != null);
}

test "project-wide unused declarations follow result-location method calls" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/result_location_main.zig",
        "test/fixtures/project_unused_decl/result_location_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unused") != null);
}

test "project-wide unused declarations normalize quoted identifiers" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/quoted_main.zig",
        "test/fixtures/project_unused_decl/quoted_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unused-name") != null);
}

test "project-wide unused declarations ignore externally visible and special public declarations" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/ignored_publics.zig",
        "test/fixtures/project_unused_decl/ignored_publics_main.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 0), analyzer.diagnostics.items.len);
}

test "project-wide unused declarations ignore unrelated field accesses" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/unrelated_field_main.zig",
        "test/fixtures/project_unused_decl/unrelated_field_api.zig",
        "test/fixtures/project_unused_decl/unrelated_field_other.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expectEqualStrings("test/fixtures/project_unused_decl/unrelated_field_api.zig", analyzer.diagnostics.items[0].file_path);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "init") != null);
}

test "project-wide unused declarations follow nested public API surfaces" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/nested_surface_main.zig",
        "test/fixtures/project_unused_decl/nested_surface.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "UnusedNestedHelper") != null);
}

test "project-wide unused declarations follow tagged union public API surfaces" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/union_surface_main.zig",
        "test/fixtures/project_unused_decl/union_surface.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "UnusedUnionHelper") != null);
}

test "project-wide unused declarations count same-file function body references" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/body_surface_main.zig",
        "test/fixtures/project_unused_decl/body_surface.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 0), analyzer.diagnostics.items.len);
}

test "project-wide unused declarations report public constants copied from values" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/value_alias.zig",
        "test/fixtures/project_unused_decl/value_alias_main.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 2), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "DefaultTimeoutMs") != null);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[1].message, "DefaultLimit") != null);
}

test "project-wide unused declarations follow usingnamespace bare references" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/usingnamespace_main.zig",
        "test/fixtures/project_unused_decl/usingnamespace_api.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "unused") != null);
}

test "project-wide unused declarations classify error sets as types" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/error_set_api.zig",
        "test/fixtures/project_unused_decl/error_set_main.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 1), analyzer.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.diagnostics.items[0].message, "Type 'ApiError'") != null);
}

test "project-wide unused declarations honor suppressions" {
    var analyzer = src.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    const files = [_][]const u8{
        "test/fixtures/project_unused_decl/suppressed_api.zig",
        "test/fixtures/project_unused_decl/suppressed_main.zig",
    };
    try analyzer.analyzeProjectUnusedDecls(&files);

    try std.testing.expectEqual(@as(usize, 0), analyzer.diagnostics.items.len);
}

test "identifier_style fixtures" {
    try runFixturesInDir(std.testing.allocator, &IdentifierStyleRule.rule, "test/fixtures/identifier_style");
}

test "sentinel_alloc fixtures" {
    try runFixturesInDir(std.testing.allocator, &SentinelAllocRule.rule, "test/fixtures/sentinel_alloc");
}

test "unused_parameter fixtures" {
    try runFixturesInDir(std.testing.allocator, &UnusedParameterRule.rule, "test/fixtures/unused_parameter");
}

test "return_local_ptr fixtures" {
    try runFixturesInDir(std.testing.allocator, &ReturnLocalPointerRule.rule, "test/fixtures/return_local_ptr");
}

test "deinit_lifecycle fixtures" {
    try runFixturesInDir(std.testing.allocator, &DeinitLifecycleRule.rule, "test/fixtures/deinit_lifecycle");
}

test "optional_unwrap fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &OptionalUnwrapEngineChecker.checker, "test/fixtures/optional_unwrap");
}

test "unreachable_code_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &UnreachableCodeChecker.checker, "test/fixtures/unreachable_code_engine");
}

test "store_violations_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &StoreViolationsEngineChecker.checker, "test/fixtures/store_violations_engine");
}

test "stack_escape_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &StackEscapeEngineChecker.checker, "test/fixtures/stack_escape_engine");
}

test "divide_by_zero_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &DivideByZeroEngineChecker.checker, "test/fixtures/divide_by_zero_engine");
}

test "slice_bounds_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &SliceBoundsEngineChecker.checker, "test/fixtures/slice_bounds_engine");
}
