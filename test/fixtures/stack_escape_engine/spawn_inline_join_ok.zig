const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    const child = std.process.Child.init(&.{ "open", owned_url }, allocator);
    try std.Thread.spawn(.{}, openUrlThread, .{ child }).join();
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
