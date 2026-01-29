const std = @import("std");

fn example(path: []const u8) !void {
    const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);
}

// EXPECT: none
