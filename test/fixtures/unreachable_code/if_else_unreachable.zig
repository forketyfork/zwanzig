// EXPECT: line=9 rule=unreachable-code
// EXPECT: line=10 rule=unreachable-code
fn ifElseUnreachable(x: bool) void {
    if (x) {
        return;
    } else {
        unreachable;
    }
    const z: i32 = 1;
    _ = z;
}
