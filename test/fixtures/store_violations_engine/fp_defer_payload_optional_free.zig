const std = @import("std");

fn example(allocator: std.mem.Allocator, input: []const u8) void {
    const maybe = allocator.dupe(u8, input) catch null;
    defer if (maybe) |buf| allocator.free(buf);
    if (maybe) |buf| {
        _ = buf.len;
    }
}

// EXPECT: none
