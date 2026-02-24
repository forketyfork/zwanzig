// EXPECT: none
const Obj = struct {
    fn deinit(_: *Obj) void {}
    fn close(_: *Obj) void {}
};

fn makeObj() !Obj {
    return Obj{};
}

fn run() !void {
    var value = Obj{};
    defer value.close();
    value.deinit();
    value = try makeObj();
}
