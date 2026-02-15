// EXPECT: rule=divide-by-zero-engine severity=error message=division

pub fn bad() i32 {
    const denominator = 0;
    return @divTrunc(100, denominator);
}
