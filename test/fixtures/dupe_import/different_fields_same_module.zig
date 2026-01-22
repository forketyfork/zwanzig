// EXPECT: none
// Importing different fields from the same module should NOT be flagged as duplicate
const Rule = @import("rule.zig").Rule;
const RuleError = @import("rule.zig").RuleError;
const Diagnostic = @import("rule.zig").Diagnostic;
const Severity = @import("rule.zig").Severity;
