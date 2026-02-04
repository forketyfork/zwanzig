// Test: if payload shadows outer declaration
// EXPECT: line=5 col=15 rule=shadowed-variable message=shadows
fn foo(opt: ?i32) void {
    const value = 1;
    if (opt) |value| {
        _ = value;
    }
    _ = value;
}
