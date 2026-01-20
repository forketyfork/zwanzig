const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const cfg_mod = @import("../cfg.zig");
const CfgBuilder = cfg_mod.CfgBuilder;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;

pub const UnreachableCodeRule = struct {
    pub const rule: Rule = .{
        .name = "unreachable-code",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();

        var builder = CfgBuilder.init(allocator);

        const tags = tree.nodes.items(.tag);
        for (tags, 0..) |tag, i| {
            if (tag == .fn_decl) {
                const fn_node: u32 = @intCast(i);
                var cfg_opt = builder.buildFromFn(src, fn_node) catch continue;
                if (cfg_opt) |*cfg| {
                    defer cfg.deinit();

                    var engine = AnalysisEngine.init(allocator, cfg);
                    defer engine.deinit();

                    try engine.run();

                    const graph = engine.getGraph();

                    for (cfg.nodes.items, 0..) |cfg_node, node_idx| {
                        const cfg_node_idx: u32 = @intCast(node_idx);

                        if (cfg_node_idx == cfg.entry or cfg_node_idx == cfg.exit) {
                            continue;
                        }

                        if (cfg_node.ir_node.tag == .nop) {
                            continue;
                        }

                        var has_incoming_feasible_edge = false;
                        for (graph.nodes.items) |exploded_node| {
                            if (exploded_node.point.node_index == cfg_node_idx) {
                                has_incoming_feasible_edge = true;
                                break;
                            }
                        }

                        if (!has_incoming_feasible_edge) {
                            if (cfg_node.ir_node.ast_node) |ast_node| {
                                const tree_local = try src.ast();
                                const main_tokens = tree_local.nodes.items(.main_token);
                                const token_starts = tree_local.tokens.items(.start);
                                const main_token = main_tokens[ast_node];
                                const byte_offset = token_starts[main_token];
                                const loc = try src.byteToLocation(byte_offset);
                                try diagnostics.append(allocator, Diagnostic.initAtLocation(
                                    src.getFilePath(),
                                    rule.name,
                                    .warning,
                                    "unreachable code detected",
                                    loc.line,
                                    loc.column,
                                ));
                            }
                        }
                    }
                }
            }
        }
    }
};

test "unreachable_code - basic unreachable after return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    return;
        \\    const x = 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}

test "unreachable_code - reachable code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    const x = 42;
        \\    return;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "unreachable_code - unreachable in if-else both terminate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) void {
        \\    if (x > 0) {
        \\        return;
        \\    } else {
        \\        return;
        \\    }
        \\    const y = 10;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var violations: std.ArrayList(Diagnostic) = .empty;
    defer violations.deinit(allocator);

    try UnreachableCodeRule.rule.check(&source, allocator, &violations);

    try testing.expect(violations.items.len > 0);
}
