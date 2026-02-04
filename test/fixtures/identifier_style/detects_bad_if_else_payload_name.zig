// EXPECT: line=9 rule=identifier-style
fn fallible() !i32 {
    return 1;
}

fn foo() void {
    if (fallible()) |value| {
        _ = value;
    } else |BadErr| {
        _ = BadErr;
    }
}
