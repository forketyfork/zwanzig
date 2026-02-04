// EXPECT: line=6 rule=return-local-ptr severity=warning
fn outer(buf: *[2]u32) []const u32 {
    const Inner = struct {
        fn bad() []const u32 {
            var inner_buf: [2]u32 = undefined;
            return inner_buf[0..];
        }
    };

    _ = Inner;
    return buf[0..];
}
