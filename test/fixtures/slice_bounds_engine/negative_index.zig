// This test checks detection of negative index access
const std = @import("std");

fn testNegativeIndex() void {
    const arr = [_]u8{ 1, 2, 3, 4, 5 };
    const idx: i32 = -1;
    // EXPECT: slice-bounds-engine: Array/slice index may be out of bounds
    _ = arr[@intCast(idx)];
}
