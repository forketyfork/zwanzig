// EXPECT: none
const ReturnType = @typeInfo(@TypeOf(main)).@"fn".return_type.?;

pub fn main() void {}
