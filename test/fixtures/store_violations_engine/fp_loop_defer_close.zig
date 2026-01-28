const std = @import("std");

fn process(dir: std.fs.Dir, names: []const []const u8) !void {
    for (names) |name| {
        const file = try dir.openFile(name, .{});
        defer file.close();
        _ = file;
    }
}

// EXPECT: none
