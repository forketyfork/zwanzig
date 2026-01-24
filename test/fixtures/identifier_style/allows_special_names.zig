// EXPECT: none
pub fn main() void {}
pub fn panic(msg: []const u8, trace: ?*anyopaque, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = trace;
    _ = ret_addr;
    while (true) {}
}
