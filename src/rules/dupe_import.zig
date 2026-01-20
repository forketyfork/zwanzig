const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that detects duplicate @import statements in Zig code.
/// Duplicate imports can indicate copy-paste errors or redundant code.
/// This rule scans tokens to find @import("...") patterns and reports
/// when the same module is imported multiple times.
pub const DupeImportRule = struct {
    pub const rule: Rule = Rule{
        .name = "dupe-import",
        .default_severity = .warning,
        .checkFn = check,
    };

    const ImportInfo = struct {
        byte_offset: usize,
        import_path: []const u8,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const content = src.getContent();

        var seen_imports = std.StringHashMap(ImportInfo).init(allocator);
        defer seen_imports.deinit();

        var i: usize = 0;
        while (i < token_tags.len) : (i += 1) {
            if (token_tags[i] == .builtin) {
                const start = token_starts[i];
                const builtin_name = tree.tokenSlice(@intCast(i));

                if (std.mem.eql(u8, builtin_name, "@import")) {
                    const l_paren_idx = nextNonCommentToken(token_tags, i + 1) orelse continue;
                    if (token_tags[l_paren_idx] != .l_paren) continue;

                    const string_idx = nextNonCommentToken(token_tags, l_paren_idx + 1) orelse continue;
                    if (token_tags[string_idx] != .string_literal) continue;

                    const string_start = token_starts[string_idx];
                    const import_path = getStringLiteralContent(content, string_start);

                    if (seen_imports.get(import_path)) |_| {
                        const range = try src.byteRangeToSourceRange(start, start + builtin_name.len);

                        const message = allocator.dupe(u8, "Duplicate import detected. This module has already been imported earlier in the file.") catch return RuleError.OutOfMemory;

                        try diagnostics.append(allocator, Diagnostic.init(
                            src.getFilePath(),
                            "dupe-import",
                            .warning,
                            message,
                            range,
                        ));
                    } else {
                        try seen_imports.put(import_path, .{
                            .byte_offset = start,
                            .import_path = import_path,
                        });
                    }

                    i = string_idx;
                }
            }
        }
    }

    fn nextNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
        var idx = start;
        while (idx < token_tags.len) {
            const tag = token_tags[idx];
            if (tag != .container_doc_comment and tag != .doc_comment) {
                return idx;
            }
            idx += 1;
        }
        return null;
    }

    fn getStringLiteralContent(content: []const u8, start: usize) []const u8 {
        if (start >= content.len or content[start] != '"') return "";

        const content_start = start + 1;
        var end = content_start;
        while (end < content.len and content[end] != '"') {
            if (content[end] == '\\' and end + 1 < content.len) {
                end += 2;
            } else {
                end += 1;
            }
        }

        return content[content_start..end];
    }
};

test "duplicate import detection - single duplicate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const std2 = @import("std");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("dupe-import", diagnostics.items[0].rule_id);
    try testing.expectEqual(Severity.warning, diagnostics.items[0].severity);
    try testing.expectEqual(@as(usize, 2), diagnostics.items[0].range.start.line);
}

test "duplicate import detection - no duplicates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const mem = @import("mem");
        \\const fs = @import("fs");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "duplicate import detection - multiple duplicates of same module" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std1 = @import("std");
        \\const std2 = @import("std");
        \\const std3 = @import("std");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try testing.expectEqual(@as(usize, 2), diagnostics.items[0].range.start.line);
    try testing.expectEqual(@as(usize, 3), diagnostics.items[1].range.start.line);
}

test "duplicate import detection - different modules with same name in different paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const utils1 = @import("./utils.zig");
        \\const utils2 = @import("../utils.zig");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "duplicate import detection - duplicate with different paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const utils1 = @import("./utils.zig");
        \\const utils2 = @import("./utils.zig");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "duplicate import detection - mixed standard and relative imports" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const utils = @import("./utils.zig");
        \\const std2 = @import("std");
        \\const helper = @import("./helper.zig");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqual(@as(usize, 3), diagnostics.items[0].range.start.line);
}

test "duplicate import detection - empty file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 = "";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "duplicate import detection - no imports" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const x = 42;
        \\const y = x + 1;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "duplicate import detection - import in function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const std2 = @import("std");
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "duplicate import detection - with doc comments between tokens" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\/// doc comment
        \\const std2 = @import
        \\    /// another doc comment
        \\    ("std");
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try DupeImportRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}
