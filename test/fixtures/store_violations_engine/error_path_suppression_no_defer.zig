const std = @import("std");
// zwanzig-disable: unused-decl

fn mayFail() !i32 {
    return error.SomeError;
}

fn errorReturnViaCall(allocator: std.mem.Allocator) !void {
    const buf = try allocator.alloc(u8, 8);
    _ = buf;
    return mayFail();
}

fn errorReturnViaVar(allocator: std.mem.Allocator) !void {
    const buf = try allocator.alloc(u8, 8);
    _ = buf;
    const err: anyerror = error.SomeError;
    return err;
}

// EXPECT: none
