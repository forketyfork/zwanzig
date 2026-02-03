// EXPECT: line=6 rule=sentinel-alloc severity=warning message=readToEndAllocOptions with non-null sentinel allocates len+1 bytes; if stored as []u8, freeing will cause size mismatch
const std = @import("std");

fn foo() void {
    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
    const content: []u8 = file.readToEndAllocOptions(
        std.heap.page_allocator,
        1024,
        null,
        @alignOf(u8),
        0,
    ) catch return;
    _ = content;
}
