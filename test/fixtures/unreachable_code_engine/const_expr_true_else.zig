// EXPECT: none
fn foo() i32 {
    const enabled = (1 + 1) == 2;
    if (enabled) {
        return 1;
    } else {
        return 0;
    }
}
