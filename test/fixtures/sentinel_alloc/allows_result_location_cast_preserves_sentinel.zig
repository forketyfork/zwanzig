// EXPECT: none
const std = @import("std");

fn foo(allocator: std.mem.Allocator) void {
    const content = @as([:0]u8, allocator.dupeZ(u8, "hello") catch return);
    _ = content;
}
