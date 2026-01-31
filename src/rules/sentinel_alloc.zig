const std = @import("std");
const Ast = std.zig.Ast;
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;

/// Detects sentinel-terminated allocations that can cause memory mismatch bugs.
///
/// Sentinel-terminated allocations (e.g., `[:0]u8`) allocate `len + 1` bytes but
/// the slice length is `len`. Zig's allocator correctly handles freeing if the
/// slice type preserves sentinel information. However, if the slice is stored in
/// a non-sentinel type (e.g., `[]u8`), the sentinel info is lost and freeing will
/// cause an allocation size mismatch.
///
/// This rule warns about functions that create sentinel-terminated allocations:
/// - `readToEndAllocOptions` with non-null sentinel parameter
/// - `allocWithOptions` with non-null sentinel parameter
/// - `allocSentinel` (always creates sentinel-terminated allocation)
/// - `dupeZ` (always creates null-terminated copy)
/// - `allocPrintSentinel` (always creates sentinel-terminated string)
///
/// To fix: either use null sentinel if not needed, preserve the sentinel type,
/// or manually free with `ptr[0..len+1]` to include the sentinel byte.
pub const SentinelAllocRule = struct {
    pub const rule: Rule = .{
        .name = "sentinel-alloc",
        .checkFn = check,
    };

    const SentinelCallKind = enum {
        read_to_end_alloc_options, // sentinel is 5th param, optional
        alloc_with_options, // sentinel is 4th param, optional
        alloc_sentinel, // always sentinel
        dupe_z, // always null-terminated
        alloc_print_sentinel, // always sentinel
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        for (0..tags.len) |i| {
            const node_idx: Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            // Look for function calls
            if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) continue;

            // Get the full call information
            var buf: [1]Ast.Node.Index = undefined;
            const full_call = tree.fullCall(&buf, node_idx) orelse continue;

            // Check if this is a method call (field_access on left side)
            const callee_idx = @intFromEnum(full_call.ast.fn_expr);
            if (callee_idx >= tags.len) continue;
            if (tags[callee_idx] != .field_access) continue;

            // Get the method name
            const field_access_data = datas[callee_idx].node_and_token;
            const field_token = field_access_data[1];
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) continue;
            const method_name = tree.tokenSlice(field_token);

            // Identify the kind of sentinel call
            const call_kind: ?SentinelCallKind = if (std.mem.eql(u8, method_name, "readToEndAllocOptions"))
                .read_to_end_alloc_options
            else if (std.mem.eql(u8, method_name, "allocWithOptions"))
                .alloc_with_options
            else if (std.mem.eql(u8, method_name, "allocSentinel"))
                .alloc_sentinel
            else if (std.mem.eql(u8, method_name, "dupeZ"))
                .dupe_z
            else if (std.mem.eql(u8, method_name, "allocPrintSentinel"))
                .alloc_print_sentinel
            else
                null;

            const kind = call_kind orelse continue;

            // Check if this is a sentinel allocation that should warn
            const should_warn = switch (kind) {
                .read_to_end_alloc_options => blk: {
                    // Sentinel is the 5th parameter (index 4)
                    if (full_call.ast.params.len < 5) break :blk false;
                    break :blk !isNullLiteral(tree, tags, token_tags, main_tokens, full_call.ast.params[4]);
                },
                .alloc_with_options => blk: {
                    // Sentinel is the 4th parameter (index 3)
                    if (full_call.ast.params.len < 4) break :blk false;
                    break :blk !isNullLiteral(tree, tags, token_tags, main_tokens, full_call.ast.params[3]);
                },
                // These always create sentinel-terminated allocations
                .alloc_sentinel, .dupe_z, .alloc_print_sentinel => true,
            };

            if (!should_warn) continue;

            // Emit warning
            const token_starts = tree.tokens.items(.start);
            const call_token = main_tokens[callee_idx];
            const byte_offset = token_starts[call_token];
            const loc = try src.byteToLocation(byte_offset);

            const message = switch (kind) {
                .read_to_end_alloc_options => "readToEndAllocOptions with non-null sentinel allocates len+1 bytes; if stored as []u8, freeing will cause size mismatch",
                .alloc_with_options => "allocWithOptions with non-null sentinel allocates len+1 bytes; if stored as []T, freeing will cause size mismatch",
                .alloc_sentinel => "allocSentinel allocates len+1 bytes; if stored as []T, freeing will cause size mismatch",
                .dupe_z => "dupeZ allocates len+1 bytes for null terminator; if stored as []T, freeing will cause size mismatch",
                .alloc_print_sentinel => "allocPrintSentinel allocates len+1 bytes; if stored as []u8, freeing will cause size mismatch",
            };

            const diag = try Diagnostic.initAtLocation(
                allocator,
                src.getFilePath(),
                rule.name,
                .warning,
                message,
                loc.line,
                loc.column,
            );
            try diagnostics.append(allocator, diag);
        }
    }

    fn isNullLiteral(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        param: Ast.Node.Index,
    ) bool {
        const param_idx = @intFromEnum(param);
        if (param_idx >= tags.len) return false;

        if (tags[param_idx] == .identifier) {
            const token = main_tokens[param_idx];
            if (token < token_tags.len and token_tags[token] == .identifier) {
                const value = tree.tokenSlice(token);
                return std.mem.eql(u8, value, "null");
            }
        }
        return false;
    }
};

test "sentinel_alloc detects readToEndAllocOptions with non-null sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
        \\    defer file.close();
        \\    const content = file.readToEndAllocOptions(
        \\        std.heap.page_allocator,
        \\        1024,
        \\        null,
        \\        @alignOf(u8),
        \\        0,
        \\    ) catch return;
        \\    _ = content;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("sentinel-alloc", diagnostics.items[0].rule_id);
}

test "sentinel_alloc ignores null sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
        \\    defer file.close();
        \\    const content = file.readToEndAllocOptions(
        \\        std.heap.page_allocator,
        \\        1024,
        \\        null,
        \\        @alignOf(u8),
        \\        null,
        \\    ) catch return;
        \\    _ = content;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "sentinel_alloc detects dupeZ" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    const s = allocator.dupeZ(u8, "hello") catch return;
        \\    _ = s;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "dupeZ") != null);
}

test "sentinel_alloc detects allocSentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    const s = allocator.allocSentinel(u8, 10, 0) catch return;
        \\    _ = s;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "allocSentinel") != null);
}
