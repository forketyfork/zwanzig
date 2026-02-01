// Tests that unwraps inside test assertions are allowed
// Test assertions like expectEqual intentionally panic on failure
// EXPECT: none
const std = @import("std");

fn getOptional() ?u8 {
    return 42;
}

test "unwrap in assertion is allowed" {
    const maybe = getOptional();
    try std.testing.expectEqual(@as(u8, 42), maybe.?);
}
