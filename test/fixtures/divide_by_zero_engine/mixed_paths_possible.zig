// EXPECT: rule=divide-by-zero-engine severity=warning message=possible

pub fn warn(flag: bool) i32 {
    var d: i32 = 2;
    if (flag) {
        d = 0;
    }
    return @divTrunc(20, d);
}
