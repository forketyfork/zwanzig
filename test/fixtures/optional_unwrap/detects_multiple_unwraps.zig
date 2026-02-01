// Tests that multiple unguarded unwraps are all flagged
// EXPECT: line=7 rule=optional-unwrap message=forced optional unwrap
// EXPECT: line=8 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    var a: ?u8 = 1;
    var b: ?u8 = 2;
    const x = a.?;
    const y = b.?;
    _ = x;
    _ = y;
}
