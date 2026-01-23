const std = @import("std");
const fixture_runner = @import("fixture_runner.zig");
const runFixturesInDir = fixture_runner.runFixturesInDir;

// Import all rules from the src module
const src = @import("src");
const DupeImportRule = src.rules.dupe_import.DupeImportRule;
const TodoCommentRule = src.rules.todo_comment.TodoCommentRule;
const EmptyErrdeferRule = src.rules.empty_errdefer.EmptyErrdeferRule;
const EmptyDeferRule = src.rules.empty_defer.EmptyDeferRule;
const UnreachableCodeRule = src.rules.unreachable_code.UnreachableCodeRule;
const FileAsStructRule = src.rules.file_as_struct.FileAsStructRule;
const UnusedDeclRule = src.rules.unused_decl.UnusedDeclRule;

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
