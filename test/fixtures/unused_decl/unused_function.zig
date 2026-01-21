// EXPECT: line=3 rule=unused-decl message=unused_helper
const std = @import("std");
fn unused_helper() void {}

pub fn main() void {
    _ = std;
}
