// CONFIG: {"escape_models":[{"method_name":"capture","receiver_type":"Sink","param_indices":[0],"captures_into":"receiver"}]}
// EXPECT: rule=stack-escape-engine severity=error message=Stack
// zwanzig-disable: unused-decl

const Sink = struct {
    fn capture(_: *Sink, _: []u8) void {}
};

fn storesStackSlice() void {
    var sink = Sink{};
    var buffer = [_]u8{ 0, 1, 2, 3 };
    sink.capture(buffer[0..]);
}
