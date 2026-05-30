const api_surface = @import("api_surface.zig");

pub fn main() void {
    _ = api_surface.makeExposed();
    _ = api_surface.StreamType;
}
