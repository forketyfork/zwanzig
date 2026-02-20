// EXPECT: rule=slice-bounds-engine severity=error message=definitely
const std = @import("std");

fn testStringOOB() void {
    const str = "hello";
    _ = str[10];
}
