// EXPECT: none

pub fn ok() f64 {
    return 1.0 / @as(f64, 0);
}
