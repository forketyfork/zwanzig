// EXPECT: line=3 rule=identifier-style
fn foo() !void {
    errdefer |BadErr| {};
    return;
}
