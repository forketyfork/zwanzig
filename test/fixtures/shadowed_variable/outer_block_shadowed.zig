// Test: outer block variable shadowed by inner block variable
// EXPECT: line=6 col=15 rule=shadowed-variable message=shadows
fn foo() void {
    const value = 5;
    {
        const value = 10;
        _ = value;
    }
    _ = value;
}
