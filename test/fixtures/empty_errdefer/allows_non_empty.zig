// EXPECT: none
fn foo() !void {
    var x: i32 = 42;
    errdefer x = 0;
    _ = x;
    return;
}
