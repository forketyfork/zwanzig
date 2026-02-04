// Test: for payload shadows outer declaration
// EXPECT: line=6 col=18 rule=shadowed-variable message=shadows
fn foo() void {
    const item = 0;
    const items = [_]i32{ 1, 2, 3 };
    for (items) |item| {
        _ = item;
    }
    _ = item;
}
