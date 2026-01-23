// Test: catch error payload shadowed by inner declaration
// EXPECT: line=7 col=15 rule=shadowed-variable message=shadows
fn mayFail() !void {}

fn foo() void {
    mayFail() catch |err| {
        const err = error.Other;
        _ = err;
    };
}
