// EXPECT: none
// Non-literal import paths are not treated as duplicate full paths
const std1 = @import("s" ++ "td");
const std2 = @import("std");
