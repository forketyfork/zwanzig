// EXPECT: line=1 rule=file-as-struct message=capitalized
const std = @import("std");

pub fn helper() void {
    std.debug.print("Hello\n", .{});
}
