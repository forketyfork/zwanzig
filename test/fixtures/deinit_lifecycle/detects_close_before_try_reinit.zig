// EXPECT: line=13 rule=deinit-lifecycle severity=hint message=fallible reinitialization
const Obj = struct {
    fn close(_: *Obj) void {}
};

fn makeObj() !Obj {
    return Obj{};
}

fn run() !void {
    var value = Obj{};
    defer value.close();
    value.close();
    value = try makeObj();
}
