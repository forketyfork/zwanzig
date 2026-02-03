const std = @import("std");

const Owner = struct {
    allocator: std.mem.Allocator,
    buf: []u8,

    fn deinit(self: *Owner, _: std.mem.Allocator) void {
        self.allocator.free(self.buf);
    }
};

fn example() !void {
    const allocator = std.heap.page_allocator;
    const buf = try allocator.alloc(u8, 1);
    var owner = Owner{ .allocator = allocator, .buf = buf };
    defer owner.deinit(allocator);
    _ = owner;
}

// CONFIG: {"resource_models":[{"kind":"free_owned","method_name":"deinit"}]}
// EXPECT: none
