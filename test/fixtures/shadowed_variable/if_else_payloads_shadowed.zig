// Test: if-else error and optional payloads shadowed
// EXPECT: line=7 col=15 rule=shadowed-variable message=shadows
fn mayFail() !?i32 {
    return 42;
}

fn foo() void {
    if (mayFail()) |value| {
        const value = 0;
        _ = value;
    } else |_| {}
}
