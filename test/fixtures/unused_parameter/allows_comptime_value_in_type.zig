// EXPECT: none
fn buf(comptime N: usize, data: [N]u8) void {
    _ = data;
}
