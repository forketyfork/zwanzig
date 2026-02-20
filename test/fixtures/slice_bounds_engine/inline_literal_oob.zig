// EXPECT: rule=slice-bounds-engine severity=error message=definitely

pub fn bad() void {
    _ = ([_]u8{ 1, 2, 3 })[4];
}
