// EXPECT: line=1 rule=file-as-struct message=lowercase
count: usize,
name: []const u8,

pub fn init() @This() {
    return .{ .count = 0, .name = "" };
}
