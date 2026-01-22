// EXPECT: none
const std = @import("std");

fn switchPartialReturn(x: u8) void {
    switch (x) {
        0 => return,
        1 => std.debug.print("one\n", .{}),
        else => return,
    }
    const z: i32 = 1;
    _ = z;
}
