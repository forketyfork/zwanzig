const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    const child = std.process.Child.init(&.{ "open", owned_url }, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ child });
    if (url.len > 0) {
        thread.join();
    } else {
        thread.join();
    }
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
