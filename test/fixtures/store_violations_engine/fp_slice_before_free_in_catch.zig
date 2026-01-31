const std = @import("std");
// zwanzig-disable: unused-decl

// Regression test: allocation with catch block that passes slice to function then frees.
// The code correctly frees entries on error.
// Pattern from architect's recent_folders_overlay.zig lines 538-544

const Entry = struct {
    value: u8,
};

const Cache = struct {
    entries: []Entry,
};

fn destroyEntryTextures(entries: []Entry) void {
    for (entries) |*e| {
        e.value = 0;
    }
}

fn makeTexture() !u8 {
    return error.Failed;
}

const Self = struct {
    allocator: std.mem.Allocator,
    cache: ?*Cache,

    fn buildCache(self: *Self, count: usize) ?*Cache {
        const cache = self.allocator.create(Cache) catch return null;

        const entries = self.allocator.alloc(Entry, count) catch {
            self.allocator.destroy(cache);
            return null;
        };
        errdefer self.allocator.free(entries);

        for (0..count) |idx| {
            entries[idx] = .{ .value = @intCast(idx) };

            const tex = makeTexture() catch {
                // Pass a slice of entries, then free
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                self.allocator.destroy(cache);
                return null;
            };
            _ = tex;
        }

        cache.* = .{
            .entries = entries,
        };

        self.cache = cache;
        return cache;
    }
};

// EXPECT: none
