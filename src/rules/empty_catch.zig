const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const SourceRange = @import("../rule.zig").SourceRange;
const Source = @import("../source.zig").Source;

/// Rule that detects empty catch blocks in Zig code using AST traversal.
/// Empty catch blocks silently ignore errors which is usually a bad practice.
///
/// This rule uses the Zig AST to find catch expressions and checks if the
/// catch body is an empty block (no statements). It reports a warning for
/// each empty catch block found.
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
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        for (tags, 0..) |tag, node_idx| {
            if (tag == .@"catch") {
                const node_index: u32 = @intCast(node_idx);
                if (hasEmptyCatchBody(tree, node_index)) {
                    const main_token = main_tokens[node_idx];
                    const catch_start = token_starts[main_token];
                    const range = try src.byteRangeToSourceRange(catch_start, catch_start + 5);

                    try diagnostics.append(allocator, Diagnostic.init(
                        src.getFilePath(),
                        "empty-catch",
                        .warning,
                        "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.",
                        range,
                    ));
                }
            }
        }
    }

    fn hasEmptyCatchBody(tree: *const std.zig.Ast, catch_node_idx: u32) bool {
        // For catch nodes, we need to find the RHS which is the catch body.
        // The catch node's main_token points to "catch", and we scan forward
        // to find the block. An empty block has only { and } tokens.
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        // Get the catch token index
        const catch_token = main_tokens[catch_node_idx];

        // Scan forward from catch token to find the block
        var token_idx = catch_token + 1;
        const num_tokens = token_tags.len;

        // Skip whitespace, comments, and potential |err| capture
        while (token_idx < num_tokens) {
            const tok_tag = token_tags[token_idx];

            if (tok_tag == .l_brace) {
                // Found the opening brace of the catch block
                // Check if the next token is the closing brace
                const next_token_idx = token_idx + 1;
                if (next_token_idx < num_tokens and token_tags[next_token_idx] == .r_brace) {
                    // Empty block - { immediately followed by }
                    return true;
                }
                // Any other token means the block has content
                return false;
            }

            // Skip pipe for |err| capture
            if (tok_tag == .pipe) {
                token_idx += 1;
                // Skip identifier if present
                if (token_idx < num_tokens and token_tags[token_idx] == .identifier) {
                    token_idx += 1;
                }
                // Skip closing pipe
                if (token_idx < num_tokens and token_tags[token_idx] == .pipe) {
                    token_idx += 1;
                }
                continue;
            }

            // Skip identifiers (capture variable)
            if (tok_tag == .identifier) {
                token_idx += 1;
                continue;
            }

            // Any other significant token before finding brace
            token_idx += 1;
        }

        return false;
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
