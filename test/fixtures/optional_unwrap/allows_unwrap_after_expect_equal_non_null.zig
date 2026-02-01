// EXPECT: none
const std = @import("std");

pub fn main() !void {
    var maybe: ?u8 = 5;
    try std.testing.expectEqual(@as(?u8, 5), maybe);
    const v = maybe.?;
    _ = v;
}
