const std = @import("std");
const TypeContext = @import("../type_context.zig").TypeContext;

pub fn isCallNode(tag: std.zig.Ast.Node.Tag) bool {
    return tag == .call or tag == .call_comma or tag == .call_one or tag == .call_one_comma;
}

pub fn getReceiverTypeName(type_ctx: ?*TypeContext, tree: *const std.zig.Ast, base_node: u32) ?[]const u8 {
    if (type_ctx == null) return null;
    const tags = tree.nodes.items(.tag);
    if (base_node >= tags.len) return null;
    if (type_ctx.?.getExpressionType(base_node)) |ti| {
        return ti.type_str;
    }
    return null;
}

pub fn constructFqn(
    tree: *const std.zig.Ast,
    base_node: u32,
    method_name: []const u8,
    buffer: *[256]u8,
) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var node = base_node;

    while (true) {
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const ident_token = main_tokens[node];
                if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;
                if (count >= parts.len) return null;
                parts[count] = tree.tokenSlice(ident_token);
                count += 1;
                break;
            },
            .field_access => {
                const field_access = datas[node].node_and_token;
                const field_token = field_access[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
                if (count >= parts.len) return null;
                parts[count] = tree.tokenSlice(field_token);
                count += 1;
                node = @intFromEnum(field_access[0]);
            },
            else => return null,
        }
    }

    var pos: usize = 0;
    var idx: usize = count;
    while (idx > 0) : (idx -= 1) {
        if (!appendFqnPart(buffer, parts[idx - 1], &pos)) return null;
        if (idx > 1) {
            if (!appendFqnSeparator(buffer, &pos)) return null;
        }
    }

    if (!appendFqnSeparator(buffer, &pos)) return null;
    if (!appendFqnPart(buffer, method_name, &pos)) return null;

    return buffer[0..pos];
}

fn appendFqnPart(buffer: *[256]u8, part: []const u8, pos: *usize) bool {
    if (part.len == 0) return false;
    if (pos.* + part.len > buffer.len) return false;
    std.mem.copyForwards(u8, buffer[pos.* .. pos.* + part.len], part);
    pos.* += part.len;
    return true;
}

fn appendFqnSeparator(buffer: *[256]u8, pos: *usize) bool {
    if (pos.* >= buffer.len) return false;
    buffer[pos.*] = '.';
    pos.* += 1;
    return true;
}
