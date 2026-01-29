const std = @import("std");

const Config = struct {
    rules: []const u8,
};

fn build(allocator: std.mem.Allocator) !Config {
    const rules = try allocator.dupe(u8, "x");
    return .{ .rules = rules };
}

// EXPECT: none
