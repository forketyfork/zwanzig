const std = @import("std");

const Ctx = struct {};

fn foo(allocator: std.mem.Allocator) !void {
    const ctx = allocator.create(Ctx) catch return error.OutOfMemory;
    errdefer allocator.destroy(ctx);

    allocator.destroy(ctx);
    return error.OutOfMemory;
}

// EXPECT: line=7 rule=store-violations-engine message=double-free
