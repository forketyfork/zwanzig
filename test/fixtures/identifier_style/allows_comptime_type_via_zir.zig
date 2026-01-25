// EXPECT: none
// This test validates that ZIR-based type information correctly identifies
// types created through comptime expressions.

// Type created from comptime function - ZIR knows this is a type
const Point = struct {
    x: i32,
    y: i32,

    fn init(x: i32, y: i32) @This() {
        return .{ .x = x, .y = y };
    }
};

// Type alias using @This() - common pattern
const Self = @This();
