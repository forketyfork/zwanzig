const std = @import("std");

const Item = struct {
    data: []u8,
};

fn addItem(allocator: std.mem.Allocator, list: *std.ArrayList(Item), src: []const u8) !void {
    const data = try allocator.dupe(u8, src);
    try list.append(allocator, .{ .data = data });
    // Ownership of `data` transferred to list - not a leak
}

// EXPECT: none
