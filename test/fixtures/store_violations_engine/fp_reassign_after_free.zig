const std = @import("std");

fn climbPath(allocator: std.mem.Allocator, start: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start);
    errdefer allocator.free(current);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (current.len <= 1) break;

        // Allocate new path
        const parent = try allocator.dupe(u8, current[0 .. current.len - 1]);

        // Free old, reassign to new - not use-after-free or double-free
        allocator.free(current);
        current = parent;
    }

    if (current.len <= 1) {
        allocator.free(current);
        return null;
    }
    return current;
}

// EXPECT: none
