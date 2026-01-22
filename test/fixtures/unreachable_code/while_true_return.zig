// EXPECT: line=7 rule=unreachable-code
// EXPECT: line=8 rule=unreachable-code
fn whileTrueReturn() void {
    while (true) {
        return;
    }
    const z: i32 = 1;
    _ = z;
}
