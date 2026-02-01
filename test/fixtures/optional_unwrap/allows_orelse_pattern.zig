// Tests that orelse pattern is safe (not using .?)
// EXPECT: none
pub fn main() void {
    var maybe: ?u8 = null;
    const value = maybe orelse 0;
    _ = value;
}
