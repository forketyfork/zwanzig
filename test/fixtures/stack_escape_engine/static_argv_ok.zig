const std = @import("std");

fn openUrl(allocator: std.mem.Allocator) !void {
    const child = std.process.Child.init(&.{ "open", "https://example.com" }, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{child});
    thread.join();
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
