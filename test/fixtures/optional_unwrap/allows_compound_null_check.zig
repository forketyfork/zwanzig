// Tests that compound null checks with 'or' guard both optionals
// If a == null OR b == null, we return early, so both are non-null after
// EXPECT: none
pub fn main() ?u8 {
    var a: ?u8 = 42;
    var b: ?u8 = 10;
    if (a == null or b == null) {
        return null;
    }
    return a.? + b.?;
}
