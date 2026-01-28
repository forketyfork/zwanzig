const std = @import("std");

const Payload = struct {
    data: []u8,
};

fn make(allocator: std.mem.Allocator, input: []const u8) !Payload {
    const data = try allocator.dupe(u8, input);
    return .{ .data = data };
}

// EXPECT: none
