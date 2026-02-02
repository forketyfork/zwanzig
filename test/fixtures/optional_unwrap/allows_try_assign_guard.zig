// Tests that assignment with try expression guards subsequent unwrap
// Pattern: self.field = try expr; self.field.?
// EXPECT: none
const std = @import("std");

const State = struct {
    allocator: std.mem.Allocator,
    cwd_path: ?[]const u8 = null,
    cwd_basename: []const u8 = "",

    fn replaceCwdPath(self: *State, path: []const u8) !void {
        if (self.cwd_path) |old| {
            self.allocator.free(old);
        }
        // After try succeeds, cwd_path is non-null
        self.cwd_path = try self.allocator.dupe(u8, path);
        self.cwd_basename = basenameForDisplay(self.cwd_path.?);
    }
};

fn basenameForDisplay(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var state = State{ .allocator = gpa.allocator() };
    try state.replaceCwdPath("/home/user");
}
