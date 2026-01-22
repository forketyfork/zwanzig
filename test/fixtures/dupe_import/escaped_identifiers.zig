// EXPECT: line=4 rule=dupe-import severity=warning
// Escaped identifiers @"foo" and foo should be treated as the same field
const A = @import("std").@"mem";
const B = @import("std").mem;
