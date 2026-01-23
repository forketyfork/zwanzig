// Test: errdefer payload shadowed by inner declaration
// EXPECT: line=5 col=15 rule=shadowed-variable message=shadows
fn foo() !void {
    errdefer |err| {
        const err = error.Other;
        _ = err;
    }
}
