// EXPECT: none
const std = @import("std");

fn tryFunc() !void {
    return error.Failed;
}

const x = tryFunc() catch {
    std.debug.print("Error occurred\n", .{});
};
