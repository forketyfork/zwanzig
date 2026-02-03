const std = @import("std");

// CONFIG: {"escape_max_depth": 1}

fn wrap1(child: std.process.Child) std.process.Child {
    return child;
}

fn wrap2(child: std.process.Child) std.process.Child {
    return child;
}

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    const child = std.process.Child.init(&.{ "open", owned_url }, allocator);
    const wrapped = wrap2(wrap1(child));
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{wrapped});
    thread.detach();
    _ = thread;
}

fn openUrlThread(child: std.process.Child) void {
    _ = child;
}

// EXPECT: none
