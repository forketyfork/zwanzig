// Test: function parameter shadowed by local variable
// EXPECT: line=4 col=11 rule=shadowed-variable message=shadows
fn foo(x: i32) void {
    const x = 5;
    _ = x;
}
