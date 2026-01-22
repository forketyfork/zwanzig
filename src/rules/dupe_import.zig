const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that detects duplicate @import statements in Zig code.
/// Duplicate imports can indicate copy-paste errors or redundant code.
/// This rule scans tokens to find @import("...") patterns and reports
/// when the same module is imported multiple times.
pub const DupeImportRule = struct {
    pub const rule: Rule = Rule{
        .name = "dupe-import",
        .default_severity = .warning,
        .checkFn = check,
    };

    const ImportInfo = struct {
        byte_offset: usize,
        import_path: []const u8,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const content = src.getContent();

        var seen_imports = std.StringHashMap(ImportInfo).init(allocator);
        defer seen_imports.deinit();

        var i: usize = 0;
        while (i < token_tags.len) : (i += 1) {
            if (token_tags[i] == .builtin) {
                const start = token_starts[i];
                const builtin_name = tree.tokenSlice(@intCast(i));

                if (std.mem.eql(u8, builtin_name, "@import")) {
                    const l_paren_idx = nextNonCommentToken(token_tags, i + 1) orelse continue;
                    if (token_tags[l_paren_idx] != .l_paren) continue;

                    const string_idx = nextNonCommentToken(token_tags, l_paren_idx + 1) orelse continue;
                    if (token_tags[string_idx] != .string_literal) continue;

                    const string_start = token_starts[string_idx];
                    const import_path = getStringLiteralContent(content, string_start);

                    if (seen_imports.get(import_path)) |_| {
                        const range = try src.byteRangeToSourceRange(start, start + builtin_name.len);

                        const diag = try Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "dupe-import",
                            .warning,
                            "Duplicate import detected. This module has already been imported earlier in the file.",
                            range,
                        );
                        try diagnostics.append(allocator, diag);
                    } else {
                        try seen_imports.put(import_path, .{
                            .byte_offset = start,
                            .import_path = import_path,
                        });
                    }

                    i = string_idx;
                }
            }
        }
    }

    fn nextNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
        var idx = start;
        while (idx < token_tags.len) {
            const tag = token_tags[idx];
            if (tag != .container_doc_comment and tag != .doc_comment) {
                return idx;
            }
            idx += 1;
        }
        return null;
    }

    fn getStringLiteralContent(content: []const u8, start: usize) []const u8 {
        if (start >= content.len or content[start] != '"') return "";

        const content_start = start + 1;
        var end = content_start;
        while (end < content.len and content[end] != '"') {
            if (content[end] == '\\' and end + 1 < content.len) {
                end += 2;
            } else {
                end += 1;
            }
        }

        return content[content_start..end];
    }
};
