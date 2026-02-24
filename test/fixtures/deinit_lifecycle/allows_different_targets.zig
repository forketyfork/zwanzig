// EXPECT: none
const Obj = struct {
    fn deinit(_: *Obj) void {}
};

fn run() !void {
    var left = Obj{};
    var right = Obj{};
    errdefer left.deinit();
    defer right.deinit();
}
