// Tests that unwrap in else branch of null check is flagged
// The else branch means the value IS null, so unwrapping is unsafe
// EXPECT: line=9 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    var maybe: ?u8 = null;
    if (maybe != null) {
        // safe here
    } else {
        const value = maybe.?;
        _ = value;
    }
}
