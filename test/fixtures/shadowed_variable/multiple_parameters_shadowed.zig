// Test: multiple parameters shadowed
// EXPECT: line=4 col=11 rule=shadowed-variable message=shadows
// EXPECT: line=5 col=11 rule=shadowed-variable message=shadows
fn foo(a: i32, b: i32) void {
    const a = 1;
    const b = 2;
    _ = a;
    _ = b;
}
