// EXPECT: none
const std = @import("std");

fn foo() void {
    var x: i32 = 42;
    defer x = 0;
    std.debug.print("{d}\n", .{x});
}
