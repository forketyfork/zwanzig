// EXPECT: none
const is_macos = false;

pub const InputSourceTracker = if (is_macos) struct {
    value: u8 = 0,
} else struct {
    value: u8 = 0,
};
