// EXPECT: none
fn foo() void {
    const loop = 2 > 3;
    while (loop) {
        doWork();
    }
}
