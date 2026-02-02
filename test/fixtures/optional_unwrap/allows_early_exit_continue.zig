// Tests that null check followed by continue guards the unwrap
// Pattern: if (x == null) continue; x.?
// EXPECT: none
pub fn main() void {
    const items: [3]?u8 = .{ 1, null, 3 };
    for (items) |item| {
        if (item == null) continue;
        const val = item.?;
        _ = val;
    }
}
