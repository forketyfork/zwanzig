const std = @import("std");
// zwanzig-disable: unused-decl, swallowed-error

const Context = struct {
    gitdir: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Context) void {
        self.allocator.free(self.gitdir);
    }
};

fn findContext(allocator: std.mem.Allocator, start: []const u8) !?Context {
    var current = try allocator.dupe(u8, start);
    errdefer allocator.free(current);

    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ current, ".git" }) catch break;
        defer allocator.free(candidate);

        if (std.fs.openDirAbsolute(candidate, .{})) |dir| {
            var owned_dir = dir;
            owned_dir.close();
            const gitdir = try allocator.dupe(u8, candidate);
            allocator.free(current);
            return Context{ .gitdir = gitdir, .allocator = allocator };
        } else |_| {
            if (std.fs.openFileAbsolute(candidate, .{})) |file| {
                defer file.close();
            } else |_| {}
        }

        const parent = std.fs.path.dirname(current) orelse break;
        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }

    allocator.free(current);
    return null;
}

// NOTE: Known false positive - loop reassigns and frees current.
// EXPECT: line=14 rule=store-violations-engine severity=error message=resource leak
// EXPECT: line=34 rule=store-violations-engine severity=error message=resource leak
