// EXPECT: line=9 rule=unreachable-code
fn foo(x: i32) void {
    if (x > 0) {
        return;
    } else {
        return;
    }
    const y: i32 = 10;
    _ = y;
}
