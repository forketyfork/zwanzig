// EXPECT: none
const std = @import("std");

pub fn helper() void {
    std.debug.print("Hello\n", .{});
}
