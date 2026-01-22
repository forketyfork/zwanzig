// EXPECT: line=8 col=21 rule=empty-catch severity=warning
const std = @import("std");

fn tryFunc() !void {
    return error.Failed;
}

const x = tryFunc() catch {};
