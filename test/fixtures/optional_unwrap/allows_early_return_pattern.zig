// Tests that early return null check guards the unwrap
// If maybe == null, we return early, so the unwrap is only reached when non-null
pub fn main() ?u8 {
    var maybe: ?u8 = 42;
    if (maybe == null) {
        return null;
    }
    return maybe.?;
}
