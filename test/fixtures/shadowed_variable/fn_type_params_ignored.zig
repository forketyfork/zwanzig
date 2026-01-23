// Test: function type parameter names should not pollute scope
// EXPECT: none
const FnType = fn (x: i32) void;

fn foo() void {
    const x = 5;
    _ = x;
}
