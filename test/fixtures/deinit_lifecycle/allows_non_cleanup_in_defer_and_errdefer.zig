// EXPECT: none
const Obj = struct {
    fn doSomething(_: *Obj) void {}
};

fn run() !void {
    var value = Obj{};
    errdefer value.doSomething();
    defer value.doSomething();
}
