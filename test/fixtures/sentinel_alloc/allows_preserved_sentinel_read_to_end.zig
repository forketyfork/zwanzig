// EXPECT: none
const std = @import("std");

fn foo() void {
    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
    const content: [:0]u8 = file.readToEndAllocOptions(
        std.heap.page_allocator,
        1024,
        null,
        @alignOf(u8),
        0,
    ) catch return;
    _ = content;
}
