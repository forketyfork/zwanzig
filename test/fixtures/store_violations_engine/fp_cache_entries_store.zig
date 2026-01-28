const std = @import("std");
// zwanzig-disable: unused-decl

const Entry = struct {
    value: u8,
};

const Cache = struct {
    entries: []Entry,
    allocator: std.mem.Allocator,

    fn deinit(self: *Cache) void {
        self.allocator.free(self.entries);
    }
};

fn buildCache(allocator: std.mem.Allocator, count: usize) !Cache {
    const entries = try allocator.alloc(Entry, count);
    errdefer allocator.free(entries);

    var cache = Cache{
        .entries = entries,
        .allocator = allocator,
    };
    return cache;
}

fn example() !void {
    const allocator = std.heap.page_allocator;
    var cache = try buildCache(allocator, 4);
    defer cache.deinit();
    _ = cache.entries.len;
}

// NOTE: Known false positive - entries escape via returned cache value.
// EXPECT: line=18 rule=store-violations-engine severity=error message=resource leak
