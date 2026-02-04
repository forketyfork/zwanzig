// EXPECT: line=4 rule=empty-errdefer
fn foo() !void {
    if (true) {
        errdefer {}
    }
}
