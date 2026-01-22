// EXPECT: line=5 rule=dupe-import severity=warning
// Inline imports with the same full path should be flagged as duplicates
const x = @import("std").mem.Allocator;
const y = @import("std").debug;
const z = @import("std").mem.Allocator;
