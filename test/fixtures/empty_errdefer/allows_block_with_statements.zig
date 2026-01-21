// EXPECT: none
const std = @import("std");

fn foo() !void {
    errdefer {
        std.debug.print("cleanup\n", .{});
    }
    return;
}
