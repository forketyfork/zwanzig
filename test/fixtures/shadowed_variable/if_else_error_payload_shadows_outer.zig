// Test: if-else error payload shadows outer declaration
// EXPECT: line=11 col=13 rule=shadowed-variable message=shadows
fn mayFail() !i32 {
    return 1;
}

fn foo() void {
    const err = error.Other;
    if (mayFail()) |value| {
        _ = value;
    } else |err| {
        _ = err;
    }
    _ = err;
}
