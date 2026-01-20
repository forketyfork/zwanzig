const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that detects unused container-level const/var declarations and functions.
///
/// This rule scans top-level declarations (const, var, fn) that are not exported
/// (not marked as `pub`) and checks if they are used elsewhere in the file.
/// Declarations that are never referenced are reported as warnings.
///
/// The rule uses a conservative approach and may have false negatives in complex
/// cases involving comptime or indirect references.
pub const UnusedDeclRule = struct {
    pub const rule: Rule = Rule{
        .name = "unused-decl",
        .default_severity = .warning,
        .checkFn = check,
    };

    const DeclInfo = struct {
        name: []const u8,
        token_index: u32,
        is_pub: bool,
        byte_offset: usize,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const root_decls = tree.rootDecls();

        var decls: std.ArrayList(DeclInfo) = .empty;
        defer decls.deinit(allocator);

        for (root_decls) |decl_idx| {
            const idx = @intFromEnum(decl_idx);
            const tag = tags[idx];

            const decl_info = switch (tag) {
                .simple_var_decl => extractVarDecl(tree, @intCast(idx), token_tags, token_starts),
                .fn_decl => extractFnDecl(tree, @intCast(idx), token_tags, token_starts),
                else => null,
            };

            if (decl_info) |info| {
                if (!info.is_pub and !isSpecialName(info.name)) {
                    try decls.append(allocator, info);
                }
            }
        }

        const source_content = src.getContent();

        for (decls.items) |decl| {
            if (!isNameUsed(source_content, decl.name, token_tags, token_starts)) {
                const range = try src.byteRangeToSourceRange(decl.byte_offset, decl.byte_offset + decl.name.len);

                const message = std.fmt.allocPrint(
                    allocator,
                    "Declaration '{s}' is never used",
                    .{decl.name},
                ) catch return RuleError.OutOfMemory;

                try diagnostics.append(allocator, Diagnostic.init(
                    src.getFilePath(),
                    "unused-decl",
                    .warning,
                    message,
                    range,
                ));
            }
        }
    }

    fn extractVarDecl(
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) ?DeclInfo {
        const main_token = tree.nodes.items(.main_token)[node_idx];

        var is_pub = false;
        if (main_token > 0) {
            const prev_token = main_token - 1;
            if (token_tags[prev_token] == .keyword_pub) {
                is_pub = true;
            }
        }

        const name_token = main_token + 1;
        if (name_token >= token_tags.len) return null;

        if (token_tags[name_token] != .identifier) return null;

        const name_start = token_starts[name_token];
        const source = tree.source;
        const name = extractIdentifier(source, name_start);

        return DeclInfo{
            .name = name,
            .token_index = name_token,
            .is_pub = is_pub,
            .byte_offset = name_start,
        };
    }

    fn extractFnDecl(
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) ?DeclInfo {
        const main_token = tree.nodes.items(.main_token)[node_idx];

        var is_pub = false;
        if (main_token > 0) {
            const prev_token = main_token - 1;
            if (token_tags[prev_token] == .keyword_pub) {
                is_pub = true;
            }
        }

        const name_token = main_token + 1;
        if (name_token >= token_tags.len) return null;

        if (token_tags[name_token] != .identifier) return null;

        const name_start = token_starts[name_token];
        const source = tree.source;
        const name = extractIdentifier(source, name_start);

        return DeclInfo{
            .name = name,
            .token_index = name_token,
            .is_pub = is_pub,
            .byte_offset = name_start,
        };
    }

    fn extractIdentifier(source: []const u8, start: usize) []const u8 {
        var end = start;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) {
            end += 1;
        }
        return source[start..end];
    }

    fn isSpecialName(name: []const u8) bool {
        if (name.len > 0 and name[0] == '_') return true;
        if (std.mem.eql(u8, name, "main")) return true;
        if (std.mem.eql(u8, name, "panic")) return true;
        return false;
    }

    fn isNameUsed(
        source: []const u8,
        name: []const u8,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) bool {
        var count: usize = 0;

        for (token_tags, 0..) |tag, i| {
            if (tag == .identifier) {
                const start = token_starts[i];
                const end = blk: {
                    var e = start;
                    while (e < source.len and (std.ascii.isAlphanumeric(source[e]) or source[e] == '_')) {
                        e += 1;
                    }
                    break :blk e;
                };
                const token_name = source[start..end];
                if (std.mem.eql(u8, token_name, name)) {
                    count += 1;
                    if (count > 1) return true;
                }
            }
        }

        return false;
    }
};

fn freeDiagnosticMessages(diagnostics: *std.ArrayList(Diagnostic), allocator: std.mem.Allocator) void {
    for (diagnostics.items) |diag| {
        allocator.free(@constCast(diag.message));
    }
    diagnostics.clearRetainingCapacity();
}

test "unused const declaration - violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const unused_value = 42;
        \\
        \\pub fn main() void {
        \\    _ = "hello";
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unused-decl", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "unused_value") != null);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "used const declaration - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const value = 42;
        \\
        \\pub fn main() void {
        \\    _ = value;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "pub const declaration - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\pub const VERSION = "1.0.0";
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unused function declaration - violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\fn unused_helper() void {}
        \\
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "unused_helper") != null);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "used function declaration - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\fn helper() void {}
        \\
        \\pub fn main() void {
        \\    helper();
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "pub function declaration - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\pub fn helper() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "underscore-prefixed declaration - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const _unused = 42;
        \\fn _helper() void {}
        \\
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "main function - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "panic function - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\fn panic(msg: []const u8, trace: ?*@import("std").builtin.StackTrace) noreturn {
        \\    @panic(msg);
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "multiple unused declarations - multiple violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const unused1 = 1;
        \\const unused2 = 2;
        \\fn unused_fn() void {}
        \\
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 3), diagnostics.items.len);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "empty file - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 = "";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "const used in nested scope - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const config = 100;
        \\
        \\pub fn process() void {
        \\    if (true) {
        \\        _ = config;
        \\    }
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unused var declaration - violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\var counter: usize = 0;
        \\
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();
    try UnusedDeclRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "counter") != null);

    freeDiagnosticMessages(&diagnostics, allocator);
}
