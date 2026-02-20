// This test checks that safe accesses are not flagged
const std = @import("std");

fn testSafeAccess() void {
    const arr = [_]u8{ 1, 2, 3, 4, 5 };
    _ = arr[0];
    _ = arr[2];
    _ = arr[4];
}

fn testSafeLoop() void {
    const arr = [_]u8{ 1, 2, 3 };
    for (arr, 0..) |item, i| {
        _ = item;
        if (i < arr.len) {
            _ = arr[i];
        }
    }
}
