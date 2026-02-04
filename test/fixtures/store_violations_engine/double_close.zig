const std = @import("std");

fn foo() !void {
    var file = try std.fs.cwd().openFile("foo", .{});
    file.close();
    file.close();
}

// EXPECT: line=6 rule=store-violations-engine severity=error
