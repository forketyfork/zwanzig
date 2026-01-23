// Test: for loop payload shadowed by inner declaration
// EXPECT: line=6 col=15 rule=shadowed-variable message=shadows
fn foo() void {
    const items = [_]i32{ 1, 2, 3 };
    for (items) |item| {
        const item = 0;
        _ = item;
    }
}
