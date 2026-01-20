const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;

pub const EmptyErrdeferRule = struct {
    pub const rule: Rule = .{
        .name = "empty-errdefer",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        for (tags, 0..) |tag, i| {
            if (tag == .@"errdefer") {
                const errdefer_node: u32 = @intCast(i);
                const errdefer_body = data[errdefer_node].opt_token_and_node[1];

                const errdefer_body_idx = @intFromEnum(errdefer_body);
                if (errdefer_body_idx != 0 and errdefer_body_idx < tags.len) {
                    const body_tag = tags[errdefer_body_idx];

                    var is_empty = false;
                    switch (body_tag) {
                        .block, .block_semicolon => {
                            const extra = data[errdefer_body_idx].extra_range;
                            const start: usize = @intFromEnum(extra.start);
                            const end: usize = @intFromEnum(extra.end);
                            is_empty = (end <= start);
                        },
                        .block_two, .block_two_semicolon => {
                            const opt_nodes = data[errdefer_body_idx].opt_node_and_opt_node;
                            is_empty = (opt_nodes[0].unwrap() == null and opt_nodes[1].unwrap() == null);
                        },
                        else => {},
                    }

                    if (is_empty) {
                        const main_tokens = tree.nodes.items(.main_token);
                        const token_starts = tree.tokens.items(.start);
                        const main_token = main_tokens[errdefer_node];
                        const errdefer_byte_offset = token_starts[main_token];
                        const loc = try src.byteToLocation(errdefer_byte_offset);
                        try diagnostics.append(allocator, Diagnostic.initAtLocation(
                            src.getFilePath(),
                            rule.name,
                            .warning,
                            "empty errdefer block",
                            loc.line,
                            loc.column,
                        ));
                    }
                }
            }
        }
    }
};

test "empty_errdefer - detects empty errdefer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    errdefer {}
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyErrdeferRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}

test "empty_errdefer - allows non-empty errdefer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    var x: i32 = 42;
        \\    errdefer x = 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyErrdeferRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "empty_errdefer - allows errdefer with block containing statements" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    errdefer {
        \\        const x = 42;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try EmptyErrdeferRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}
