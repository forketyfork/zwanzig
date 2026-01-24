// EXPECT: line=4 rule=identifier-style
fn foo() void {
    const items = [_]i32{ 1, 2 };
    for (items) |Item| {
        _ = Item;
    }
}
