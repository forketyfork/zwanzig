const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    var argv: [2][]const u8 = .{ "open", owned_url };
    const child = std.process.Child.init(argv[0..], allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ child });
    thread.detach();
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: line=7 rule=stack-escape-engine severity=error message=Stack-backed value escapes via thread
