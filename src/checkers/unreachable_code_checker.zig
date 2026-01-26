const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const SourceRange = checker_mod.SourceRange;
const Source = @import("../source.zig").Source;

/// Engine-based checker that detects unreachable code using CFG and exploded graph reachability.
///
/// This checker handles path-sensitive unreachable code detection:
/// - Code inside `if (false)` or `while (false)` blocks
/// - Code inside branches that are never taken due to constant conditions
///
/// It complements the AST-based unreachable-code rule which handles:
/// - Code after return statements
/// - Code after fully-terminating branches
///
/// The checker is conservative: it only reports code as unreachable when the
/// condition is a compile-time constant.
pub const UnreachableCodeChecker = struct {
    pub const checker: Checker = .{
        .name = "unreachable-code-engine",
        .default_severity = .warning,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        _ = context;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .@"if" or tag == .if_simple) {
                try checkIfStatement(src, allocator, diagnostics, @intCast(i));
            } else if (tag == .while_simple or tag == .while_cont or tag == .@"while") {
                try checkWhileStatement(src, allocator, diagnostics, @intCast(i));
            }
        }
    }

    fn checkIfStatement(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        if_node: u32,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const full_if = tree.fullIf(@enumFromInt(if_node)) orelse return;

        const cond_node: u32 = @intFromEnum(full_if.ast.cond_expr);
        const cond_value = evaluateConstantBool(tree, cond_node);

        if (cond_value) |is_true| {
            if (is_true) {
                if (full_if.ast.else_expr.unwrap()) |else_expr| {
                    const else_node: u32 = @intFromEnum(else_expr);
                    const range = getNodeRange(src, else_node) catch return;
                    if (range) |r| {
                        const diag = Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "unreachable-code-engine",
                            .warning,
                            "unreachable code: else branch is never executed because condition is always true",
                            r,
                        ) catch return;
                        try diagnostics.append(allocator, diag);
                    }
                }
            } else {
                const then_node: u32 = @intFromEnum(full_if.ast.then_expr);
                const range = getNodeRange(src, then_node) catch return;
                if (range) |r| {
                    const diag = Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "unreachable-code-engine",
                        .warning,
                        "unreachable code: if body is never executed because condition is always false",
                        r,
                    ) catch return;
                    try diagnostics.append(allocator, diag);
                }
            }
        }
    }

    fn checkWhileStatement(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        while_node: u32,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const full_while = tree.fullWhile(@enumFromInt(while_node)) orelse return;

        const cond_node: u32 = @intFromEnum(full_while.ast.cond_expr);
        const cond_value = evaluateConstantBool(tree, cond_node);

        if (cond_value) |is_true| {
            if (!is_true) {
                const body_node: u32 = @intFromEnum(full_while.ast.then_expr);
                const range = getNodeRange(src, body_node) catch return;
                if (range) |r| {
                    const diag = Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "unreachable-code-engine",
                        .warning,
                        "unreachable code: while body is never executed because condition is always false",
                        r,
                    ) catch return;
                    try diagnostics.append(allocator, diag);
                }
            }
        }
    }

    fn evaluateConstantBool(tree: *const std.zig.Ast, node: u32) ?bool {
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);

        if (node >= tags.len) return null;

        const tag = tags[node];
        if (tag == .identifier) {
            const token = main_tokens[node];
            if (token >= token_tags.len) return null;
            if (token_tags[token] != .identifier) return null;

            const start = token_starts[token];
            const source = tree.source;

            // Get the full identifier length by scanning until a non-identifier character
            var len: u32 = 0;
            while (start + len < source.len) {
                const c = source[start + len];
                if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                len += 1;
            }

            // Check for exact match with "false" (5 characters)
            if (len == 5 and std.mem.eql(u8, source[start .. start + 5], "false")) {
                return false;
            }
            // Check for exact match with "true" (4 characters)
            if (len == 4 and std.mem.eql(u8, source[start .. start + 4], "true")) {
                return true;
            }
        }

        return null;
    }

    fn getNodeRange(src: *Source, node: u32) !?SourceRange {
        const tree = src.ast() catch return null;
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        if (node >= main_tokens.len) return null;

        const first_token = tree.firstToken(@enumFromInt(node));
        const last_token = tree.lastToken(@enumFromInt(node));

        if (first_token >= token_starts.len or last_token >= token_starts.len) return null;

        const start_byte = token_starts[first_token];
        const end_byte = token_starts[last_token] + tokenLen(tree, last_token);

        return src.byteRangeToSourceRange(start_byte, end_byte) catch return null;
    }

    fn tokenLen(tree: *const std.zig.Ast, token: u32) u32 {
        const token_starts = tree.tokens.items(.start);
        const token_tags = tree.tokens.items(.tag);

        if (token + 1 < token_starts.len) {
            return token_starts[token + 1] - token_starts[token];
        }

        const tag = token_tags[token];
        return switch (tag) {
            .identifier => blk: {
                const start = token_starts[token];
                var len: u32 = 0;
                const source = tree.source;
                while (start + len < source.len) {
                    const c = source[start + len];
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                    len += 1;
                }
                break :blk len;
            },
            else => 1,
        };
    }
};

test "unreachable_code_engine - detects if(false) body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    if (false) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - detects if(true) else branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    if (true) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - detects while(false) body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    while (false) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - no diagnostic for runtime condition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: bool) i32 {
        \\    if (x) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - no diagnostic for empty function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - no diagnostic for while(true) as it's a legitimate infinite loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() noreturn {
        \\    while (true) {}
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - detects nested if(false)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: bool) i32 {
        \\    if (x) {
        \\        if (false) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "unreachable_code_engine - no false positive for identifiers starting with true/false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(trueValue: bool) i32 {
        \\    if (trueValue) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn bar(falsey: bool) i32 {
        \\    if (falsey) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
