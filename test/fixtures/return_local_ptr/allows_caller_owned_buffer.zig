// EXPECT: none
fn good(buf: *[2]u32) []const u32 {
    return buf[0..];
}

pub fn main() void {
    var buf: [2]u32 = undefined;
    const slice = good(&buf);
    _ = slice;
}
