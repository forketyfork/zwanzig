const std = @import("std");
// zwanzig-disable: unused-decl

fn build(allocator: std.mem.Allocator, ok: bool) !void {
    const buf = try allocator.alloc(u8, 8);
    if (!ok) return error.BadInput;
    allocator.free(buf);
}

// EXPECT: line=5 rule=store-violations-engine severity=error message=resource leak
