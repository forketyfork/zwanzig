// EXPECT: line=3 rule=identifier-style
fn foo(opt: ?i32) void {
    if (opt) |BadValue| {
        _ = BadValue;
    }
}
