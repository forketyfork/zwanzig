// EXPECT: line=3 rule=unused-decl message=unused_value
const std = @import("std");
const unused_value: i32 = 42;

pub fn main() void {
    _ = std;
}
