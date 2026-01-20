const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that enforces file naming conventions based on whether the file
/// contains top-level fields (i.e., acts as a struct).
///
/// In Zig, a file can act as an implicit struct by having top-level fields.
/// This rule enforces the convention that:
/// - Files with top-level fields should have a capitalized file name (e.g., `MyType.zig`)
/// - Files without top-level fields should have a lowercase file name (e.g., `utils.zig`)
pub const FileAsStructRule = struct {
    pub const rule: Rule = Rule{
        .name = "file-as-struct",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const file_path = src.getFilePath();

        const has_fields = hasTopLevelFields(tree);
        const filename = getFilename(file_path);

        if (filename.len == 0) return;

        const first_char = filename[0];
        const is_capitalized = std.ascii.isUpper(first_char);

        if (has_fields and !is_capitalized) {
            const message = allocator.dupe(
                u8,
                "File contains top-level fields but has a lowercase name. " ++
                    "Consider using a capitalized name (e.g., 'MyType.zig') for struct-like files.",
            ) catch return RuleError.OutOfMemory;

            try diagnostics.append(allocator, Diagnostic.initAtLocation(
                file_path,
                "file-as-struct",
                .warning,
                message,
                1,
                1,
            ));
        } else if (!has_fields and is_capitalized) {
            const message = allocator.dupe(
                u8,
                "File has a capitalized name but contains no top-level fields. " ++
                    "Consider using a lowercase name (e.g., 'utils.zig') for module files.",
            ) catch return RuleError.OutOfMemory;

            try diagnostics.append(allocator, Diagnostic.initAtLocation(
                file_path,
                "file-as-struct",
                .warning,
                message,
                1,
                1,
            ));
        }
    }

    fn hasTopLevelFields(tree: *const std.zig.Ast) bool {
        const tags = tree.nodes.items(.tag);
        const root_decls = tree.rootDecls();

        for (root_decls) |decl_idx| {
            const tag = tags[@intFromEnum(decl_idx)];
            if (isContainerField(tag)) {
                return true;
            }
        }

        return false;
    }

    fn isContainerField(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
            .container_field_init,
            .container_field,
            => true,
            else => false,
        };
    }

    fn getFilename(file_path: []const u8) []const u8 {
        const basename = std.fs.path.basename(file_path);
        if (std.mem.endsWith(u8, basename, ".zig")) {
            return basename[0 .. basename.len - 4];
        }
        return basename;
    }
};

fn freeDiagnosticMessages(diagnostics: *std.ArrayList(Diagnostic), allocator: std.mem.Allocator) void {
    for (diagnostics.items) |diag| {
        allocator.free(@constCast(diag.message));
    }
    diagnostics.clearRetainingCapacity();
}

test "file with top-level fields and lowercase name - violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    // File with top-level fields (implicit struct)
    const code: [:0]const u8 =
        \\count: usize,
        \\name: []const u8,
        \\
        \\pub fn init() @This() {
        \\    return .{ .count = 0, .name = "" };
        \\}
    ;
    var source = Source.init(allocator, "mytype.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("file-as-struct", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "lowercase") != null);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "file with top-level fields and capitalized name - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\count: usize,
        \\name: []const u8,
        \\
        \\pub fn init() @This() {
        \\    return .{ .count = 0, .name = "" };
        \\}
    ;
    var source = Source.init(allocator, "MyType.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "file without top-level fields and capitalized name - violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    // Module file without fields
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn helper() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
    ;
    var source = Source.init(allocator, "Utils.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("file-as-struct", diagnostics.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "capitalized") != null);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "file without top-level fields and lowercase name - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn helper() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
    ;
    var source = Source.init(allocator, "utils.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "file with const/var declarations but no fields - lowercase name - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\pub const VERSION = "1.0.0";
        \\var counter: usize = 0;
    ;
    var source = Source.init(allocator, "config.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "file with nested struct fields - only top-level counts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    // This file has fields inside a nested struct, but no top-level fields
    const code: [:0]const u8 =
        \\const Inner = struct {
        \\    value: i32,
        \\};
        \\
        \\pub fn create() Inner {
        \\    return .{ .value = 42 };
        \\}
    ;
    var source = Source.init(allocator, "factory.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "empty file - no violation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 = "";
    var source = Source.init(allocator, "empty.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "getFilename extracts filename without .zig extension" {
    const result1 = FileAsStructRule.getFilename("src/MyType.zig");
    try std.testing.expectEqualStrings("MyType", result1);

    const result2 = FileAsStructRule.getFilename("utils.zig");
    try std.testing.expectEqualStrings("utils", result2);

    const result3 = FileAsStructRule.getFilename("/absolute/path/to/File.zig");
    try std.testing.expectEqualStrings("File", result3);
}

test "file with only a single top-level field" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\value: i32,
    ;
    var source = Source.init(allocator, "wrapper.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "file with initialized top-level field" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\value: i32 = 42,
    ;
    var source = Source.init(allocator, "point.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);

    freeDiagnosticMessages(&diagnostics, allocator);
}

test "mixed top-level fields and declarations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\x: i32,
        \\y: i32,
        \\pub fn origin() @This() {
        \\    return .{ .x = 0, .y = 0 };
        \\}
    ;
    var source = Source.init(allocator, "Point.zig", code);
    defer source.deinit();
    try FileAsStructRule.rule.check(&source, allocator, &diagnostics);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
