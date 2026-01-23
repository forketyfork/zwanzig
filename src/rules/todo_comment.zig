const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Source = @import("../source.zig").Source;

/// Rule that detects TODO comments in Zig code.
/// TODO comments indicate unfinished work that should be tracked.
/// This rule scans source lines for `// TODO` patterns and reports
/// each occurrence with its location.
pub const TodoCommentRule = struct {
    pub const rule: Rule = Rule{
        .name = "todo",
        .default_severity = .hint,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const content = src.getContent();

        var line_number: usize = 1;
        var line_start: usize = 0;

        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '\n') {
                line_start = i + 1;
                line_number += 1;
                i += 1;
                continue;
            }

            if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
                const comment_start = i;
                i += 2;

                while (i < content.len and (content[i] == ' ' or content[i] == '\t')) {
                    i += 1;
                }

                if (i + 4 <= content.len and std.mem.eql(u8, content[i .. i + 4], "TODO") and isTodoBoundary(content, i + 4)) {
                    const todo_col = comment_start - line_start + 1;

                    var comment_end = i;
                    while (comment_end < content.len and content[comment_end] != '\n') {
                        comment_end += 1;
                    }

                    const range = try src.byteRangeToSourceRange(comment_start, comment_end);

                    const todo_text = extractTodoMessage(content[i..comment_end]);

                    const diag = try Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "todo",
                        .hint,
                        todo_text,
                        range,
                    );
                    try diagnostics.append(allocator, diag);

                    _ = todo_col;
                    i = comment_end;
                }
            } else {
                i += 1;
            }
        }
    }

    fn isTodoBoundary(content: []const u8, pos: usize) bool {
        if (pos >= content.len) return true;
        const c = content[pos];
        return c == ':' or c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn extractTodoMessage(todo_content: []const u8) []const u8 {
        if (todo_content.len < 4) return "TODO comment found";

        var start: usize = 4;

        while (start < todo_content.len and (todo_content[start] == ':' or todo_content[start] == ' ' or todo_content[start] == '\t')) {
            start += 1;
        }

        if (start >= todo_content.len) {
            return "TODO comment found";
        }

        var end = todo_content.len;
        while (end > start and (todo_content[end - 1] == ' ' or todo_content[end - 1] == '\t' or todo_content[end - 1] == '\r')) {
            end -= 1;
        }

        if (end > start) {
            return todo_content[start..end];
        }

        return "TODO comment found";
    }
};
