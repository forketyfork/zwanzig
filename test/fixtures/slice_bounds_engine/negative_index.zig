// EXPECT: rule=slice-bounds-engine severity=error message=out
const std = @import("std");

fn testNegativeIndex() void {
    const arr = [_]u8{ 1, 2, 3, 4, 5 };
    const idx: i32 = -1;
    _ = arr[@intCast(idx)];
}
