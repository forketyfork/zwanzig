const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const thread_allocator = std.heap.c_allocator;
    const owned_url = try thread_allocator.dupe(u8, url);
    const child = std.process.Child.init(&.{ "open", owned_url }, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ thread_allocator, child, owned_url });
    thread.join();
}

fn openUrlThread(allocator: std.mem.Allocator, child: std.process.Child, url: []const u8) void {
    _ = allocator;
    _ = child;
    _ = url;
}

// EXPECT: none
