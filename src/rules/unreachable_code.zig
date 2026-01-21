const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const cfg_mod = @import("../cfg.zig");
const CfgBuilder = cfg_mod.CfgBuilder;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;

pub const UnreachableCodeRule = struct {
    pub const rule: Rule = .{
        .name = "unreachable-code",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);

        for (tags, 0..) |tag, i| {
            if (tag == .fn_decl) {
                const fn_node: u32 = @intCast(i);
                try checkFunctionForUnreachable(src, allocator, diagnostics, fn_node);
            }
        }
    }

    fn checkFunctionForUnreachable(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        fn_node: u32,
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        var body_node: ?u32 = null;

        if (tags[fn_node] == .fn_decl) {
            const node_data = data[fn_node];
            _ = node_data.opt_node_and_opt_node[0].unwrap() orelse return;
            body_node = @intFromEnum(node_data.opt_node_and_opt_node[1].unwrap() orelse return);
        }

        if (body_node) |body| {
            try checkBlockForUnreachable(src, allocator, diagnostics, body);
        }
    }

    fn checkBlockForUnreachable(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        block_node: u32,
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const block_tag = tags[block_node];
        var statements: []const u32 = &.{};
        var scratch_buf: [2]u32 = undefined;

        switch (block_tag) {
            .block, .block_semicolon => {
                const extra_range = data[block_node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                statements = tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[block_node].opt_node_and_opt_node;
                var count: usize = 0;
                if (opt_nodes[0].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                statements = scratch_buf[0..count];
            },
            else => return,
        }

        var found_terminator = false;
        for (statements) |stmt| {
            if (found_terminator) {
                const main_tokens = tree.nodes.items(.main_token);
                const token_starts = tree.tokens.items(.start);
                const main_token = main_tokens[stmt];
                const byte_offset = token_starts[main_token];
                const loc = try src.byteToLocation(byte_offset);
                const diag = try Diagnostic.initAtLocation(
                    allocator,
                    src.getFilePath(),
                    rule.name,
                    .warning,
                    "unreachable code detected",
                    loc.line,
                    loc.column,
                );
                try diagnostics.append(allocator, diag);
            }

            const stmt_tag = tags[stmt];
            if (stmt_tag == .@"return") {
                found_terminator = true;
            } else if (stmt_tag == .@"if") {
                if (try isIfFullyTerminating(src, stmt)) {
                    found_terminator = true;
                }
            }

            try checkStatementRecursively(src, allocator, diagnostics, stmt);
        }
    }

    fn isIfFullyTerminating(src: *Source, if_node: u32) RuleError!bool {
        const tree = try src.ast();
        const data = tree.nodes.items(.data);

        const if_data = data[if_node];
        const then_expr = @intFromEnum(if_data.opt_node_and_opt_node[0].unwrap() orelse return false);
        const else_expr_opt = if_data.opt_node_and_opt_node[1].unwrap();

        if (else_expr_opt == null) {
            return false;
        }

        const else_expr = @intFromEnum(else_expr_opt.?);

        const then_terminates = try doesBlockTerminate(src, then_expr);
        const else_terminates = try doesBlockTerminate(src, else_expr);

        return then_terminates and else_terminates;
    }

    fn doesBlockTerminate(src: *Source, node: u32) RuleError!bool {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const node_tag = tags[node];

        if (node_tag == .@"return") {
            return true;
        }

        var statements: []const u32 = &.{};
        var scratch_buf: [2]u32 = undefined;

        switch (node_tag) {
            .block, .block_semicolon => {
                const extra_range = data[node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                statements = tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[node].opt_node_and_opt_node;
                var count: usize = 0;
                if (opt_nodes[0].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                statements = scratch_buf[0..count];
            },
            else => return false,
        }

        if (statements.len == 0) {
            return false;
        }

        const last_stmt = statements[statements.len - 1];
        const last_tag = tags[last_stmt];

        if (last_tag == .@"return") {
            return true;
        }

        if (last_tag == .@"if") {
            return try isIfFullyTerminating(src, last_stmt);
        }

        return false;
    }

    fn checkStatementRecursively(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        stmt_node: u32,
    ) RuleError!void {
        const tree = try src.ast();
        const data = tree.nodes.items(.data);

        const stmt_tag = tree.nodes.items(.tag)[stmt_node];

        switch (stmt_tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                try checkBlockForUnreachable(src, allocator, diagnostics, stmt_node);
            },
            .@"if" => {
                const if_data = data[stmt_node];
                if (if_data.opt_node_and_opt_node[0].unwrap()) |then_node| {
                    try checkStatementRecursively(src, allocator, diagnostics, @intFromEnum(then_node));
                }
                if (if_data.opt_node_and_opt_node[1].unwrap()) |else_node| {
                    try checkStatementRecursively(src, allocator, diagnostics, @intFromEnum(else_node));
                }
            },
            else => {},
        }
    }
};

test "unreachable_code - basic unreachable after return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    return;
        \\    const x = 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (violations.items) |*diag| {
            diag.deinit(allocator);
        }
        violations.deinit(allocator);
    }

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}

test "unreachable_code - reachable code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    const x = 42;
        \\    return;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "unreachable_code - unreachable in if-else both terminate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) void {
        \\    if (x > 0) {
        \\        return;
        \\    } else {
        \\        return;
        \\    }
        \\    const y = 10;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (violations.items) |*diag| {
            diag.deinit(allocator);
        }
        violations.deinit(allocator);
    }

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}
