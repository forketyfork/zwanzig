// EXPECT: line=12 rule=sentinel-alloc severity=warning message=allocSentinel allocates len+1 bytes
const std = @import("std");

// This struct uses container_decl_two internally (0-2 members)
// Tests that the rule handles structs with few fields without panicking
const Config = struct {
    value: u32,
};

pub fn foo(allocator: std.mem.Allocator) void {
    _ = Config;
    const s: []u8 = allocator.allocSentinel(u8, 10, 0) catch return;
    _ = s;
}
