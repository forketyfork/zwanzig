// Test: pointer payload shadowed
// EXPECT: line=6 col=15 rule=shadowed-variable message=shadows
fn foo() void {
    var items = [_]i32{ 1, 2, 3 };
    for (&items) |*item| {
        const item = @as(*i32, undefined);
        _ = item;
    }
}
