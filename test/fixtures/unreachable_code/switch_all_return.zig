// EXPECT: line=9 rule=unreachable-code
// EXPECT: line=10 rule=unreachable-code
fn switchAllReturn(x: u8) void {
    switch (x) {
        0 => return,
        1 => return,
        else => return,
    }
    const z: i32 = 1;
    _ = z;
}
