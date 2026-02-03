// EXPECT: line=5 rule=sentinel-alloc severity=warning message=allocWithOptions with non-null sentinel allocates len+1 bytes
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const s: []u8 = allocator.allocWithOptions(u8, 10, null, 0) catch return;
    _ = s;
}
