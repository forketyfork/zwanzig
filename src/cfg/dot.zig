const std = @import("std");
const graph = @import("graph.zig");
const Cfg = graph.Cfg;
const ids = @import("../ids.zig");
const dot_helpers = @import("../dot_helpers.zig");

const log = std.log.scoped(.cfg_dot);

/// Generate DOT format representation of a CFG for visualization.
/// The output can be rendered with Graphviz: `dot -Tpng file.dot -o file.png`
/// or viewed at online tools like edotor.net or viz-js.com
pub fn generate(cfg: *const Cfg, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);

    // Header
    try writer.writeAll("digraph CFG {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=box, fontname=\"monospace\", fontsize=10];\n");
    try writer.writeAll("  edge [fontname=\"monospace\", fontsize=9];\n");

    // Function name as graph label
    if (cfg.fn_name) |name| {
        try writer.print("  label=\"CFG: {s}\";\n", .{name});
        try writer.writeAll("  labelloc=t;\n");
    }

    try writer.writeAll("\n");

    // Nodes
    for (cfg.nodes.items) |node| {
        const idx = ids.cfgIndex(node.index);
        const tag_name = @tagName(node.ir_node.tag);

        // Special styling for entry/exit nodes
        if (node.ir_node.tag == .fn_entry) {
            try writer.print("  n{d} [label=\"{d}: {s}\", style=filled, fillcolor=lightgreen];\n", .{ idx, idx, tag_name });
        } else if (node.ir_node.tag == .fn_exit) {
            try writer.print("  n{d} [label=\"{d}: {s}\", style=filled, fillcolor=lightcoral];\n", .{ idx, idx, tag_name });
        } else if (node.ir_node.tag == .branch or node.ir_node.tag == .loop_header) {
            try writer.print("  n{d} [label=\"{d}: {s}\", shape=diamond];\n", .{ idx, idx, tag_name });
        } else {
            try writer.print("  n{d} [label=\"{d}: {s}\"];\n", .{ idx, idx, tag_name });
        }
    }

    try writer.writeAll("\n");

    // Edges with labels for non-normal edges
    for (cfg.edges.items) |edge| {
        const from_idx = ids.cfgIndex(edge.from);
        const to_idx = ids.cfgIndex(edge.to);

        if (edge.kind == .normal) {
            try writer.print("  n{d} -> n{d};\n", .{ from_idx, to_idx });
        } else {
            const style = dot_helpers.edgeStyle(edge.kind);
            try writer.print("  n{d} -> n{d} [label=\"{s}\", {s}];\n", .{
                from_idx,
                to_idx,
                @tagName(edge.kind),
                style,
            });
        }
    }

    try writer.writeAll("}\n");

    return buffer.toOwnedSlice(allocator);
}

/// Write a CFG to a DOT file.
/// The filename is based on the source file, function name, and AST node index for uniqueness.
pub fn writeToFile(
    cfg: *const Cfg,
    dir: []const u8,
    source_path: []const u8,
    allocator: std.mem.Allocator,
) void {
    const dot = generate(cfg, allocator) catch |err| {
        log.warn("failed to generate CFG DOT: {}", .{err});
        return;
    };
    defer allocator.free(dot);

    // Build filename: <source_basename>_<fn_name>_<ast_idx>.dot
    // The AST index suffix guarantees uniqueness for functions with the same name
    const stem = dot_helpers.stemFromPath(source_path);
    const fn_name = cfg.fn_name orelse "anonymous";
    const ast_idx = if (cfg.fn_ast_node) |node| ids.astIndex(node) else 0;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}_{s}_{d}.dot", .{ dir, stem, fn_name, ast_idx }) catch {
        log.warn("CFG DOT path too long", .{});
        return;
    };

    dot_helpers.writeDotFile(dir, file_path, dot) catch |err| {
        log.warn("failed to write CFG DOT file {s}: {}", .{ file_path, err });
        return;
    };

    log.debug("dumped CFG to {s}", .{file_path});
}

/// Print DOT format to stderr for quick debugging.
pub fn dumpToStderr(cfg: *const Cfg, allocator: std.mem.Allocator) void {
    const dot = generate(cfg, allocator) catch |err| {
        std.debug.print("Failed to generate DOT: {}\n", .{err});
        return;
    };
    defer allocator.free(dot);
    std.debug.print("{s}", .{dot});
}

// ============================================================================
// Tests
// ============================================================================

test "generate DOT output" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const IrNode = graph.IrNode;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();
    cfg.fn_name = "testFn";

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    const branch = try cfg.addNode(IrNode.init(.branch));
    const body = try cfg.addNode(IrNode.init(.var_decl));
    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, branch);
    try cfg.addEdgeWithKind(branch, body, .branch_true);
    try cfg.addEdgeWithKind(branch, exit, .branch_false);
    try cfg.addEdge(body, exit);

    const dot = try generate(&cfg, allocator);
    defer allocator.free(dot);

    // Verify DOT structure
    try testing.expect(std.mem.indexOf(u8, dot, "digraph CFG") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "label=\"CFG: testFn\"") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "fn_entry") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "fn_exit") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "branch_true") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "branch_false") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "lightgreen") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "lightcoral") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "shape=diamond") != null);
}
