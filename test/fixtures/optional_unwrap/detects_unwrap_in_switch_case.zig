// Tests that unwraps inside switch case bodies are detected
// EXPECT: line=8 rule=optional-unwrap message=forced optional unwrap
pub fn main() void {
    var maybe: ?u8 = null;
    const tag: u8 = 0;
    switch (tag) {
        0 => {
            const v = maybe.?;
            _ = v;
        },
        else => {},
    }
}
