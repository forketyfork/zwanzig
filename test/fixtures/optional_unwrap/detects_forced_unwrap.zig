// EXPECT: line=6 rule=optional-unwrap message=forced optional unwrap
const std = @import("std");

pub fn main() void {
    var maybe: ?u8 = null;
    const value = maybe.?;
    _ = value;
    _ = std;
}
