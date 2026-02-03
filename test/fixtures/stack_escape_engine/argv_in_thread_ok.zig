const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ allocator, owned_url });
    thread.join();
}

fn openUrlThread(allocator: std.mem.Allocator, owned_url: []const u8) void {
    const argv = [_][]const u8{ "open", owned_url };
    var child = std.process.Child.init(&argv, allocator);
    _ = child;
}

// EXPECT: none
