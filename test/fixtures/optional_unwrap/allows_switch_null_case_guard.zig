// EXPECT: none
pub fn main() ?u8 {
    var maybe: ?u8 = 1;
    switch (maybe) {
        null => return null,
        else => |value| {
            _ = value;
        },
    }
    return maybe.?;
}
