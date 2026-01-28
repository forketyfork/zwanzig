const std = @import("std");

const Foo = struct {
    allocator: std.mem.Allocator,

    fn bar(self: *Foo) !void {
        var ptr = try self.allocator.alloc(u8, 1);
        self.allocator.free(ptr);
        self.allocator.free(ptr);
    }
};

// EXPECT: line=9 rule=store-violations-engine severity=error message=double-free
