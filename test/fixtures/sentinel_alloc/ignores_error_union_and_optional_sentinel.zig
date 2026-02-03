const std = @import("std");

const Err = error{Oops};

const Holder = struct {
    path: ?[:0]const u8,
};

fn makePath(allocator: std.mem.Allocator) Err![:0]const u8 {
    const s = try allocator.dupeZ(u8, "hello");
    return s;
}

fn makeHolder(allocator: std.mem.Allocator) !Holder {
    var holder: Holder = .{ .path = null };
    holder.path = try allocator.dupeZ(u8, "world");
    return holder;
}
