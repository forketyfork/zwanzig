pub const Exposed = struct {
    font: FontConfig = .{},
    load_error: ?LoadError = null,
};

pub const FontConfig = struct {
    family: []const u8 = "mono",
};

pub const LoadError = error{
    Invalid,
};

pub const HelperForUnusedApi = struct {};

pub const StreamType = TypeFactory(Handler);

pub const Handler = struct {};

pub fn makeExposed() Exposed {
    return .{};
}

pub fn unusedApi() HelperForUnusedApi {
    return .{};
}

pub fn unusedFunction() void {}

fn TypeFactory(comptime T: type) type {
    return struct {
        value: T,
    };
}
