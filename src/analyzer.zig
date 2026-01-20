const std = @import("std");
const Rule = @import("rule.zig").Rule;
const Diagnostic = @import("rule.zig").Diagnostic;
const Source = @import("source.zig").Source;
const RuleFilter = @import("rule_filter.zig").RuleFilter;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(*const Rule),
    diagnostics: std.ArrayList(Diagnostic),
    rule_filter: RuleFilter,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .rules = .empty,
            .diagnostics = .empty,
            .rule_filter = .none,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.rules.deinit(self.allocator);
        for (self.diagnostics.items) |diag| {
            self.allocator.free(@constCast(diag.message));
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn registerRule(self: *Analyzer, rule: *const Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn setRuleFilter(self: *Analyzer, filter: RuleFilter) void {
        self.rule_filter = filter;
    }

    pub fn isRuleEnabled(self: *const Analyzer, rule_name: []const u8) bool {
        switch (self.rule_filter) {
            .none => return true,
            .allowlist => |list| {
                for (list) |allowed| {
                    if (std.mem.eql(u8, rule_name, allowed)) {
                        return true;
                    }
                }
                return false;
            },
            .blocklist => |list| {
                for (list) |blocked| {
                    if (std.mem.eql(u8, rule_name, blocked)) {
                        return false;
                    }
                }
                return true;
            },
        }
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
            if (self.isRuleEnabled(rule.name)) {
                try rule.check(&source, self.allocator, &self.diagnostics);
            }
        }
    }

    pub fn printResults(self: *Analyzer) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();

        if (self.diagnostics.items.len == 0) {
            try stdout.writeAll("No issues found.\n");
            return;
        }

        try stdout.print("Found {d} issue(s):\n", .{self.diagnostics.items.len});
        for (self.diagnostics.items) |diag| {
            try diag.format(stdout);
        }
    }

    pub fn hasDiagnostics(self: *Analyzer) bool {
        return self.diagnostics.items.len > 0;
    }
};
