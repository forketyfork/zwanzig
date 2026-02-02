// Tests that compound short-circuit AND guards multiple optionals
// In `a != null and b != null and a.? + b.? == x`, both unwraps are guarded
// EXPECT: none
pub fn check(a: ?u8, b: ?u8, x: u8) bool {
    return a != null and b != null and a.? + b.? == x;
}
