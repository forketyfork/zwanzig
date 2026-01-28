const std = @import("std");

fn foo() !void {
    var file = try std.fs.cwd().openFile("foo", .{});
    file.close();
}

// EXPECT: none
