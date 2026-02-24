// EXPECT: line=9 rule=deinit-lifecycle severity=warning message=both defer and errdefer
const Obj = struct {
    fn deinit(_: *Obj) void {}
};

fn run() !void {
    var value = Obj{};
    defer value.deinit();
    errdefer value.deinit();
}
