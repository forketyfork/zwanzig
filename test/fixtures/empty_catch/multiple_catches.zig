// EXPECT: line=12 rule=empty-catch
// EXPECT: line=16 rule=empty-catch
const std = @import("std");

fn tryFunc() !void {
    return error.Failed;
}
fn anotherFunc() !void {
    return error.Other;
}

const x = tryFunc() catch {};
const y = anotherFunc() catch {
    @panic("error");
};
const z = tryFunc() catch {};
