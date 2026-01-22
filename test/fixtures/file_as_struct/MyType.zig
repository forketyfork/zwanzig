// EXPECT: none
count: usize,
name: []const u8,

pub fn init() @This() {
    return .{ .count = 0, .name = "" };
}
