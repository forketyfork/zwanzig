// Test: sibling scopes don't shadow each other
// EXPECT: none
fn foo() void {
    {
        const x = 1;
        _ = x;
    }
    {
        const x = 2;
        _ = x;
    }
}
