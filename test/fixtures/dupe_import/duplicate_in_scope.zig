// EXPECT: line=5 rule=dupe-import severity=warning
const std = @import("std");

test "duplicate in scope" {
    const std2 = @import("std");
    _ = std2;
}
