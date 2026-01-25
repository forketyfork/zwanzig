// EXPECT: none
// This test validates that ZIR-based type information correctly identifies
// type aliases that might be ambiguous with heuristic-based analysis.

// Type alias from std library - ZIR knows this is a type
const Allocator = @import("std").mem.Allocator;

// Union type - should be PascalCase
const Result = union(enum) {
    ok: i32,
    err: []const u8,
};

// Opaque type alias pattern
const Handle = *opaque {};
