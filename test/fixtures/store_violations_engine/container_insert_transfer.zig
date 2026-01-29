const std = @import("std");
// zwanzig-disable: unused-decl

fn appendOwned(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const duped = try allocator.dupe(u8, value);
    errdefer allocator.free(duped);
    try list.insert(allocator, 0, duped);
}

fn clearList(list: *std.ArrayList([]u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| {
        allocator.free(item);
    }
    list.clearRetainingCapacity();
}

fn useList(allocator: std.mem.Allocator) void {
    var list: std.ArrayList([]u8) = .empty;
    defer {
        clearList(&list, allocator);
        list.deinit(allocator);
    }

    appendOwned(&list, allocator, "hello") catch return;
}

// EXPECT: none
