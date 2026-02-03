// EXPECT: line=5 rule=sentinel-alloc severity=warning message=allocSentinel allocates len+1 bytes
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const s: []u8 = allocator.allocSentinel(u8, 10, 0) catch return;
    _ = s;
}
