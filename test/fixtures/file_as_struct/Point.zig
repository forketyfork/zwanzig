// EXPECT: none
const std = @import("std");
x: i32,
y: i32,

pub fn origin() @This() {
    return .{ .x = 0, .y = 0 };
}
