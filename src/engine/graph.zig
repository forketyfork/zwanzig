const std = @import("std");
const cfg_mod = @import("../cfg.zig");
const ids = @import("../ids.zig");
const Cfg = cfg_mod.Cfg;
const IrNode = cfg_mod.IrNode;
const EngineError = @import("base.zig").EngineError;
const ProgramPoint = @import("state.zig").ProgramPoint;
const ProgramState = @import("state.zig").ProgramState;

/// Default maximum number of unique states per program point.
/// Beyond this, new states at the same point are dropped (widening approximation).
const default_max_states_per_point: u32 = 10;

/// A node in the exploded graph, keyed by (ProgramPoint, ProgramState).
pub const ExplodedNode = struct {
    /// The program point (CFG location)
    point: ProgramPoint,
    /// The abstract program state at this point
    state: ProgramState,
    /// Unique index of this node in the exploded graph
    index: u32,
    /// Indices of predecessor nodes in the exploded graph
    predecessors: std.ArrayList(u32),
    /// Indices of successor nodes in the exploded graph
    successors: std.ArrayList(u32),

    pub fn init(point: ProgramPoint, state: ProgramState, index: u32) ExplodedNode {
        return .{
            .point = point,
            .state = state,
            .index = index,
            .predecessors = .empty,
            .successors = .empty,
        };
    }

    pub fn deinit(self: *ExplodedNode, allocator: std.mem.Allocator) void {
        self.state.deinit();
        self.predecessors.deinit(allocator);
        self.successors.deinit(allocator);
    }

    /// Compute a combined hash for point and state (used for deduplication)
    pub fn computeKey(point: ProgramPoint, state: *ProgramState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const node_index = ids.cfgIndex(point.node_index);
        hasher.update(std.mem.asBytes(&node_index));
        hasher.update(std.mem.asBytes(&point.kind));
        const state_hash = state.computeHash();
        hasher.update(std.mem.asBytes(&state_hash));
        return hasher.final();
    }
};

/// The exploded graph: a representation of all reachable (ProgramPoint, ProgramState) pairs.
/// This is the core data structure for path-sensitive analysis.
pub const ExplodedGraph = struct {
    allocator: std.mem.Allocator,
    /// All nodes in the exploded graph
    nodes: std.ArrayList(ExplodedNode),
    /// Map from (point, state) hash to node index for deduplication
    /// Hash collisions are possible; we accept the small risk as a pragmatic
    /// tradeoff for memory and performance.
    node_map: std.AutoHashMap(u64, u32),
    /// Reference to the CFG being analyzed
    cfg: *const Cfg,
    /// Count of states per program point (for widening)
    point_state_counts: std.AutoHashMap(u64, u32),
    /// Maximum number of unique states per program point before dropping
    max_states_per_point: u32,
    /// Count of states dropped due to per-point limit
    dropped_state_count: u32,

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) ExplodedGraph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .node_map = std.AutoHashMap(u64, u32).init(allocator),
            .cfg = cfg,
            .point_state_counts = std.AutoHashMap(u64, u32).init(allocator),
            .max_states_per_point = default_max_states_per_point,
            .dropped_state_count = 0,
        };
    }

    pub fn deinit(self: *ExplodedGraph) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.node_map.deinit();
        self.point_state_counts.deinit();
    }

    /// Get or create a node for the given point and state.
    /// Returns the node index and whether it was newly created.
    /// Note: if a node already exists, the state is not consumed and caller should deinit it.
    pub fn getOrCreateNode(self: *ExplodedGraph, point: ProgramPoint, state: *ProgramState) EngineError!struct { index: u32, is_new: bool } {
        const key = ExplodedNode.computeKey(point, state);

        if (self.node_map.get(key)) |existing_index| {
            return .{ .index = existing_index, .is_new = false };
        }

        // Check per-point state limit (widening approximation)
        const point_key = point.hash();
        const current_count = self.point_state_counts.get(point_key) orelse 0;
        if (current_count >= self.max_states_per_point) {
            // Too many states at this point - approximate by not exploring further.
            // Use maxInt as sentinel; addEdge will reject it via bounds check.
            self.dropped_state_count += 1;
            return .{ .index = std.math.maxInt(u32), .is_new = false };
        }

        const index: u32 = @intCast(self.nodes.items.len);
        const node = ExplodedNode.init(point, state.*, index);

        try self.nodes.append(self.allocator, node);
        try self.node_map.put(key, index);
        try self.point_state_counts.put(point_key, current_count + 1);

        return .{ .index = index, .is_new = true };
    }

    /// Add an edge between two exploded graph nodes
    pub fn addEdge(self: *ExplodedGraph, from_index: u32, to_index: u32) EngineError!void {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) {
            return;
        }

        try self.nodes.items[from_index].successors.append(self.allocator, to_index);
        try self.nodes.items[to_index].predecessors.append(self.allocator, from_index);
    }

    /// Get a node by index
    pub fn getNode(self: *const ExplodedGraph, index: u32) ?*const ExplodedNode {
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    /// Get node count
    pub fn nodeCount(self: *const ExplodedGraph) usize {
        return self.nodes.items.len;
    }

    pub fn getDroppedStateCount(self: *const ExplodedGraph) u32 {
        return self.dropped_state_count;
    }

    pub fn setMaxStatesPerPoint(self: *ExplodedGraph, max: u32) void {
        self.max_states_per_point = max;
    }
};

test "ExplodedGraph node creation and deduplication" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 42 });

    const result1 = try graph.getOrCreateNode(point, &state1);
    try testing.expect(result1.is_new);
    try testing.expectEqual(@as(u32, 0), result1.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    // Same point, same state should deduplicate
    var state1_clone = try state1.clone(allocator);
    const result2 = try graph.getOrCreateNode(point, &state1_clone);
    if (!result2.is_new) {
        state1_clone.deinit();
    }
    try testing.expect(!result2.is_new);
    try testing.expectEqual(@as(u32, 0), result2.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    // Same point, different state should create new node
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 100 });
    const result3 = try graph.getOrCreateNode(point, &state2);
    try testing.expect(result3.is_new);
    try testing.expectEqual(@as(u32, 1), result3.index);
    try testing.expectEqual(@as(usize, 2), graph.nodeCount());
}

test "ExplodedGraph edge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    const result1 = try graph.getOrCreateNode(point, &state1);

    var state2 = ProgramState.init(allocator);
    const result2 = try graph.getOrCreateNode(point, &state2);

    try graph.addEdge(result1.index, result2.index);

    const node1 = graph.getNode(result1.index).?;
    const node2 = graph.getNode(result2.index).?;

    try testing.expectEqual(@as(usize, 1), node1.successors.items.len);
    try testing.expectEqual(@as(usize, 1), node2.predecessors.items.len);
    try testing.expectEqual(result2.index, node1.successors.items[0]);
    try testing.expectEqual(result1.index, node2.predecessors.items[0]);
}
