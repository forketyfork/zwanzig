const Api = @import("result_location_api.zig");

pub fn main() !void {
    const pointer: *Api = try .create();
    const value: Api = .init();

    _ = pointer;
    _ = value;
}
