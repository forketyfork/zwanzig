const std = @import("std");
// zwanzig-disable: unused-decl

const Context = struct {
    root: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Context) void {
        self.allocator.free(self.root);
    }
};

fn findContext(allocator: std.mem.Allocator, start: []const u8) !?Context {
    var current = try allocator.dupe(u8, start);
    errdefer allocator.free(current);

    if (current.len == 0) {
        allocator.free(current);
        return null;
    }

    if (current[0] == 'x') {
        const root = try allocator.dupe(u8, current);
        allocator.free(current);
        return Context{ .root = root, .allocator = allocator };
    }

    allocator.free(current);
    return null;
}

// EXPECT: none
