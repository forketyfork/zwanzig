// Tests that optional initialized with a concrete value is safe to unwrap
// The checker tracks that maybe was initialized with 42 (non-null)
pub fn main() void {
    const maybe: ?u8 = 42;
    const value = maybe.?;
    _ = value;
}
