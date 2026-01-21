// EXPECT: line=8 rule=empty-catch
const std = @import("std");

fn tryFunc() !void {
    return error.Failed;
}

const x = tryFunc() catch {
    // intentionally ignored
};
