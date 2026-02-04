// EXPECT: line=8 rule=return-local-ptr severity=warning
fn fill(buf: *[2]u32) []const u32 {
    return buf[0..];
}

fn bad() []const u32 {
    var buf: [2]u32 = undefined;
    return fill(&buf);
}
