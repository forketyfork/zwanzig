// Test: sibling if/else scopes do not shadow
// EXPECT: none
fn foo(cond: bool) void {
    if (cond) {
        const value = 1;
        _ = value;
    } else {
        const value = 2;
        _ = value;
    }
}
