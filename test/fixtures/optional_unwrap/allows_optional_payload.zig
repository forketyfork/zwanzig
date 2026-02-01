pub fn main() void {
    var maybe: ?u8 = 1;
    if (maybe) |value| {
        _ = value;
    }
}
// EXPECT: none
