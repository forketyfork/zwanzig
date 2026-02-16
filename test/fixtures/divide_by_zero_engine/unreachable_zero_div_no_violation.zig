// EXPECT: none

pub fn ok() i32 {
    if (false) {
        return @divTrunc(1, 0);
    }
    return 0;
}
