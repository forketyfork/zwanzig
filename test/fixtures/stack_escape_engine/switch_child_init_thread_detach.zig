const std = @import("std");

fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const thread_allocator = std.heap.c_allocator;
    const owned_url = try thread_allocator.dupe(u8, url);
    const mode: u2 = 0;
    const child = switch (mode) {
        0 => std.process.Child.init(&.{ "open", owned_url }, allocator),
        1 => std.process.Child.init(&.{ "xdg-open", owned_url }, allocator),
        else => std.process.Child.init(&.{ "rundll32", "url.dll,FileProtocolHandler", owned_url }, allocator),
    };
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ thread_allocator, child, owned_url });
    thread.detach();
    _ = thread;
}

fn openUrlThread(allocator: std.mem.Allocator, child: std.process.Child, url: []const u8) void {
    _ = allocator;
    _ = child;
    _ = url;
}

// EXPECT: line=12 rule=stack-escape-engine severity=error message=Stack-backed value escapes via thread
