// EXPECT: line=4 rule=empty-defer
fn foo(x: bool) void {
    if (x) {
        defer {}
    }
}
