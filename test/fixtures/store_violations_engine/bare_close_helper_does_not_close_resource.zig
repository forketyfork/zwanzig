const std = @import("std");

fn close(_: std.fs.File) void {}

fn foo() !void {
    var file = try std.fs.cwd().openFile("foo", .{});
    close(file);
}

// EXPECT: rule=store-violations-engine severity=error message=resource leak
