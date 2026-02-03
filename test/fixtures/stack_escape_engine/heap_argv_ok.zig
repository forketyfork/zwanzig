const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    var argv = try allocator.alloc([]const u8, 2);
    argv[0] = "open";
    argv[1] = owned_url;
    const child = std.process.Child.init(argv, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{child});
    thread.join();
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
