// EXPECT: line=6 rule=dupe-import severity=warning
// Different chained field paths from same module should NOT be flagged
// Same chained field path should be flagged
const Allocator = @import("std").mem.Allocator;
const ArrayList = @import("std").ArrayList;
const Allocator2 = @import("std").mem.Allocator;
