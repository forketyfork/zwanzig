const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Violation = @import("../rule.zig").Violation;

/// Rule that detects empty catch blocks in Zig code
/// Empty catch blocks silently ignore errors which is usually a bad practice
pub const EmptyCatchRule = struct {
    pub const rule: Rule = Rule{
        .name = "empty-catch",
        .checkFn = check,
    };

    fn check(source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) !void {
        var line: usize = 1;
        var column: usize = 1;
        var i: usize = 0;

        while (i < source.len) : (i += 1) {
            // Track line and column
            if (source[i] == '\n') {
                line += 1;
                column = 1;
                continue;
            }
            column += 1;

            // Look for "catch" keyword
            if (i + 5 <= source.len and std.mem.eql(u8, source[i..][0..5], "catch")) {
                // Make sure it's a whole word (not part of another identifier)
                const is_word_start = i == 0 or !isIdentifierChar(source[i - 1]);
                const is_word_end = i + 5 >= source.len or !isIdentifierChar(source[i + 5]);

                if (is_word_start and is_word_end) {
                    // Found "catch" keyword, now look for the block
                    const catch_line = line;
                    const catch_column = column;
                    var j = i + 5;

                    // Skip whitespace and potential |err| capture
                    while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\n')) : (j += 1) {}

                    // Check for optional error capture |err|
                    if (j < source.len and source[j] == '|') {
                        j += 1;
                        // Skip until we find the closing |
                        while (j < source.len and source[j] != '|') : (j += 1) {}
                        if (j < source.len) j += 1; // Skip the closing |

                        // Skip more whitespace
                        while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\n')) : (j += 1) {}
                    }

                    // Now we should be at the opening brace
                    if (j < source.len and source[j] == '{') {
                        j += 1;

                        // Check if the block is empty (only whitespace between { and })
                        var is_empty = true;
                        while (j < source.len) : (j += 1) {
                            if (source[j] == '}') {
                                // Found closing brace
                                if (is_empty) {
                                    // Report violation
                                    try violations.append(Violation{
                                        .file_path = file_path,
                                        .line = catch_line,
                                        .column = catch_column,
                                        .rule_name = "empty-catch",
                                        .message = "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.",
                                    });
                                }
                                break;
                            } else if (source[j] != ' ' and source[j] != '\t' and source[j] != '\n' and source[j] != '\r') {
                                // Found non-whitespace content
                                is_empty = false;
                            }
                        }

                        // Move main loop past the catch block we just analyzed
                        i = j;
                    }
                }
            }
        }
    }

    fn isIdentifierChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }
};

test "empty catch block detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var violations = std.ArrayList(Violation).init(allocator);
    defer violations.deinit();

    // Test case 1: Empty catch block
    const code1 =
        \\const x = try_func() catch {};
    ;
    try EmptyCatchRule.rule.check(code1, "test.zig", &violations);
    try testing.expectEqual(@as(usize, 1), violations.items.len);

    violations.clearRetainingCapacity();

    // Test case 2: Non-empty catch block
    const code2 =
        \\const x = try_func() catch {
        \\    std.debug.print("Error occurred\n", .{});
        \\};
    ;
    try EmptyCatchRule.rule.check(code2, "test.zig", &violations);
    try testing.expectEqual(@as(usize, 0), violations.items.len);

    violations.clearRetainingCapacity();

    // Test case 3: Catch with error capture but empty body
    const code3 =
        \\const x = try_func() catch |err| {};
    ;
    try EmptyCatchRule.rule.check(code3, "test.zig", &violations);
    try testing.expectEqual(@as(usize, 1), violations.items.len);

    violations.clearRetainingCapacity();

    // Test case 4: Multiple catches
    const code4 =
        \\const x = try_func() catch {};
        \\const y = another_func() catch {
        \\    return error.Failed;
        \\};
        \\const z = third_func() catch {};
    ;
    try EmptyCatchRule.rule.check(code4, "test.zig", &violations);
    try testing.expectEqual(@as(usize, 2), violations.items.len);
}
