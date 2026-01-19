const std = @import("std");

/// Represents a single violation found by a rule
pub const Violation = struct {
    file_path: []const u8,
    line: usize,
    column: usize,
    rule_name: []const u8,
    message: []const u8,

    pub fn format(self: Violation, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            self.file_path,
            self.line,
            self.column,
            self.rule_name,
            self.message,
        });
    }
};

/// Base interface that all rules must implement
pub const Rule = struct {
    name: []const u8,
    checkFn: *const fn (source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) anyerror!void,

    pub fn check(self: *const Rule, source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) !void {
        try self.checkFn(source, file_path, violations);
    }
};
