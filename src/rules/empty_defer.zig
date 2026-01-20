const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;

pub const EmptyDeferRule = struct {
    pub const rule: Rule = .{
        .name = "empty-defer",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        for (tags, 0..) |tag, i| {
            if (tag == .@"defer") {
                const defer_node: u32 = @intCast(i);
                const defer_body_opt = data[defer_node].opt_node;

                if (defer_body_opt.unwrap()) |defer_body_node| {
                    const defer_body_idx = @intFromEnum(defer_body_node);
                    if (defer_body_idx < tags.len) {
                        const body_tag = tags[defer_body_idx];

                        var is_empty = false;
                        switch (body_tag) {
                            .block, .block_semicolon => {
                                const extra = data[defer_body_idx].extra_range;
                                const start: usize = @intFromEnum(extra.start);
                                const end: usize = @intFromEnum(extra.end);
                                is_empty = (end <= start);
                            },
                            .block_two, .block_two_semicolon => {
                                const opt_nodes = data[defer_body_idx].opt_node_and_opt_node;
                                is_empty = (opt_nodes[0].unwrap() == null and opt_nodes[1].unwrap() == null);
                            },
                            else => {},
                        }

                        if (is_empty) {
                            const main_tokens = tree.nodes.items(.main_token);
                            const token_starts = tree.tokens.items(.start);
                            const main_token = main_tokens[defer_node];
                            const defer_byte_offset = token_starts[main_token];
                            const loc = try src.byteToLocation(defer_byte_offset);
                            try diagnostics.append(allocator, Diagnostic.initAtLocation(
                                src.getFilePath(),
                                rule.name,
                                .warning,
                                "empty defer block",
                                loc.line,
                                loc.column,
                            ));
                        }
                    }
                }
            }
        }
    }
};

test "empty_defer - detects empty defer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer {}
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyDeferRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}

test "empty_defer - allows non-empty defer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    var x: i32 = 42;
        \\    defer x = 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyDeferRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "empty_defer - allows defer with block containing statements" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer {
        \\        const x = 42;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyDeferRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}
