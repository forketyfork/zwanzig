const std = @import("std");

fn foo(allocator: std.mem.Allocator) !void {
    var ptr = try allocator.alloc(u8, 1);
    _ = ptr;
}

// EXPECT: line=4 rule=store-violations-engine severity=error message=resource leak
