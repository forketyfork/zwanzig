const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const SourceRange = checker_mod.SourceRange;
const Source = @import("../source.zig").Source;
const value = @import("../engine/value.zig");

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
        const cond_value = evaluateConditionValue(tree, cond_node);

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
        const cond_value = evaluateConditionValue(tree, cond_node);

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

    fn evaluateConditionValue(tree: *const std.zig.Ast, cond_node: u32) ?bool {
        // First, try to evaluate as a literal true/false
        if (value.evaluateBoolLiteral(tree, cond_node)) |literal| {
            return literal;
        }

        // If it's an identifier, try to resolve it to a const declaration
        const tags = tree.nodes.items(.tag);
        if (cond_node >= tags.len) return null;
        if (tags[cond_node] != .identifier) return null;

        // Get the identifier name
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);
        const token = main_tokens[cond_node];
        const start = token_starts[token];

        var len: u32 = 0;
        while (start + len < tree.source.len) {
            const c = tree.source[start + len];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            len += 1;
        }
        const ident_name = tree.source[start .. start + len];

        // Search for a const declaration with this name in preceding nodes
        for (0..cond_node) |i| {
            const node_tag = tags[i];
            // Look for simple_var_decl (const x = ...) or local_var_decl
            if (node_tag != .simple_var_decl and node_tag != .local_var_decl) continue;

            const var_decl = tree.fullVarDecl(@enumFromInt(@as(u32, @intCast(i)))) orelse continue;

            // Must be a const (not var)
            const decl_token = tree.tokens.items(.tag)[var_decl.ast.mut_token];
            if (decl_token != .keyword_const) continue;

            // Get the declaration name
            const decl_name_token = var_decl.ast.mut_token + 1;
            if (decl_name_token >= tree.tokens.items(.start).len) continue;
            const decl_start = tree.tokens.items(.start)[decl_name_token];

            var decl_len: u32 = 0;
            while (decl_start + decl_len < tree.source.len) {
                const c = tree.source[decl_start + decl_len];
                if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                decl_len += 1;
            }
            const decl_name = tree.source[decl_start .. decl_start + decl_len];

            // Check if names match
            if (!std.mem.eql(u8, ident_name, decl_name)) continue;

            // Found the declaration, now evaluate its initializer
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            return value.evaluateBoolLiteral(tree, @intFromEnum(init_node));
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

test "unreachable_code_engine - detects const flag false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const debug = false;
        \\    if (debug) {
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

test "unreachable_code_engine - detects const flag true else branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const enabled = true;
        \\    if (enabled) {
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

test "unreachable_code_engine - no warning for var flag (may be reassigned)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(cond: bool) i32 {
        \\    var flag = true;
        \\    if (cond) flag = false;
        \\    if (flag) return 1;
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
