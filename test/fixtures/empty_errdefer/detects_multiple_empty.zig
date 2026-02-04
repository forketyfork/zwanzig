// EXPECT: line=4 rule=empty-errdefer
// EXPECT: line=6 rule=empty-errdefer
fn foo() !void {
    errdefer {}
    if (true) {
        errdefer {}
    }
}
