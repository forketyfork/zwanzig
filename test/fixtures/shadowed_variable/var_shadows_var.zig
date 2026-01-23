// Test: var shadowing var
// EXPECT: line=5 col=13 rule=shadowed-variable message=shadows
fn foo() void {
    var x: i32 = 1;
    {
        var x: i32 = 2;
        x += 1;
        _ = x;
    }
    x += 1;
    _ = x;
}
