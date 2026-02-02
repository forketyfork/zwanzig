// Tests that null check followed by break guards the unwrap
// Pattern: if (x == null) break; x.?
// EXPECT: none
pub fn main() void {
    var maybe: ?u8 = 42;
    while (true) {
        if (maybe == null) break;
        const val = maybe.?;
        _ = val;
        break;
    }
}
