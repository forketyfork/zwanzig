// EXPECT: rule=divide-by-zero-engine severity=warning message=possible

pub fn warn(flag: bool) i32 {
    var x: i32 = 0;
    if (flag) {
        x = -1;
    }
    return @divTrunc(10, x + 1);
}
