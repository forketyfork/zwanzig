// EXPECT: line=3 rule=empty-errdefer
fn foo() !void {
    errdefer {}
    return;
}
