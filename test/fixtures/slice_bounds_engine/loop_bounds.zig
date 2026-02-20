// EXPECT: rule=slice-bounds-engine severity=error message=may

pub fn maybeOob(flag: bool) void {
    const arr = [_]u8{ 1, 2, 3 };
    var idx: i32 = 1;
    if (flag) {
        idx = 5;
    }
    _ = arr[@intCast(idx)];
}
