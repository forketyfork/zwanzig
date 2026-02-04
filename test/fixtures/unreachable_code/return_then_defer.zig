// EXPECT: line=4 rule=unreachable-code
fn returnThenDefer() void {
    return;
    defer foo();
}

fn foo() void {}
