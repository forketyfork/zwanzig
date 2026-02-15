// EXPECT: rule=divide-by-zero-engine severity=error message=division

pub fn bad(x: i32) i32 {
    var denominator: i32 = 1;
    if (x == 0) {
        denominator = 0;
    } else {
        return 1;
    }
    return @divTrunc(10, denominator);
}
