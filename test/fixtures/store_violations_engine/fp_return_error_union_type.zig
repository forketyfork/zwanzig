const std = @import("std");
// zwanzig-disable: unused-decl

// Test that returning an error union expression sets error_active state,
// preventing false positive leak reports on error paths.

fn mayFail() !i32 {
    return error.SomeError;
}

fn helperWithAlloc(allocator: std.mem.Allocator) !void {
    const buf = try allocator.alloc(u8, 8);
    defer allocator.free(buf);
    // Return result of a function that returns error union
    // This should be recognized as an error path
    return mayFail();
}

fn helperWithReturnErr(allocator: std.mem.Allocator) !void {
    const buf = try allocator.alloc(u8, 8);
    const err: anyerror = error.SomeError;
    defer allocator.free(buf);
    // Return an error variable
    // This should also be recognized as an error path
    return err;
}

// EXPECT: none
