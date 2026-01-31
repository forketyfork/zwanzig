const std = @import("std");
const graph_mod = @import("graph.zig");
const ExplodedGraph = graph_mod.ExplodedGraph;
const state_mod = @import("state.zig");
const ProgramState = state_mod.ProgramState;
const ProgramPoint = state_mod.ProgramPoint;
const cfg_mod = @import("../cfg.zig");
const Cfg = cfg_mod.Cfg;
const ids = @import("../ids.zig");

const log = std.log.scoped(.engine_dot);

// ============================================================================
// Exploded Graph Visualization
// ============================================================================

/// Generate DOT format for the full exploded graph.
/// Shows all (CFG node, state) pairs with edges between them.
pub fn generateExplodedGraph(
    graph: *const ExplodedGraph,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("digraph ExplodedGraph {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=record, fontname=\"monospace\", fontsize=9];\n");
    try writer.writeAll("  edge [fontname=\"monospace\", fontsize=8];\n");

    if (graph.cfg.fn_name) |name| {
        try writer.print("  label=\"Exploded Graph: {s}\";\n", .{name});
        try writer.writeAll("  labelloc=t;\n");
    }

    try writer.writeAll("\n");

    for (graph.nodes.items) |node| {
        const cfg_idx = ids.cfgIndex(node.point.node_index);
        const cfg_node = graph.cfg.getNode(node.point.node_index);
        const ir_tag = if (cfg_node) |n| @tagName(n.ir_node.tag) else "?";

        var state_copy = node.state;
        const state_hash: u32 = @truncate(state_copy.computeHash());
        const env_count = node.state.env.size();
        const constraint_count = node.state.constraints.size();
        const violations = node.state.store.getViolations();

        var fillcolor: []const u8 = "white";
        if (violations.len > 0) {
            fillcolor = "lightyellow";
        }
        if (cfg_node) |n| {
            if (n.ir_node.tag == .fn_entry and node.point.kind == .pre) {
                fillcolor = "lightgreen";
            } else if (n.ir_node.tag == .fn_exit and node.point.kind == .post) {
                fillcolor = "lightcoral";
            }
        }

        try writer.print(
            "  e{d} [label=\"{{cfg:{d} ({s}) {s}|h:{x:0>8}|env:{d} cstr:{d}}}\", style=filled, fillcolor={s}];\n",
            .{ node.index, cfg_idx, ir_tag, @tagName(node.point.kind), state_hash, env_count, constraint_count, fillcolor },
        );
    }

    try writer.writeAll("\n");

    for (graph.nodes.items) |node| {
        for (node.successors.items) |succ_idx| {
            try writer.print("  e{d} -> e{d};\n", .{ node.index, succ_idx });
        }
    }

    try writer.writeAll("}\n");
    return buffer.toOwnedSlice(allocator);
}

/// Write exploded graph to a DOT file.
pub fn writeExplodedGraphToFile(
    graph: *const ExplodedGraph,
    dir: []const u8,
    source_path: []const u8,
    fn_name: ?[]const u8,
    allocator: std.mem.Allocator,
) void {
    const dot = generateExplodedGraph(graph, allocator) catch |err| {
        log.warn("failed to generate exploded graph DOT: {}", .{err});
        return;
    };
    defer allocator.free(dot);

    writeToFile(dot, dir, source_path, fn_name, "exploded", allocator);
}

// ============================================================================
// Annotated CFG Visualization
// ============================================================================

/// Generate DOT format for CFG with state annotations.
/// Shows the original CFG structure with state summary at each node.
pub fn generateAnnotatedCfg(
    graph: *const ExplodedGraph,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    const cfg = graph.cfg;

    var states_per_node = std.AutoHashMap(u32, StateInfo).init(allocator);
    defer states_per_node.deinit();

    for (graph.nodes.items) |node| {
        const cfg_idx = ids.cfgIndex(node.point.node_index);
        const violations = node.state.store.getViolations();

        const entry = try states_per_node.getOrPut(cfg_idx);
        if (!entry.found_existing) {
            entry.value_ptr.* = StateInfo{ .count = 0, .has_violation = false };
        }
        entry.value_ptr.count += 1;
        if (violations.len > 0) {
            entry.value_ptr.has_violation = true;
        }
    }

    try writer.writeAll("digraph AnnotatedCFG {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=record, fontname=\"monospace\", fontsize=9];\n");
    try writer.writeAll("  edge [fontname=\"monospace\", fontsize=8];\n");

    if (cfg.fn_name) |name| {
        try writer.print("  label=\"Annotated CFG: {s}\";\n", .{name});
        try writer.writeAll("  labelloc=t;\n");
    }

    try writer.writeAll("\n");

    for (cfg.nodes.items) |cfg_node| {
        const idx = ids.cfgIndex(cfg_node.index);
        const tag_name = @tagName(cfg_node.ir_node.tag);

        var state_count: usize = 0;
        var has_violation = false;
        if (states_per_node.get(idx)) |info| {
            state_count = info.count;
            has_violation = info.has_violation;
        }

        var fillcolor: []const u8 = "white";
        if (has_violation) {
            fillcolor = "lightyellow";
        } else if (cfg_node.ir_node.tag == .fn_entry) {
            fillcolor = "lightgreen";
        } else if (cfg_node.ir_node.tag == .fn_exit) {
            fillcolor = "lightcoral";
        }

        var shape: []const u8 = "record";
        if (cfg_node.ir_node.tag == .branch or cfg_node.ir_node.tag == .loop_header) {
            shape = "diamond";
        }

        try writer.print(
            "  n{d} [label=\"{{{d}: {s}|states: {d}}}\", shape={s}, style=filled, fillcolor={s}];\n",
            .{ idx, idx, tag_name, state_count, shape, fillcolor },
        );
    }

    try writer.writeAll("\n");

    for (cfg.edges.items) |edge| {
        const from_idx = ids.cfgIndex(edge.from);
        const to_idx = ids.cfgIndex(edge.to);

        if (edge.kind == .normal) {
            try writer.print("  n{d} -> n{d};\n", .{ from_idx, to_idx });
        } else {
            const style = switch (edge.kind) {
                .branch_true => "color=green",
                .branch_false => "color=red",
                .loop_back => "color=blue, style=dashed",
                .loop_exit => "color=orange",
                .try_error, .catch_error, .errdefer_edge => "color=red, style=dotted",
                .try_success, .catch_success => "color=green, style=dotted",
                .defer_edge => "color=purple, style=dashed",
                .jump => "style=bold",
                .normal => "",
            };
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

/// Write annotated CFG to a DOT file.
pub fn writeAnnotatedCfgToFile(
    graph: *const ExplodedGraph,
    dir: []const u8,
    source_path: []const u8,
    fn_name: ?[]const u8,
    allocator: std.mem.Allocator,
) void {
    const dot = generateAnnotatedCfg(graph, allocator) catch |err| {
        log.warn("failed to generate annotated CFG DOT: {}", .{err});
        return;
    };
    defer allocator.free(dot);

    writeToFile(dot, dir, source_path, fn_name, "annotated", allocator);
}

// ============================================================================
// Path Trace Visualization
// ============================================================================

/// Generate DOT format for path traces leading to violations.
/// Shows linear paths from entry to each violation with state info.
pub fn generatePathTraces(
    graph: *const ExplodedGraph,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    var violation_nodes: std.ArrayList(u32) = .empty;
    defer violation_nodes.deinit(allocator);

    for (graph.nodes.items) |node| {
        if (node.state.store.getViolations().len > 0) {
            try violation_nodes.append(allocator, node.index);
        }
    }

    try writer.writeAll("digraph PathTraces {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=record, fontname=\"monospace\", fontsize=9];\n");
    try writer.writeAll("  edge [fontname=\"monospace\", fontsize=8];\n");

    if (graph.cfg.fn_name) |name| {
        try writer.print("  label=\"Path Traces: {s}\";\n", .{name});
        try writer.writeAll("  labelloc=t;\n");
    }

    try writer.writeAll("\n");

    if (violation_nodes.items.len == 0) {
        try writer.writeAll("  no_violations [label=\"No violations found\", style=filled, fillcolor=lightgreen];\n");
    } else {
        for (violation_nodes.items, 0..) |target, path_idx| {
            const path = try reconstructPath(graph, target, allocator);
            defer allocator.free(path);

            try writer.print("  subgraph cluster_path{d} {{\n", .{path_idx});

            const violations = graph.nodes.items[target].state.store.getViolations();
            if (violations.len > 0) {
                try writer.print("    label=\"Path {d}: {s}\";\n", .{ path_idx, @tagName(violations[0].kind) });
            } else {
                try writer.print("    label=\"Path {d}\";\n", .{path_idx});
            }
            try writer.writeAll("    style=rounded;\n");

            for (path, 0..) |node_idx, step| {
                const node = &graph.nodes.items[node_idx];
                const cfg_idx = ids.cfgIndex(node.point.node_index);
                const cfg_node = graph.cfg.getNode(node.point.node_index);
                const ir_tag = if (cfg_node) |n| @tagName(n.ir_node.tag) else "?";

                const node_violations = node.state.store.getViolations();
                var fillcolor: []const u8 = "white";
                if (node_violations.len > 0) {
                    fillcolor = "lightcoral";
                } else if (step == 0) {
                    fillcolor = "lightgreen";
                }

                const env_count = node.state.env.size();
                const err_state = @tagName(node.state.error_state);

                try writer.print(
                    "    p{d}_{d} [label=\"{{step {d}|cfg:{d} {s} {s}|env:{d} err:{s}}}\", style=filled, fillcolor={s}];\n",
                    .{ path_idx, node_idx, step, cfg_idx, ir_tag, @tagName(node.point.kind), env_count, err_state, fillcolor },
                );
            }

            if (path.len > 1) {
                for (0..path.len - 1) |i| {
                    try writer.print("    p{d}_{d} -> p{d}_{d};\n", .{ path_idx, path[i], path_idx, path[i + 1] });
                }
            }

            try writer.writeAll("  }\n\n");
        }
    }

    try writer.writeAll("}\n");
    return buffer.toOwnedSlice(allocator);
}

/// Write path traces to a DOT file.
pub fn writePathTracesToFile(
    graph: *const ExplodedGraph,
    dir: []const u8,
    source_path: []const u8,
    fn_name: ?[]const u8,
    allocator: std.mem.Allocator,
) void {
    const dot = generatePathTraces(graph, allocator) catch |err| {
        log.warn("failed to generate path traces DOT: {}", .{err});
        return;
    };
    defer allocator.free(dot);

    writeToFile(dot, dir, source_path, fn_name, "traces", allocator);
}

// ============================================================================
// Helpers
// ============================================================================

const StateInfo = struct {
    count: usize,
    has_violation: bool,
};

/// Reconstruct path from entry to a given node by following predecessors.
fn reconstructPath(
    graph: *const ExplodedGraph,
    target_index: u32,
    allocator: std.mem.Allocator,
) ![]u32 {
    var path: std.ArrayList(u32) = .empty;
    errdefer path.deinit(allocator);

    var current = target_index;
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    while (true) {
        if (visited.contains(current)) break;
        try visited.put(current, {});
        try path.insert(allocator, 0, current);

        const node = &graph.nodes.items[current];
        if (node.predecessors.items.len == 0) break;
        current = node.predecessors.items[0];
    }

    return path.toOwnedSlice(allocator);
}

/// Write DOT content to a file in the specified directory.
fn writeToFile(
    dot: []const u8,
    dir: []const u8,
    source_path: []const u8,
    fn_name: ?[]const u8,
    suffix: []const u8,
    allocator: std.mem.Allocator,
) void {
    _ = allocator;

    const basename = std.fs.path.basename(source_path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |idx| basename[0..idx] else basename;
    const name = fn_name orelse "anonymous";

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}_{s}_{s}.dot", .{ dir, stem, name, suffix }) catch {
        log.warn("DOT path too long", .{});
        return;
    };

    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("failed to create DOT dump directory {s}: {}", .{ dir, err });
        return;
    };

    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        log.warn("failed to create DOT file {s}: {}", .{ file_path, err });
        return;
    };
    defer file.close();

    file.writeAll(dot) catch |err| {
        log.warn("failed to write DOT file {s}: {}", .{ file_path, err });
        return;
    };

    log.debug("dumped DOT to {s}", .{file_path});
}

// ============================================================================
// Tests
// ============================================================================

test "generateExplodedGraph basic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const IrNode = cfg_mod.IrNode;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();
    cfg.fn_name = "testFn";

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, exit);

    var eg = ExplodedGraph.init(allocator, &cfg);
    defer eg.deinit();

    var state1 = ProgramState.init(allocator);
    const point1 = ProgramPoint.initPre(cfg.entry, &cfg);
    _ = try eg.getOrCreateNode(point1, &state1);

    const dot = try generateExplodedGraph(&eg, allocator);
    defer allocator.free(dot);

    try testing.expect(std.mem.indexOf(u8, dot, "digraph ExplodedGraph") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "e0") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "testFn") != null);
}

test "generateAnnotatedCfg basic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const IrNode = cfg_mod.IrNode;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();
    cfg.fn_name = "testFn";

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, exit);

    var eg = ExplodedGraph.init(allocator, &cfg);
    defer eg.deinit();

    var state1 = ProgramState.init(allocator);
    const point1 = ProgramPoint.initPre(cfg.entry, &cfg);
    _ = try eg.getOrCreateNode(point1, &state1);

    const dot = try generateAnnotatedCfg(&eg, allocator);
    defer allocator.free(dot);

    try testing.expect(std.mem.indexOf(u8, dot, "digraph AnnotatedCFG") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "n0") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "states:") != null);
}

test "generatePathTraces no violations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const IrNode = cfg_mod.IrNode;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();
    cfg.fn_name = "testFn";

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    cfg.entry = entry;

    var eg = ExplodedGraph.init(allocator, &cfg);
    defer eg.deinit();

    var state1 = ProgramState.init(allocator);
    const point1 = ProgramPoint.initPre(cfg.entry, &cfg);
    _ = try eg.getOrCreateNode(point1, &state1);

    const dot = try generatePathTraces(&eg, allocator);
    defer allocator.free(dot);

    try testing.expect(std.mem.indexOf(u8, dot, "digraph PathTraces") != null);
    try testing.expect(std.mem.indexOf(u8, dot, "No violations found") != null);
}

test "reconstructPath finds entry" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const IrNode = cfg_mod.IrNode;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    const middle = try cfg.addNode(IrNode.init(.call));
    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, middle);
    try cfg.addEdge(middle, exit);

    var eg = ExplodedGraph.init(allocator, &cfg);
    defer eg.deinit();

    var state1 = ProgramState.init(allocator);
    const point1 = ProgramPoint.initPre(entry, &cfg);
    const r1 = try eg.getOrCreateNode(point1, &state1);

    var state2 = ProgramState.init(allocator);
    const point2 = ProgramPoint.initPre(middle, &cfg);
    const r2 = try eg.getOrCreateNode(point2, &state2);

    var state3 = ProgramState.init(allocator);
    const point3 = ProgramPoint.initPre(exit, &cfg);
    const r3 = try eg.getOrCreateNode(point3, &state3);

    try eg.addEdge(r1.index, r2.index);
    try eg.addEdge(r2.index, r3.index);

    const path = try reconstructPath(&eg, r3.index, allocator);
    defer allocator.free(path);

    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqual(r1.index, path[0]);
    try testing.expectEqual(r2.index, path[1]);
    try testing.expectEqual(r3.index, path[2]);
}
