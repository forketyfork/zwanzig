// EXPECT: none
// Different literal strings should not be treated as the same full path
const foo = @import("foo");
const foo2 = @import("./foo.zig");
