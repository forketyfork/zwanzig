// TODO: This should NOT produce a warning once value tracking is improved
// Currently the checker doesn't track that optional was initialized with a value
// EXPECT: line=6 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    const maybe: ?u8 = 42;
    const value = maybe.?;
    _ = value;
}
