// EXPECT: line=9 rule=return-local-ptr severity=warning
const std = @import("std");

const Ast = std.zig.Ast;

// This reproduces the exact bug pattern from sentinel_alloc.zig
fn getContainerMembers(tree: *const Ast, tags: []const Ast.Node.Tag, node_idx: u32) ?[]const Ast.Node.Index {
    var buf: [2]Ast.Node.Index = undefined;
    return switch (tags[node_idx]) {
        .container_decl_two, .container_decl_two_trailing => tree.containerDeclTwo(&buf, @enumFromInt(node_idx)).ast.members,
        else => null,
    };
}
