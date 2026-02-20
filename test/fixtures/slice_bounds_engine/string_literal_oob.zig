// This test checks detection of out-of-bounds on string literals
const std = @import("std");

fn testStringOOB() void {
    const str = "hello";
    // EXPECT: slice-bounds-engine: Array/slice index is definitely out of bounds
    _ = str[10];
}
