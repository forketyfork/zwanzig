const std = @import("std");
const fixture_runner = @import("fixture_runner.zig");
const runFixturesInDir = fixture_runner.runFixturesInDir;
const runCheckerFixturesInDir = fixture_runner.runCheckerFixturesInDir;

// Import all rules from the src module
const src = @import("src");
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

    const allowlist = [_][]const u8{ "unused-decl" };
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

    const allowlist = [_][]const u8{ "unused-decl" };
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
