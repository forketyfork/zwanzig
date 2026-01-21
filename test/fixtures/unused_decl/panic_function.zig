// EXPECT: none
const std = @import("std");

fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = trace;
    @panic(msg);
}
