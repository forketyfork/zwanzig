const std = @import("std");

pub const AssertionKind = enum {
    boolean,
    equality,
};

pub fn isTestAssertionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "expect") or
        std.mem.eql(u8, name, "expectEqual") or
        std.mem.eql(u8, name, "expectEqualStrings") or
        std.mem.eql(u8, name, "expectEqualSlices") or
        std.mem.eql(u8, name, "expectEqualDeep") or
        std.mem.eql(u8, name, "expectApproxEqAbs") or
        std.mem.eql(u8, name, "expectApproxEqRel") or
        std.mem.eql(u8, name, "expectError") or
        std.mem.eql(u8, name, "expectFmt") or
        std.mem.eql(u8, name, "assert");
}

pub fn constraintKindForName(name: []const u8) ?AssertionKind {
    if (std.mem.eql(u8, name, "expect") or std.mem.eql(u8, name, "assert")) {
        return .boolean;
    }
    if (std.mem.eql(u8, name, "expectEqual") or
        std.mem.eql(u8, name, "expectEqualStrings") or
        std.mem.eql(u8, name, "expectEqualSlices") or
        std.mem.eql(u8, name, "expectEqualDeep") or
        std.mem.eql(u8, name, "expectApproxEqAbs") or
        std.mem.eql(u8, name, "expectApproxEqRel"))
    {
        return .equality;
    }
    return null;
}

pub fn resolveAssertionName(
    tree: *const std.zig.Ast,
    fn_expr: std.zig.Ast.Node.Index,
    allow_bare: bool,
) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const fn_node = @intFromEnum(fn_expr);

    if (fn_node >= tags.len) return null;

    if (tags[fn_node] == .field_access) {
        const field_data = datas[fn_node].node_and_token;
        const field_token = field_data[1];
        const field_name = tree.tokenSlice(field_token);
        if (!isTestAssertionName(field_name)) return null;

        const base_node = @intFromEnum(field_data[0]);
        if (isTestingNamespace(tree, base_node)) {
            return field_name;
        }
        return null;
    }

    if (tags[fn_node] == .identifier and allow_bare) {
        const main_token = tree.nodes.items(.main_token)[fn_node];
        const name = tree.tokenSlice(main_token);
        if (isTestAssertionName(name)) return name;
    }

    return null;
}

fn isTestingNamespace(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return false;

    if (tags[node] == .identifier) {
        const token = tree.nodes.items(.main_token)[node];
        return std.mem.eql(u8, tree.tokenSlice(token), "testing");
    }

    if (tags[node] == .field_access) {
        const data = datas[node].node_and_token;
        const field_token = data[1];
        const field_name = tree.tokenSlice(field_token);
        if (!std.mem.eql(u8, field_name, "testing")) return false;

        const base_node = @intFromEnum(data[0]);
        if (base_node >= tags.len) return false;
        if (tags[base_node] != .identifier) return false;
        const base_token = tree.nodes.items(.main_token)[base_node];
        return std.mem.eql(u8, tree.tokenSlice(base_token), "std");
    }

    return false;
}
