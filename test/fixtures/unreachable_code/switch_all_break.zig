// EXPECT: none
fn switchAllBreak(x: u8) void {
    blk: {
        switch (x) {
            0 => break :blk,
            1 => break :blk,
            else => break :blk,
        }
    }
    const z: i32 = 1;
    _ = z;
}
