const Api = @import("typed_receiver_api.zig");

const Wrapper = struct {
    api: Api,

    fn call(self: *Wrapper) void {
        self.api.fieldRun();
    }
};

pub fn main() void {
    var value = Api.init();
    defer value.deinit();
    value.run();

    var wrapper = Wrapper{ .api = value };
    wrapper.call();

    callThroughPointer(&value);
}

fn callThroughPointer(api: *Api) void {
    api.pointerRun();
}
