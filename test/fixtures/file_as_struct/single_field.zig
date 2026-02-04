// EXPECT: line=1 rule=file-as-struct message=lowercase
value: i32,

pub fn init() @This() {
    return .{ .value = 0 };
}
