// EXPECT: line=3 rule=identifier-style
fn foo() void {
    _ = bar() catch |BadErr| {};
}

fn bar() !void {}
