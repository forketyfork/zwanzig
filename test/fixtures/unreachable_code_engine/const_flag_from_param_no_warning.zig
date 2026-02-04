// EXPECT: none
fn foo(cond: bool) i32 {
    const flag = cond;
    if (flag) return 1;
    return 0;
}
