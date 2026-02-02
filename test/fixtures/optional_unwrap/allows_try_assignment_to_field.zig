// Tests that assignment of try-initialized variable to field guards the unwrap
// Pattern: const x = try foo(); self.field = x; self.field.?
// EXPECT: none
const Self = struct {
    shell: ?u32 = null,
    terminal: ?u32 = null,
};

fn spawnShell() !u32 {
    return 42;
}

fn initTerminal() !u32 {
    return 43;
}

fn initStream(t: *u32, s: *u32) void {
    _ = t;
    _ = s;
}

pub fn spawn(self: *Self) !void {
    const shell = try spawnShell();
    var terminal = try initTerminal();
    _ = &terminal;

    self.shell = shell;
    self.terminal = terminal;

    initStream(&self.terminal.?, &self.shell.?);
}
