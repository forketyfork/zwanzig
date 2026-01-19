const std = @import("std");

/// Represents a single violation found by a rule
pub const Violation = struct {
    file_path: []const u8,
    line: usize,
    column: usize,
    rule_name: []const u8,
    message: []const u8,

    pub fn format(self: Violation, writer: *std.Io.Writer) !void {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            self.file_path,
            self.line,
            self.column,
            self.rule_name,
            self.message,
        });
    }
};

pub const RuleError = error{OutOfMemory};

/// Base interface that all rules must implement
pub const Rule = struct {
    name: []const u8,
    checkFn: *const fn (
        source: []const u8,
        file_path: []const u8,
        allocator: std.mem.Allocator,
        violations: *std.ArrayList(Violation),
    ) RuleError!void,

    pub fn check(
        self: *const Rule,
        source: []const u8,
        file_path: []const u8,
        allocator: std.mem.Allocator,
        violations: *std.ArrayList(Violation),
    ) RuleError!void {
        try self.checkFn(source, file_path, allocator, violations);
    }
};
