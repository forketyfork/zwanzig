// Tests that unwrap in else branch of payload capture is flagged
// EXPECT: line=8 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    var maybe: ?u8 = null;
    if (maybe) |value| {
        _ = value;
    } else {
        const v = maybe.?;
        _ = v;
    }
}
