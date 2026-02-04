// EXPECT: line=3 rule=identifier-style
fn foo(opt: ?i32) void {
    while (opt) |BadValue| {
        _ = BadValue;
        break;
    }
}
