// Test: redeclaration in same scope is a compile error, not a shadow warning
// This file tests that we don't report shadows for the same scope
// (Zig compiler will catch redeclarations)
// EXPECT: none
fn foo() void {
    const x = 1;
    _ = x;
}

fn bar() void {
    const x = 2;
    _ = x;
}
