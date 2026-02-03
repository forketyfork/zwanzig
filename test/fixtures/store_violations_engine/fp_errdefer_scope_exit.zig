const std = @import("std");

fn foo(allocator: std.mem.Allocator) !void {
    {
        const buf = try allocator.alloc(u8, 1);
        errdefer allocator.free(buf);
        allocator.free(buf);
    }

    return error.Oops;
}

// EXPECT: none
