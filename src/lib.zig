pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const rule = @import("rule.zig");

pub const Source = source.Source;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Severity = diagnostic.Severity;
pub const Rule = rule.Rule;

pub const rules = struct {
    pub const empty_catch = @import("rules/empty_catch.zig");
    pub const dupe_import = @import("rules/dupe_import.zig");
    pub const todo_comment = @import("rules/todo_comment.zig");
    pub const empty_errdefer = @import("rules/empty_errdefer.zig");
    pub const empty_defer = @import("rules/empty_defer.zig");
    pub const unreachable_code = @import("rules/unreachable_code.zig");
    pub const file_as_struct = @import("rules/file_as_struct.zig");
    pub const unused_decl = @import("rules/unused_decl.zig");
};
