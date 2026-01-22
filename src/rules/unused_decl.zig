const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;
const Source = @import("../source.zig").Source;

/// Rule that detects unused container-level const/var declarations and functions.
///
/// This rule scans top-level declarations (const, var, fn) that are not exported
/// (not marked as `pub`) and checks if they are used elsewhere in the file.
/// Declarations that are never referenced are reported as warnings.
///
/// The rule uses a conservative approach and may have false negatives in complex
/// cases involving comptime or indirect references.
pub const UnusedDeclRule = struct {
    pub const rule: Rule = Rule{
        .name = "unused-decl",
        .default_severity = .warning,
        .checkFn = check,
    };

    const DeclInfo = struct {
        name: []const u8,
        token_index: u32,
        is_pub: bool,
        byte_offset: usize,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const root_decls = tree.rootDecls();

        var decls: std.ArrayList(DeclInfo) = .empty;
        defer decls.deinit(allocator);

        for (root_decls) |decl_idx| {
            const idx = @intFromEnum(decl_idx);
            const tag = tags[idx];

            const decl_info = switch (tag) {
                .simple_var_decl => extractVarDecl(tree, @intCast(idx), token_tags, token_starts),
                .fn_decl => extractFnDecl(tree, @intCast(idx), token_tags, token_starts),
                else => null,
            };

            if (decl_info) |info| {
                if (!info.is_pub and !isSpecialName(info.name)) {
                    try decls.append(allocator, info);
                }
            }
        }

        for (decls.items) |decl| {
            if (!isNameUsed(tree, decl.name, token_tags)) {
                const range = try src.byteRangeToSourceRange(decl.byte_offset, decl.byte_offset + decl.name.len);

                const message = try std.fmt.allocPrint(
                    allocator,
                    "Declaration '{s}' is never used",
                    .{decl.name},
                );
                defer allocator.free(message);

                const diag = try Diagnostic.init(
                    allocator,
                    src.getFilePath(),
                    "unused-decl",
                    .warning,
                    message,
                    range,
                );
                try diagnostics.append(allocator, diag);
            }
        }
    }

    fn extractVarDecl(
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) ?DeclInfo {
        const main_token = tree.nodes.items(.main_token)[node_idx];

        const is_pub = hasPubOrExportModifier(main_token, token_tags);

        const name_token = main_token + 1;
        if (name_token >= token_tags.len) return null;

        if (token_tags[name_token] != .identifier) return null;

        const name_start = token_starts[name_token];
        const name = tree.tokenSlice(name_token);

        return DeclInfo{
            .name = name,
            .token_index = name_token,
            .is_pub = is_pub,
            .byte_offset = name_start,
        };
    }

    fn extractFnDecl(
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) ?DeclInfo {
        const main_token = tree.nodes.items(.main_token)[node_idx];

        const is_pub = hasPubOrExportModifier(main_token, token_tags);

        const name_token = main_token + 1;
        if (name_token >= token_tags.len) return null;

        if (token_tags[name_token] != .identifier) return null;

        const name_start = token_starts[name_token];
        const name = tree.tokenSlice(name_token);

        return DeclInfo{
            .name = name,
            .token_index = name_token,
            .is_pub = is_pub,
            .byte_offset = name_start,
        };
    }

    fn hasPubOrExportModifier(main_token: u32, token_tags: []const std.zig.Token.Tag) bool {
        var token = main_token;
        while (token > 0) {
            token -= 1;
            const tag = token_tags[token];
            switch (tag) {
                .keyword_pub => return true,
                .keyword_export => return true,
                .keyword_extern => return true,
                .keyword_inline,
                .keyword_noinline,
                .keyword_comptime,
                .keyword_threadlocal,
                => continue,
                else => return false,
            }
        }
        return false;
    }

    fn isSpecialName(name: []const u8) bool {
        if (name.len > 0 and name[0] == '_') return true;
        if (std.mem.eql(u8, name, "main")) return true;
        if (std.mem.eql(u8, name, "panic")) return true;
        return false;
    }

    fn isNameUsed(
        tree: *const std.zig.Ast,
        name: []const u8,
        token_tags: []const std.zig.Token.Tag,
    ) bool {
        var count: usize = 0;

        for (token_tags, 0..) |tag, i| {
            if (tag == .identifier) {
                const token_name = tree.tokenSlice(@intCast(i));
                if (std.mem.eql(u8, token_name, name)) {
                    count += 1;
                    if (count > 1) return true;
                }
            }
        }

        return false;
    }
};
