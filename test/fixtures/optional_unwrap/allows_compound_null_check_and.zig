// Tests that compound null checks with 'and' guard optionals correctly
// If a != null AND b != null, both are non-null in the then branch
// EXPECT: none
pub fn process(a: ?u8, b: ?u8) u8 {
    if (a != null and b != null) {
        return a.? + b.?;
    }
    return 0;
}

pub fn main() void {
    _ = process(1, 2);
}
