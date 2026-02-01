// Tests that unwrap without any null check is flagged
// EXPECT: line=7 rule=optional-unwrap message=forced optional unwrap
pub fn getOptional() ?u8 {
    return 42;
}
pub fn main() void {
    const value = getOptional().?;
    _ = value;
}
