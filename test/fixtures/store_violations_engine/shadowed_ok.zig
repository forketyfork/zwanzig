const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    var ptr = allocator.alloc(u8, 1) catch unreachable;
    {
        var ptr = allocator.alloc(u8, 1) catch unreachable;
        allocator.free(ptr);
    }
    allocator.free(ptr);
}

// EXPECT: none
