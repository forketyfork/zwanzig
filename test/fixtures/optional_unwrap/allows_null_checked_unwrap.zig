// TODO: This should NOT produce a warning once null tracking is improved
// Currently the checker doesn't track null constraints through branches
// EXPECT: line=7 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    var maybe: ?u8 = 42;
    if (maybe != null) {
        const value = maybe.?;
        _ = value;
    }
}
