const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that detects empty catch blocks in Zig code
/// Empty catch blocks silently ignore errors which is usually a bad practice
pub const EmptyCatchRule = struct {
    pub const rule: Rule = Rule{
        .name = "empty-catch",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const source = src.getContent();
        const file_path = src.getFilePath();
        var line: usize = 1;
        var column: usize = 1;
        var i: usize = 0;

        while (i < source.len) {
            const current = source[i];

            // Track line and column
            if (current == '\n') {
                line += 1;
                column = 1;
                i += 1;
                continue;
            }

            // Look for "catch" keyword
            if (i + 5 <= source.len and std.mem.eql(u8, source[i .. i + 5], "catch")) {
                // Make sure it's a whole word (not part of another identifier)
                const is_word_start = i == 0 or !isIdentifierChar(source[i - 1]);
                const is_word_end = i + 5 >= source.len or !isIdentifierChar(source[i + 5]);

                if (is_word_start and is_word_end) {
                    // Found "catch" keyword, now look for the block
                    const catch_line = line;
                    const catch_column = column;
                    var j = i + 5;

                    // Skip whitespace and potential |err| capture
                    while (j < source.len and isWhitespace(source[j])) : (j += 1) {}

                    // Check for optional error capture |err|
                    if (j < source.len and source[j] == '|') {
                        j += 1;
                        // Skip until we find the closing | (with bounds check)
                        while (j < source.len and source[j] != '|') : (j += 1) {}
                        if (j >= source.len) {
                            // Malformed: no closing | found, skip this catch
                            continue;
                        }
                        j += 1; // Skip the closing |

                        // Skip more whitespace
                        while (j < source.len and isWhitespace(source[j])) : (j += 1) {}
                    }

                    // Now we should be at the opening brace
                    if (j < source.len and source[j] == '{') {
                        // Check if the block is empty (only whitespace between { and })
                        var is_empty = true;
                        var found_closing_brace = false;
                        var k = j + 1;
                        while (k < source.len) {
                            const ch = source[k];
                            if (ch == '}') {
                                // Found closing brace
                                found_closing_brace = true;
                                if (is_empty) {
                                    try diagnostics.append(allocator, Diagnostic.initAtLocation(
                                        file_path,
                                        "empty-catch",
                                        .warning,
                                        "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.",
                                        catch_line,
                                        catch_column,
                                    ));
                                }
                                break;
                            }

                            if (isWhitespace(ch)) {
                                k += 1;
                                continue;
                            }

                            if (ch == '/' and k + 1 < source.len) {
                                const next = source[k + 1];
                                if (next == '/') {
                                    k += 2;
                                    while (k < source.len and source[k] != '\n') : (k += 1) {}
                                    continue;
                                }
                                if (next == '*') {
                                    k += 2;
                                    while (k + 1 < source.len and !(source[k] == '*' and source[k + 1] == '/')) : (k += 1) {}
                                    if (k + 1 < source.len) {
                                        k += 2;
                                    } else {
                                        k = source.len;
                                    }
                                    continue;
                                }
                            }

                            // Found non-whitespace content
                            is_empty = false;
                            k += 1;
                        }

                        // If we found a closing brace, move main loop past it
                        // If not (malformed code), j is already at end of source, which is safe
                        if (found_closing_brace) {
                            const skip_to = k + 1;
                            advancePosition(source, i, skip_to, &line, &column);
                            i = skip_to;
                            continue;
                        }
                    }
                }
            }

            i += 1;
            column += 1;
        }
    }

    fn advancePosition(source: []const u8, start: usize, target: usize, line: *usize, column: *usize) void {
        var idx = start;
        const end = @min(target, source.len);
        while (idx < end) : (idx += 1) {
            if (source[idx] == '\n') {
                line.* += 1;
                column.* = 1;
            } else {
                column.* += 1;
            }
        }
    }

    fn isIdentifierChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

test "empty catch block detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    // Test case 1: Empty catch block
    const code1: [:0]const u8 =
        \\const x = try_func() catch {};
    ;
    var source1 = Source.init(allocator, "test.zig", code1);
    defer source1.deinit();
    try EmptyCatchRule.rule.check(&source1, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqual(@as(usize, 1), diagnostics.items[0].range.start.line);
    try testing.expectEqual(@as(usize, 22), diagnostics.items[0].range.start.column);
    try testing.expectEqual(Severity.warning, diagnostics.items[0].severity);
    try testing.expectEqualStrings("empty-catch", diagnostics.items[0].rule_id);

    diagnostics.clearRetainingCapacity();

    // Test case 2: Non-empty catch block
    const code2: [:0]const u8 =
        \\const x = try_func() catch {
        \\    std.debug.print("Error occurred\n", .{});
        \\};
    ;
    var source2 = Source.init(allocator, "test.zig", code2);
    defer source2.deinit();
    try EmptyCatchRule.rule.check(&source2, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    diagnostics.clearRetainingCapacity();

    // Test case 3: Comment-only catch block
    const code3: [:0]const u8 =
        \\const x = try_func() catch {
        \\    // intentionally ignored
        \\};
    ;
    var source3 = Source.init(allocator, "test.zig", code3);
    defer source3.deinit();
    try EmptyCatchRule.rule.check(&source3, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);

    diagnostics.clearRetainingCapacity();

    // Test case 4: Catch with error capture but empty body
    const code4: [:0]const u8 =
        \\const x = try_func() catch |err| {};
    ;
    var source4 = Source.init(allocator, "test.zig", code4);
    defer source4.deinit();
    try EmptyCatchRule.rule.check(&source4, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);

    diagnostics.clearRetainingCapacity();

    // Test case 5: Multiple catches
    const code5: [:0]const u8 =
        \\const x = try_func() catch {};
        \\const y = another_func() catch {
        \\    return error.Failed;
        \\};
        \\const z = third_func() catch {};
    ;
    var source5 = Source.init(allocator, "test.zig", code5);
    defer source5.deinit();
    try EmptyCatchRule.rule.check(&source5, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 2), diagnostics.items.len);

    diagnostics.clearRetainingCapacity();

    // Test case 6: Line tracking after skipping a block
    const code6: [:0]const u8 =
        \\const x = try_func() catch {
        \\    // intentionally ignored
        \\};
        \\const y = another_func() catch {};
    ;
    var source6 = Source.init(allocator, "test.zig", code6);
    defer source6.deinit();
    try EmptyCatchRule.rule.check(&source6, allocator, &diagnostics);
    try testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try testing.expectEqual(@as(usize, 4), diagnostics.items[1].range.start.line);

    diagnostics.clearRetainingCapacity();

    // Test case 7: Malformed code - missing closing brace (should not crash)
    const code7: [:0]const u8 =
        \\const x = try_func() catch {
    ;
    var source7 = Source.init(allocator, "test.zig", code7);
    defer source7.deinit();
    try EmptyCatchRule.rule.check(&source7, allocator, &diagnostics);

    diagnostics.clearRetainingCapacity();

    // Test case 8: Malformed code - missing closing pipe (should not crash)
    const code8: [:0]const u8 =
        \\const x = try_func() catch |err
    ;
    var source8 = Source.init(allocator, "test.zig", code8);
    defer source8.deinit();
    try EmptyCatchRule.rule.check(&source8, allocator, &diagnostics);
}
