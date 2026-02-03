const std = @import("std");

fn openUrl() !void {
    var buf: [4]u8 = undefined;
    const ptr: *u8 = @ptrCast(&buf);
    const thread = try std.Thread.spawn(.{}, worker, .{ ptr });
    thread.detach();
}

fn worker(ptr: *u8) void {
    _ = ptr;
}

// EXPECT: line=6 rule=stack-escape-engine severity=error message=Stack-backed value escapes via thread
