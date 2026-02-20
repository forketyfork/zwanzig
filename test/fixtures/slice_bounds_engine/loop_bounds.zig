// This test checks detection of potential out-of-bounds in loops
const std = @import("std");

fn testLoopOOB() void {
    const arr = [_]u8{ 1, 2, 3 };
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // EXPECT: slice-bounds-engine: Array/slice index may be out of bounds
        _ = arr[i];
    }
}
