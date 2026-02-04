// EXPECT: none
// Base import and inline field access are different full paths
const std = @import("std");
const mem = @import("std").mem;
const Allocator = std.mem.Allocator;
