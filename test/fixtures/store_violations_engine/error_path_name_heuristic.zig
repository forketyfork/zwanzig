const std = @import("std");
// zwanzig-disable: unused-decl

const Fake = struct {
    fn open(_: *Fake) u32 {
        return 1;
    }
};

fn leakOnNormalReturn(allocator: std.mem.Allocator, fake: *Fake) u32 {
    const buf = allocator.alloc(u8, 8) catch return 0;
    _ = buf;
    return fake.open();
}

// EXPECT: line=11 rule=store-violations-engine severity=error message=resource leak
