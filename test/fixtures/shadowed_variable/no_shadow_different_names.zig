// Test: no shadow when names are different
// EXPECT: none
fn foo(x: i32) void {
    const y = 5;
    {
        const z = 10;
        _ = z;
    }
    _ = x;
    _ = y;
}
