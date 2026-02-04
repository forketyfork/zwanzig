// EXPECT: line=1 rule=file-as-struct message=lowercase
pub count: usize = 0,
name: []const u8 = "",

pub fn init() @This() {
    return .{ .count = 1, .name = "init" };
}
