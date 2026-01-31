// EXPECT: line=2 rule=unused-parameter message=Unused parameter 'unused_param'
fn foo(unused_param: i32, used: i32) void {
    _ = used;
}
