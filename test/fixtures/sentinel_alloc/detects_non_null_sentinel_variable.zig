// EXPECT: line=6 rule=sentinel-alloc severity=warning message=allocWithOptions
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const sentinel: u8 = 0;
    const s: []u8 = allocator.allocWithOptions(u8, 10, null, sentinel) catch return;
    _ = s;
}
