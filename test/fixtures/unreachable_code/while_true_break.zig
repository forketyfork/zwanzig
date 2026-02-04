// EXPECT: none
fn whileTrueBreak() void {
    while (true) {
        break;
    }
    const z: i32 = 1;
    _ = z;
}
