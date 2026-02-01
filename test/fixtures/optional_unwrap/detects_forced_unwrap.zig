const std = @import("std");

pub fn main() void {
    var maybe: ?u8 = null;
    const value = maybe.?; // EXPECT: line=5 rule=optional-unwrap message=forced optional unwrap
    _ = value;
    _ = std;
}
