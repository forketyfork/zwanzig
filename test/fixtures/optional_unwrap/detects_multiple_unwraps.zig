// Tests that multiple unguarded unwraps are all flagged
// EXPECT: line=11 rule=optional-unwrap message=forced optional unwrap
// EXPECT: line=12 rule=optional-unwrap message=forced optional unwrap
fn getOptionalA() ?u8 {
    return 1;
}
fn getOptionalB() ?u8 {
    return 2;
}
pub fn main() void {
    const x = getOptionalA().?;
    const y = getOptionalB().?;
    _ = x;
    _ = y;
}
