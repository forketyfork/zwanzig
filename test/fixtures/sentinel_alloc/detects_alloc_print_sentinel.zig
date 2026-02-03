// EXPECT: line=5 rule=sentinel-alloc severity=warning message=allocPrintSentinel allocates len+1 bytes
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const s: []u8 = allocator.allocPrintSentinel(0, "{d}", .{42}) catch return;
    _ = s;
}
