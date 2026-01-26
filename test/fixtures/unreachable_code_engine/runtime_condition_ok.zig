// EXPECT: none
fn foo(trueValue: bool, falsey: bool) void {
    if (trueValue) {
        doWork();
    }
    if (falsey) {
        doWork();
    }
}
