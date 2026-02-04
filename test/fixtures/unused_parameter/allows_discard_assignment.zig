// EXPECT: none
fn foo(unused: i32, used: i32) void {
    _ = used;
    _ = unused;
}
