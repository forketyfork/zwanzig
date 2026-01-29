const std = @import("std");

fn build(allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    const item = try allocator.alloc(u8, 1);
    try list.append(allocator, item);
    return list;
}

// EXPECT: none
