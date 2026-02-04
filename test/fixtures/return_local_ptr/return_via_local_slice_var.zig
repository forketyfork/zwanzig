// EXPECT: line=5 rule=return-local-ptr severity=warning
fn bad() []const u32 {
    var buf: [2]u32 = undefined;
    const slice = buf[0..];
    return slice;
}
