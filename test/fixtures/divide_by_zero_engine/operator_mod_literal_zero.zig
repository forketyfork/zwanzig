// EXPECT: rule=divide-by-zero-engine severity=error message=modulo

pub fn bad() i32 {
    return @as(i32, 15) % @as(i32, 0);
}
