// Tests that null check guards the unwrap - no warning expected
// The if (maybe != null) check proves the value is non-null in the then branch
pub fn main() void {
    var maybe: ?u8 = 42;
    if (maybe != null) {
        const value = maybe.?;
        _ = value;
    }
}
