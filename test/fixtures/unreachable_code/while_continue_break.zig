// EXPECT: none
fn whileContinueBreak(x: i32) void {
    while (x > 0) {
        if (x > 10) {
            continue;
        }
        break;
    }
    const z: i32 = 1;
    _ = z;
}
