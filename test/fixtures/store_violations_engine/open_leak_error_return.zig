const std = @import("std");

fn foo() !void {
    const file = try std.fs.cwd().openFile("foo", .{});
    _ = file;
    return error.Oops;
}

// EXPECT: none
