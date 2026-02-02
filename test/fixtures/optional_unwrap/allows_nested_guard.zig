// Tests that nested guards work correctly
// EXPECT: none
pub fn check(opt: ?u8, x: u8) bool {
    if (opt != null) {
        if (opt.? == x) {
            return true;
        }
    }
    return false;
}
