// This test checks detection of definite out-of-bounds access with literal index
const std = @import("std");

fn testOutOfBounds() void {
    const arr = [_]u8{ 1, 2, 3 };
    // EXPECT: slice-bounds-engine: Array/slice index is definitely out of bounds
    _ = arr[5];
}
