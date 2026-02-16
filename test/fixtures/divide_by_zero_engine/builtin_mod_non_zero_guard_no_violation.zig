// EXPECT: none

pub fn ok(x: i32) i32 {
    if (x > 0) {
        return @mod(11, x);
    }
    return 0;
}
