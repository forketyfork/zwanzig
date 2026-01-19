const std = @import("std");

pub fn main() !void {
    // Good example - properly handling errors
    const file = std.fs.cwd().openFile("test.txt", .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return err;
    };
    defer file.close();

    // Good example - returning the error
    const data = readData() catch |err| {
        return err;
    };
    _ = data;

    // Good example - providing fallback value
    processFile("myfile.txt") catch |err| {
        std.debug.print("Error processing file: {}\n", .{err});
        return;
    };

    // Good example - using unreachable for truly impossible errors
    const result = getValue() catch unreachable;
    _ = result;
}

fn readData() ![]const u8 {
    return error.NotImplemented;
}

fn processFile(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}

fn getValue() !u32 {
    return 42;
}
