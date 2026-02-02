// Tests that null check in if condition guards unwrap inside switch arm
// Pattern: switch (x) { .arm => if (y != null) { y.? } }
// EXPECT: none
const Shell = struct {
    fn write(self: *Shell, data: []const u8) !usize {
        _ = self;
        return data.len;
    }
};

const Session = struct {
    shell: ?Shell = null,
    spawned: bool = false,
    dead: bool = false,
};

const EventType = enum { key_down, key_up, other };

pub fn handle(sessions: []Session, event_type: EventType, idx: usize) void {
    switch (event_type) {
        .key_down => {},
        .key_up => {
            const focused = sessions[idx];
            if (focused.spawned and !focused.dead and focused.shell != null) {
                const data: [1]u8 = .{27};
                _ = focused.shell.?.write(&data) catch {};
            }
        },
        .other => {},
    }
}
