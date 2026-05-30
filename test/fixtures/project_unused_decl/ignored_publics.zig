pub extern fn externalFunction() void;

pub export fn exportedFunction() void {}

pub fn main() void {}

pub fn panic(message: []const u8, stack_trace: ?*anyopaque, ret_addr: usize) noreturn {
    _ = message;
    _ = stack_trace;
    _ = ret_addr;
    while (true) {}
}

pub const _explicitly_ignored = 1;

pub const std_options = struct {};
