const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("project-unused-decl-fixture", .{
        .root_source_file = b.path("src/lib.zig"),
    });
}
