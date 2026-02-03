const std = @import("std");

const Component = struct {
    allocator: std.mem.Allocator,
    name: ?[]u8 = null,

    fn setName(self: *Component, value: []const u8) void {
        if (self.name) |old| self.allocator.free(old);
        self.name = self.allocator.dupe(u8, value) catch return;
    }

    fn deinit(self: *Component) void {
        if (self.name) |val| self.allocator.free(val);
    }
};

fn example() void {
    var comp = Component{ .allocator = std.heap.page_allocator };
    comp.setName("hello");
    comp.deinit();
}

// EXPECT: none
