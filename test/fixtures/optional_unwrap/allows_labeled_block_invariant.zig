// Tests that labeled block with null-guard break guards subsequent unwrap
// Pattern: const flag = blk: { x orelse break :blk false; ... }; if (flag) { x.? }
// EXPECT: none
const Terminal = struct {
    value: u32,
};

const Session = struct {
    terminal: ?Terminal = null,
};

pub fn handleEvent(session: Session) bool {
    const should_forward = blk: {
        // If terminal is null, break with false
        const terminal = session.terminal orelse break :blk false;
        // Use terminal to compute result
        break :blk terminal.value > 0;
    };

    if (should_forward) {
        // If should_forward is true, terminal must have been non-null
        // (otherwise the block would have broken with false)
        const terminal = session.terminal.?;
        return terminal.value > 10;
    }
    return false;
}

pub fn main() void {
    const s = Session{ .terminal = Terminal{ .value = 42 } };
    _ = handleEvent(s);
}
