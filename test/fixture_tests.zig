const std = @import("std");
const fixture_runner = @import("fixture_runner.zig");
const runFixturesInDir = fixture_runner.runFixturesInDir;

// Import all rules
const EmptyCatchRule = @import("../src/rules/empty_catch.zig").EmptyCatchRule;
const DupeImportRule = @import("../src/rules/dupe_import.zig").DupeImportRule;
const TodoCommentRule = @import("../src/rules/todo_comment.zig").TodoCommentRule;
const EmptyErrdeferRule = @import("../src/rules/empty_errdefer.zig").EmptyErrdeferRule;
const EmptyDeferRule = @import("../src/rules/empty_defer.zig").EmptyDeferRule;
const UnreachableCodeRule = @import("../src/rules/unreachable_code.zig").UnreachableCodeRule;
const FileAsStructRule = @import("../src/rules/file_as_struct.zig").FileAsStructRule;
const UnusedDeclRule = @import("../src/rules/unused_decl.zig").UnusedDeclRule;

test "empty_catch fixtures" {
    try runFixturesInDir(std.testing.allocator, &EmptyCatchRule.rule, "test/fixtures/empty_catch");
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
