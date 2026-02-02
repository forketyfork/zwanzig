// Tests that short-circuit OR guards the unwrap
// In `a == null or a.? != x`, the `.?` is only evaluated when a is non-null
// EXPECT: none
pub fn check(a: ?u8, x: u8) bool {
    return a == null or a.? != x;
}
