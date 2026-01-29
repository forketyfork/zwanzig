const std = @import("std");

const Holder = struct {
    file: std.fs.File,
};

fn openOne(dir: std.fs.Dir, name: []const u8) !Holder {
    const file = try dir.openFile(name, .{});
    return .{ .file = file };
}

// EXPECT: none
