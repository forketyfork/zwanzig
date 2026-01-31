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
const UnreachableCodeChecker = src.checkers.unreachable_code_checker.UnreachableCodeChecker;
const StoreViolationsEngineChecker = src.checkers.store_violations_engine.StoreViolationsEngineChecker;

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

test "identifier_style fixtures" {
    try runFixturesInDir(std.testing.allocator, &IdentifierStyleRule.rule, "test/fixtures/identifier_style");
}

test "sentinel_alloc fixtures" {
    try runFixturesInDir(std.testing.allocator, &SentinelAllocRule.rule, "test/fixtures/sentinel_alloc");
}

test "unreachable_code_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &UnreachableCodeChecker.checker, "test/fixtures/unreachable_code_engine");
}

test "store_violations_engine fixtures" {
    try runCheckerFixturesInDir(std.testing.allocator, &StoreViolationsEngineChecker.checker, "test/fixtures/store_violations_engine");
}
