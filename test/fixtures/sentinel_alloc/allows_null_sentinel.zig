const std = @import("std");

fn foo() void {
    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
    const content = file.readToEndAllocOptions(
        std.heap.page_allocator,
        1024,
        null,
        @alignOf(u8),
        null,
    ) catch return;
    _ = content;
}
