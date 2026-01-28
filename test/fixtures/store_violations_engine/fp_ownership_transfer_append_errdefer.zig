const std = @import("std");

const Item = struct {
    path: []u8,
    name: []u8,
};

fn addItem(allocator: std.mem.Allocator, list: *std.ArrayList(Item), path: []const u8, name: []const u8) !void {
    const path_copy = try allocator.dupe(u8, path);
    const name_copy = allocator.dupe(u8, name) catch {
        allocator.free(path_copy);
        return error.OutOfMemory;
    };
    list.append(allocator, .{ .path = path_copy, .name = name_copy }) catch {
        allocator.free(path_copy);
        allocator.free(name_copy);
        return error.OutOfMemory;
    };
    // Ownership transferred to list on success - not a leak
}

// EXPECT: none
