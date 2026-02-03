const std = @import("std");

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    url: []u8,

    pub fn deinit(self: *ThreadContext) void {
        self.allocator.free(self.url);
    }
};

fn foo(allocator: std.mem.Allocator, url: []const u8) !void {
    const ctx = allocator.create(ThreadContext) catch return error.OutOfMemory;
    errdefer allocator.destroy(ctx);

    ctx.allocator = allocator;
    ctx.url = allocator.dupe(u8, url) catch return error.OutOfMemory;
    errdefer allocator.free(ctx.url);

    ctx.deinit();
    return error.OutOfMemory;
}

// CONFIG: {"resource_models":[{"kind":"free_owned","method_name":"deinit"}]}
// EXPECT: line=18 rule=store-violations-engine message=double-free
