const std = @import("std");

fn foo() void {
    const file = std.fs.File{ .handle = 0 };
    file.close();
}

// EXPECT: line=5 rule=store-violations-engine severity=error message=close without tracked open
