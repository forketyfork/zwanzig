// Test: if optional unwrap payload shadowed by inner declaration
// EXPECT: line=5 col=15 rule=shadowed-variable message=shadows
fn foo(opt: ?i32) void {
    if (opt) |value| {
        const value = 0;
        _ = value;
    }
}
