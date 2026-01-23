// Test: underscore-prefixed variables are allowed to shadow
// EXPECT: none
fn foo(_x: i32) void {
    const _x = 5;
    _ = _x;
}

fn bar() void {
    const _unused = 1;
    {
        const _unused = 2;
        _ = _unused;
    }
    _ = _unused;
}
