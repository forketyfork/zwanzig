const std = @import("std");

fn openUrl(comptime cmd: []const u8, allocator: std.mem.Allocator) !void {
    const child = std.process.Child.init(&.{ cmd, "https://example.com" }, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ child });
    thread.detach();
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
