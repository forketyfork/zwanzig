const std = @import("std");
// zwanzig-disable: unused-decl

// Test that type-based open detection recognizes known file methods
// that return std.fs.File wrapped in error union.

fn useFileWithKnownOpen() !void {
    // openFile returns !std.fs.File - should be tracked as a resource
    const file = try std.fs.cwd().openFile("/tmp/test.txt", .{});
    // Missing file.close() - this should be detected as a leak
    _ = file;
}

// EXPECT: resource leak
