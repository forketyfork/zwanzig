// Tests that ternary if expression guards the unwrap
// In `if (opt != null) opt.? else 0`, the `.?` is only evaluated when opt is non-null
// EXPECT: none
pub fn getValue(opt: ?u8) u8 {
    return if (opt != null) opt.? else 0;
}
