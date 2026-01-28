const std = @import("std");

fn foo(allocator: std.mem.Allocator) !void {
    var ptr = try allocator.alloc(u8, 1);
    allocator.free(ptr);
    allocator.free(ptr);
}

// EXPECT: rule=store-violations-engine severity=error message=double-free
