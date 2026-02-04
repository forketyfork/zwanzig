// EXPECT: line=9 rule=sentinel-alloc severity=warning message=allocSentinel allocates len+1 bytes
const std = @import("std");

const Holder = struct {
    data: []u8,
};

fn foo(allocator: std.mem.Allocator) void {
    const holder = Holder{ .data = allocator.allocSentinel(u8, 10, 0) catch return };
    _ = holder;
}
