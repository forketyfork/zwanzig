// EXPECT: line=16 rule=deinit-lifecycle severity=hint message=fallible reinitialization
// EXPECT: line=17 rule=deinit-lifecycle severity=hint message=fallible reinitialization
const Obj = struct {
    fn deinit(_: *Obj) void {}
};

fn makeObj() !Obj {
    return Obj{};
}

fn run() !void {
    var first = Obj{};
    var second = Obj{};
    defer first.deinit();
    defer second.deinit();
    first.deinit();
    second.deinit();
    first = try makeObj();
    second = try makeObj();
}
