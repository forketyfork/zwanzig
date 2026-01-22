// EXPECT: none
fn whileTrueWithBreak(x: i32) void {
    while (true) {
        if (x > 0) {
            break;
        }
    }
    const z: i32 = 1;
    _ = z;
}
