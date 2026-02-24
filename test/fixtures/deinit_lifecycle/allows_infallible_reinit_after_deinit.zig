// EXPECT: none
const Obj = struct {
    fn deinit(_: *Obj) void {}
};

fn makeObj() Obj {
    return Obj{};
}

fn run() !void {
    var value = Obj{};
    defer value.deinit();
    value.deinit();
    value = makeObj();
}
