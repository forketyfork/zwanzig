// EXPECT: line=4 rule=unreachable-code-engine
fn foo() void {
    const loop = 2 > 3;
    while (loop) {
        doWork();
    }
}
