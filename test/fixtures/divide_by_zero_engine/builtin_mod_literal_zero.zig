// EXPECT: rule=divide-by-zero-engine severity=error message=modulo

pub fn bad() i32 {
    return @mod(10, 0);
}
