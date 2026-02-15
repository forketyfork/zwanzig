// EXPECT: rule=divide-by-zero-engine severity=error message=division

pub fn bad() i32 {
    return @divTrunc(10, 0);
}
