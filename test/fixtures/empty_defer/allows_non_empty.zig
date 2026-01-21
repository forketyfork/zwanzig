// EXPECT: none
fn foo() void {
    var x: i32 = 42;
    defer x = 0;
    _ = x;
}
