// EXPECT: line=4 rule=return-local-ptr severity=warning
fn bad() *[2]u32 {
    var buf: [2]u32 = undefined;
    return &buf;
}
