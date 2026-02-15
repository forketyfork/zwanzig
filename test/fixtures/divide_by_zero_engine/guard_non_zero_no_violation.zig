// EXPECT: none

pub fn ok(x: i32) i32 {
    if (x != 0) {
        return @divTrunc(10, x);
    }
    return 0;
}
