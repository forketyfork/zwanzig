// EXPECT: rule=slice-bounds-engine severity=error message=definitely
const std = @import("std");

fn testOutOfBounds() void {
    const arr = [_]u8{ 1, 2, 3 };
    _ = arr[5];
}
