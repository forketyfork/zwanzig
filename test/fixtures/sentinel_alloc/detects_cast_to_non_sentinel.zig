// EXPECT: line=5 rule=sentinel-alloc severity=warning message=dupeZ allocates len+1 bytes for null terminator
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const s = @as([]u8, allocator.dupeZ(u8, "hello") catch return);
    _ = s;
}
