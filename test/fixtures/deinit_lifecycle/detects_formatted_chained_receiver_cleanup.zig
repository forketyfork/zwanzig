// EXPECT: rule=deinit-lifecycle severity=hint message=fallible reinitialization
const Obj = struct {
    fn deinit(_: *Obj) void {}
};

const Holder = struct {
    value: Obj,
};

fn makeObj() !Obj {
    return Obj{};
}

fn run() !void {
    var holder = Holder{ .value = Obj{} };
    defer holder.value.deinit();
    holder . value.deinit();
    holder . value = try makeObj();
}
