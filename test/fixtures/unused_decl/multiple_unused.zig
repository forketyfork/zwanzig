// EXPECT: line=5 rule=unused-decl message=unused1
// EXPECT: line=6 rule=unused-decl message=unused2
// EXPECT: line=7 rule=unused-decl message=unused_fn
const std = @import("std");
const unused1: i32 = 1;
const unused2: i32 = 2;
fn unused_fn() void {}

pub fn main() void {
    _ = std;
}
