// EXPECT: none
const Inner = struct {
    value: i32,
};

pub fn create() Inner {
    return .{ .value = 42 };
}
