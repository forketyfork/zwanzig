// EXPECT: none

pub fn ok() f64 {
    var denominator: f64 = 0;
    denominator += 1;
    return 1.0 / denominator;
}
