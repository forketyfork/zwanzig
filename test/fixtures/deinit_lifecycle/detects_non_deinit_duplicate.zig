// EXPECT: line=8 rule=deinit-lifecycle severity=warning message=both defer and errdefer
const Obj = struct {
    fn close(_: *Obj) void {}
};

fn run() !void {
    var value = Obj{};
    errdefer value.close();
    defer value.close();
}
