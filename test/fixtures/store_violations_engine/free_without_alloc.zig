const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    var buf = [_]u8{0};
    var ptr = buf[0..];
    allocator.free(ptr);
}

// EXPECT: line=6 rule=store-violations-engine severity=error message=free without tracked allocation
