const std = @import("std");

const testing = struct {
    pub fn expect(_: bool) void {}
};

pub fn main() void {
    var maybe: ?u8 = null;
    testing.expect(maybe != null);
    const v = maybe.?;
    _ = v;
    _ = std;
}
// EXPECT: line=10 rule=optional-unwrap message=forced optional unwrap
