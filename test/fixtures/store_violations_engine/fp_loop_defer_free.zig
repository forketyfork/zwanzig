const std = @import("std");

fn process(allocator: std.mem.Allocator, inputs: []const []const u8) !void {
    for (inputs) |item| {
        const buf = try allocator.dupe(u8, item);
        defer allocator.free(buf);
        _ = buf.len;
    }
}

// EXPECT: none
