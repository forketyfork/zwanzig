// EXPECT: line=4 rule=dupe-import severity=warning
const std = @import("std");
const builtin = @import("builtin");
const std2 = @import("std");
