const std = @import("std");
const Rule = @import("rule.zig").Rule;
const Violation = @import("rule.zig").Violation;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(*const Rule),
    violations: std.ArrayList(Violation),

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .rules = std.ArrayList(*const Rule).init(allocator),
            .violations = std.ArrayList(Violation).init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.rules.deinit();
        self.violations.deinit();
    }

    pub fn registerRule(self: *Analyzer, rule: *const Rule) !void {
        try self.rules.append(rule);
    }

    pub fn analyzeFile(self: *Analyzer, file_path: []const u8) !void {
        // Read the file
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const max_size = 10 * 1024 * 1024; // 10MB max file size
        const source = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(source);

        // Run all registered rules
        for (self.rules.items) |rule| {
            try rule.check(source, file_path, &self.violations);
        }
    }

    pub fn printResults(self: *Analyzer) !void {
        const stdout = std.io.getStdOut().writer();

        if (self.violations.items.len == 0) {
            try stdout.writeAll("No violations found.\n");
            return;
        }

        try stdout.print("Found {d} violation(s):\n", .{self.violations.items.len});
        for (self.violations.items) |violation| {
            try stdout.print("{}\n", .{violation});
        }
    }

    pub fn hasViolations(self: *Analyzer) bool {
        return self.violations.items.len > 0;
    }
};
