// Test: multiple nested block shadows
// EXPECT: line=7 col=15 rule=shadowed-variable message=shadows
// EXPECT: line=9 col=19 rule=shadowed-variable message=shadows
fn foo() void {
    const x = 1;
    {
        const x = 2;
        {
            const x = 3;
            _ = x;
        }
        _ = x;
    }
    _ = x;
}
