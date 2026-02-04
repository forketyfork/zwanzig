// EXPECT: line=3 rule=unused-parameter message=Unused parameter 'a'
// EXPECT: line=3 rule=unused-parameter message=Unused parameter 'b'
fn foo(a: i32, b: i32, used: i32) void {
    _ = used;
}
