// EXPECT: line=5 rule=dupe-import severity=warning
// Importing the same field from the same module IS a duplicate
const Rule = @import("rule.zig").Rule;
const RuleError = @import("rule.zig").RuleError;
const AnotherRule = @import("rule.zig").Rule;
