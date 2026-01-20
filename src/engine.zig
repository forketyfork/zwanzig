const std = @import("std");
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgNode = cfg_mod.CfgNode;
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;

pub const EngineError = std.mem.Allocator.Error;

/// Represents a position in the analysis - a specific point in the CFG.
/// ProgramPoint identifies a CFG node plus whether we are at the pre-state
/// (before the node executes) or post-state (after the node executes).
pub const ProgramPoint = struct {
    /// Index of the CFG node
    node_index: u32,
    /// Whether this is a pre-state (before node execution) or post-state (after)
    kind: Kind,

    pub const Kind = enum {
        /// Before the CFG node is executed
        pre,
        /// After the CFG node has been executed
        post,
    };

    pub fn init(node_index: u32, kind: Kind) ProgramPoint {
        return .{
            .node_index = node_index,
            .kind = kind,
        };
    }

    pub fn initPre(node_index: u32) ProgramPoint {
        return init(node_index, .pre);
    }

    pub fn initPost(node_index: u32) ProgramPoint {
        return init(node_index, .post);
    }

    pub fn eql(self: ProgramPoint, other: ProgramPoint) bool {
        return self.node_index == other.node_index and self.kind == other.kind;
    }

    pub fn hash(self: ProgramPoint) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.node_index));
        hasher.update(std.mem.asBytes(&self.kind));
        return hasher.final();
    }
};

/// Placeholder for abstract program state.
/// Currently stores only a unique identifier for deduplication.
/// Future steps will add environment, store, and constraints.
pub const ProgramState = struct {
    /// Unique state identifier for deduplication
    state_id: u64,

    pub fn init() ProgramState {
        return .{
            .state_id = 0,
        };
    }

    pub fn initWithId(state_id: u64) ProgramState {
        return .{
            .state_id = state_id,
        };
    }

    pub fn eql(self: ProgramState, other: ProgramState) bool {
        return self.state_id == other.state_id;
    }

    pub fn hash(self: ProgramState) u64 {
        return self.state_id;
    }

    /// Clone the state (placeholder - currently just copies state_id)
    pub fn clone(self: ProgramState) ProgramState {
        return .{
            .state_id = self.state_id,
        };
    }
};

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
        self.predecessors.deinit(allocator);
        self.successors.deinit(allocator);
    }

    /// Compute a combined hash for point and state (used for deduplication)
    pub fn computeKey(point: ProgramPoint, state: ProgramState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&point.node_index));
        hasher.update(std.mem.asBytes(&point.kind));
        hasher.update(std.mem.asBytes(&state.state_id));
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
    node_map: std.AutoHashMap(u64, u32),
    /// Reference to the CFG being analyzed
    cfg: *const Cfg,

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) ExplodedGraph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .node_map = std.AutoHashMap(u64, u32).init(allocator),
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *ExplodedGraph) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.node_map.deinit();
    }

    /// Get or create a node for the given point and state.
    /// Returns the node index and whether it was newly created.
    pub fn getOrCreateNode(self: *ExplodedGraph, point: ProgramPoint, state: ProgramState) EngineError!struct { index: u32, is_new: bool } {
        const key = ExplodedNode.computeKey(point, state);

        if (self.node_map.get(key)) |existing_index| {
            return .{ .index = existing_index, .is_new = false };
        }

        const index: u32 = @intCast(self.nodes.items.len);
        const node = ExplodedNode.init(point, state, index);

        try self.nodes.append(self.allocator, node);
        try self.node_map.put(key, index);

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
};

/// Worklist-based analysis engine.
/// Traverses the CFG and builds an exploded graph with deduplication.
pub const AnalysisEngine = struct {
    allocator: std.mem.Allocator,
    /// The exploded graph being built
    graph: ExplodedGraph,
    /// Worklist of (exploded node index, edge kind from predecessor) pairs to process
    worklist: std.ArrayList(WorklistItem),
    /// State counter for generating unique state IDs (placeholder)
    state_counter: u64,

    const WorklistItem = struct {
        /// Index of the exploded graph node to process
        node_index: u32,
        /// The kind of edge that led to this node (for path-sensitive analysis)
        edge_kind: EdgeKind,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) AnalysisEngine {
        return .{
            .allocator = allocator,
            .graph = ExplodedGraph.init(allocator, cfg),
            .worklist = .empty,
            .state_counter = 0,
        };
    }

    pub fn deinit(self: *AnalysisEngine) void {
        self.graph.deinit();
        self.worklist.deinit(self.allocator);
    }

    /// Run the analysis on the CFG, building the exploded graph.
    pub fn run(self: *AnalysisEngine) EngineError!void {
        const cfg = self.graph.cfg;

        const initial_state = self.createInitialState();
        const entry_point = ProgramPoint.initPre(cfg.entry);

        const result = try self.graph.getOrCreateNode(entry_point, initial_state);
        try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal });

        while (self.worklist.pop()) |item| {
            try self.processNode(item.node_index, item.edge_kind);
        }
    }

    fn createInitialState(self: *AnalysisEngine) ProgramState {
        const state_id = self.state_counter;
        self.state_counter += 1;
        return ProgramState.initWithId(state_id);
    }

    fn processNode(self: *AnalysisEngine, node_index: u32, edge_kind: EdgeKind) EngineError!void {
        _ = edge_kind;

        const exploded_node = self.graph.getNode(node_index) orelse return;
        const point = exploded_node.point;
        const state = exploded_node.state;

        switch (point.kind) {
            .pre => {
                const post_point = ProgramPoint.initPost(point.node_index);
                const new_state = self.transferFunction(point, state);

                const result = try self.graph.getOrCreateNode(post_point, new_state);
                try self.graph.addEdge(node_index, result.index);

                if (result.is_new) {
                    try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal });
                }
            },
            .post => {
                const cfg = self.graph.cfg;
                var successors: std.ArrayList(u32) = .empty;
                defer successors.deinit(self.allocator);
                try cfg.getSuccessors(self.allocator, point.node_index, &successors);

                for (cfg.edges.items) |edge| {
                    if (edge.from == point.node_index) {
                        const succ_point = ProgramPoint.initPre(edge.to);
                        const succ_state = state.clone();

                        const result = try self.graph.getOrCreateNode(succ_point, succ_state);
                        try self.graph.addEdge(node_index, result.index);

                        if (result.is_new) {
                            try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = edge.kind });
                        }
                    }
                }
            },
        }
    }

    /// Transfer function: compute the new state after executing a CFG node.
    /// Currently a placeholder that returns the same state.
    fn transferFunction(self: *AnalysisEngine, point: ProgramPoint, state: ProgramState) ProgramState {
        _ = self;
        _ = point;
        return state.clone();
    }

    /// Get the exploded graph after analysis
    pub fn getGraph(self: *const AnalysisEngine) *const ExplodedGraph {
        return &self.graph;
    }
};

test "ProgramPoint basic operations" {
    const testing = std.testing;

    const point1 = ProgramPoint.initPre(5);
    try testing.expectEqual(@as(u32, 5), point1.node_index);
    try testing.expectEqual(ProgramPoint.Kind.pre, point1.kind);

    const point2 = ProgramPoint.initPost(5);
    try testing.expectEqual(@as(u32, 5), point2.node_index);
    try testing.expectEqual(ProgramPoint.Kind.post, point2.kind);

    try testing.expect(!point1.eql(point2));

    const point3 = ProgramPoint.initPre(5);
    try testing.expect(point1.eql(point3));

    try testing.expect(point1.hash() != point2.hash());
    try testing.expect(point1.hash() == point3.hash());
}

test "ProgramState basic operations" {
    const testing = std.testing;

    const state1 = ProgramState.init();
    try testing.expectEqual(@as(u64, 0), state1.state_id);

    const state2 = ProgramState.initWithId(42);
    try testing.expectEqual(@as(u64, 42), state2.state_id);

    try testing.expect(!state1.eql(state2));

    const state3 = state2.clone();
    try testing.expect(state2.eql(state3));
}

test "ExplodedGraph node creation and deduplication" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(0);
    const state = ProgramState.initWithId(1);

    const result1 = try graph.getOrCreateNode(point, state);
    try testing.expect(result1.is_new);
    try testing.expectEqual(@as(u32, 0), result1.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    const result2 = try graph.getOrCreateNode(point, state);
    try testing.expect(!result2.is_new);
    try testing.expectEqual(@as(u32, 0), result2.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    const state2 = ProgramState.initWithId(2);
    const result3 = try graph.getOrCreateNode(point, state2);
    try testing.expect(result3.is_new);
    try testing.expectEqual(@as(u32, 1), result3.index);
    try testing.expectEqual(@as(usize, 2), graph.nodeCount());
}

test "ExplodedGraph edge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point1 = ProgramPoint.initPre(0);
    const point2 = ProgramPoint.initPost(0);
    const state = ProgramState.initWithId(1);

    const result1 = try graph.getOrCreateNode(point1, state);
    const result2 = try graph.getOrCreateNode(point2, state);

    try graph.addEdge(result1.index, result2.index);

    const node1 = graph.getNode(result1.index).?;
    try testing.expectEqual(@as(usize, 1), node1.successors.items.len);
    try testing.expectEqual(result2.index, node1.successors.items[0]);

    const node2 = graph.getNode(result2.index).?;
    try testing.expectEqual(@as(usize, 1), node2.predecessors.items.len);
    try testing.expectEqual(result1.index, node2.predecessors.items[0]);
}

test "AnalysisEngine simple CFG traversal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();
    try testing.expect(graph.nodeCount() >= 4);

    const node0 = graph.getNode(0).?;
    try testing.expectEqual(@as(u32, entry), node0.point.node_index);
    try testing.expectEqual(ProgramPoint.Kind.pre, node0.point.kind);
}

test "AnalysisEngine deduplication prevents infinite loops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));
    const body = try cfg.addNode(cfg_mod.IrNode.init(.loop_body));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, header);
    try cfg.addEdgeWithKind(header, body, .branch_true);
    try cfg.addEdgeWithKind(header, exit, .loop_exit);
    try cfg.addEdgeWithKind(body, header, .loop_back);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();

    try testing.expect(graph.nodeCount() > 0);
    try testing.expect(graph.nodeCount() <= 12);
}

test "AnalysisEngine branching CFG" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const branch = try cfg.addNode(cfg_mod.IrNode.init(.branch));
    const then_node = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const else_node = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const merge = try cfg.addNode(cfg_mod.IrNode.init(.nop));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, branch);
    try cfg.addEdgeWithKind(branch, then_node, .branch_true);
    try cfg.addEdgeWithKind(branch, else_node, .branch_false);
    try cfg.addEdge(then_node, merge);
    try cfg.addEdge(else_node, merge);
    try cfg.addEdge(merge, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();

    try testing.expect(graph.nodeCount() >= 12);
}
