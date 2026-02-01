// EXPECT: none
const std = @import("std");
usingnamespace std.testing;

pub fn main() !void {
    var maybe: ?u8 = 1;
    try expect(maybe != null);
    const v = maybe.?;
    _ = v;
    _ = std;
}
