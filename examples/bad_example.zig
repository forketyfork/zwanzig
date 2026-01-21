const std = @import("std");

pub fn main() !void {
    // This is a bad example - empty catch blocks
    const file = std.fs.cwd().openFile("test.txt", .{}) catch {}; // Violation!
    _ = file;

    // Another bad example with error capture
    const data = readData() catch |err| {}; // Violation!
    _ = data;

    // This is also bad
    processFile("myfile.txt") catch {}; // Violation!
}

fn readData() ![]const u8 {
    return error.NotImplemented;
}

fn processFile(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}
