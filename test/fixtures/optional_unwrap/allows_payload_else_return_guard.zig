// EXPECT: none
pub fn main() ?u8 {
    var maybe: ?u8 = 1;
    if (maybe) |value| {
        _ = value;
    } else {
        return null;
    }
    return maybe.?;
}
