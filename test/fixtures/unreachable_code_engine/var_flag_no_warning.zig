// EXPECT: none
fn foo(cond: bool) i32 {
    var flag = true;
    if (cond) flag = false;
    if (flag) return 1;
    return 0;
}
