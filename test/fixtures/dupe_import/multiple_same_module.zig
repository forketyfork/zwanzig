// EXPECT: line=4 rule=dupe-import
// EXPECT: line=5 rule=dupe-import
const std1 = @import("std");
const std2 = @import("std");
const std3 = @import("std");
