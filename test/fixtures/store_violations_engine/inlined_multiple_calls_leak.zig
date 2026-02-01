const std = @import("std");
// zwanzig-disable: unused-decl

// Regression test for PR #41 comment concern:
// Verify that leaks in functions with conditional freeing are still detected.
//
// The concern was: if a callee allocates and leaks on one call but a later call
// frees/rebinds that local, the earlier leak might not be recorded because
// both inlined calls use the same AST-backed var IDs.
//
// Resolution: Leaks are detected because each function is analyzed independently.
// This function has a path that leaks (when should_free is false), and that
// leak is detected during analysis.

fn helper(allocator: std.mem.Allocator, should_free: bool) void {
    const ptr = allocator.alloc(u8, 10) catch return;
    if (should_free) {
        allocator.free(ptr);
    }
    // Leaks when should_free is false - this path is detected
}

// EXPECT: line=16 rule=store-violations-engine severity=error message=resource leak
