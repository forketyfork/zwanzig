// EXPECT: line=7 rule=optional-unwrap message=forced optional unwrap
const std = @import("std");

pub fn main() !void {
    var maybe: ?u8 = null;
    try std.testing.expectEqual(@as(?u8, null), maybe);
    const v = maybe.?;
    _ = v;
}
