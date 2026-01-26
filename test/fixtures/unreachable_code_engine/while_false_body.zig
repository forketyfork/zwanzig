// EXPECT: line=3 rule=unreachable-code-engine
fn foo() void {
    while (false) {
        doWork();
    }
}
