// Tests that short-circuit AND guards the unwrap
// In `a != null and a.? == x`, the `.?` is only evaluated when a is non-null
// EXPECT: none
pub fn check(a: ?u8, x: u8) bool {
    return a != null and a.? == x;
}
