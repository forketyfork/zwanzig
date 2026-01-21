// EXPECT: line=4 rule=unreachable-code
fn foo() void {
    return;
    const x: i32 = 42;
    _ = x;
}
