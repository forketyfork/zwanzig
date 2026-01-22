// EXPECT: none
fn foo() void {
    defer {
        const x: i32 = 42;
        _ = x;
    }
}
