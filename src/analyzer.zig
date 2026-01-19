const std = @import("std");
const Rule = @import("rule.zig").Rule;
const Violation = @import("rule.zig").Violation;
const Source = @import("source.zig").Source;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(*const Rule),
    violations: std.ArrayList(Violation),

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .rules = .empty,
            .violations = .empty,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.rules.deinit(self.allocator);
        self.violations.deinit(self.allocator);
    }

    pub fn registerRule(self: *Analyzer, rule: *const Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn analyzeFile(self: *Analyzer, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const max_size = 10 * 1024 * 1024;
        const content = try file.readToEndAllocOptions(
            self.allocator,
            max_size,
            null,
            std.mem.Alignment.of(u8),
            0,
        );
        defer self.allocator.free(content);

        var source = Source.init(self.allocator, file_path, content);
        defer source.deinit();

        for (self.rules.items) |rule| {
            try rule.check(&source, self.allocator, &self.violations);
        }
    }

    pub fn printResults(self: *Analyzer) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();

        if (self.violations.items.len == 0) {
            try stdout.writeAll("No violations found.\n");
            return;
        }

        try stdout.print("Found {d} violation(s):\n", .{self.violations.items.len});
        for (self.violations.items) |violation| {
            try stdout.print("{f}", .{violation});
        }
    }

    pub fn hasViolations(self: *Analyzer) bool {
        return self.violations.items.len > 0;
    }
};
