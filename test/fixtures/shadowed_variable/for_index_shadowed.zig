// Test: for loop index shadowed
// EXPECT: line=6 col=15 rule=shadowed-variable message=shadows
fn foo() void {
    const items = [_]i32{ 1, 2, 3 };
    for (items, 0..) |_, i| {
        const i = 99;
        _ = i;
    }
}
