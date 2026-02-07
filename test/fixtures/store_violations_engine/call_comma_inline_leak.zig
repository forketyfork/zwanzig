const std = @import("std");
// zwanzig-disable: unused-decl

// Regression test: .call_comma (trailing comma in multi-arg call) must be
// recognized by resolveFunctionCall for engine inlining to work.

fn leakyHelper(allocator: std.mem.Allocator, size: usize) void {
    const ptr = allocator.alloc(u8, size) catch return;
    _ = ptr;
}

fn caller(allocator: std.mem.Allocator) void {
    leakyHelper(allocator, 10,); // trailing comma produces .call_comma AST node
}

// EXPECT: line=8 rule=store-violations-engine severity=error message=resource leak
