const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Source = @import("../source.zig").Source;

pub const OptionalUnwrapRule = struct {
    pub const rule: Rule = .{
        .name = "optional-unwrap",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        for (tags, 0..) |tag, i| {
            if (tag != .unwrap_optional) continue;

            const main_token = main_tokens[i];
            if (main_token >= token_starts.len) continue;

            const unwrap_offset = token_starts[main_token];
            const loc = try src.byteToLocation(unwrap_offset);
            const diag = try Diagnostic.initAtLocation(
                allocator,
                src.getFilePath(),
                rule.name,
                .warning,
                "forced optional unwrap can panic at runtime",
                loc.line,
                loc.column,
            );
            try diagnostics.append(allocator, diag);
        }
    }
};
