const std = @import("std");

fn foo() !void {
    var file = try std.fs.cwd().openFile("foo", .{});
    file.close();
    _ = try file.stat();
}

// EXPECT: line=6 rule=store-violations-engine severity=error message=use after close
