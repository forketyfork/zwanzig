const std = @import("std");
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgNode = cfg_mod.CfgNode;
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;
const IrTag = cfg_mod.IrTag;

pub const EngineError = std.mem.Allocator.Error;

/// Abstract value representing the possible values of a variable or expression.
/// These values are used for symbolic execution and dataflow analysis.
pub const AbstractValue = union(enum) {
    /// Value is unknown - no information available
    unknown,
    /// Value is definitely null/undefined
    null_val,
    /// Value is definitely not null (but actual value is unknown)
    non_null,
    /// Value is an integer within a known range
    int_range: IntRange,
    /// Value is a known concrete integer
    concrete_int: i64,

    pub const IntRange = struct {
        min: i64,
        max: i64,

        pub fn init(min: i64, max: i64) IntRange {
            return .{ .min = min, .max = max };
        }

        pub fn single(value: i64) IntRange {
            return .{ .min = value, .max = value };
        }

        pub fn eql(self: IntRange, other: IntRange) bool {
            return self.min == other.min and self.max == other.max;
        }

        pub fn contains(self: IntRange, value: i64) bool {
            return value >= self.min and value <= self.max;
        }

        pub fn overlaps(self: IntRange, other: IntRange) bool {
            return self.min <= other.max and other.min <= self.max;
        }

        pub fn merge(self: IntRange, other: IntRange) IntRange {
            return .{
                .min = @min(self.min, other.min),
                .max = @max(self.max, other.max),
            };
        }
    };

    pub fn eql(self: AbstractValue, other: AbstractValue) bool {
        return switch (self) {
            .unknown => other == .unknown,
            .null_val => other == .null_val,
            .non_null => other == .non_null,
            .int_range => |r1| switch (other) {
                .int_range => |r2| r1.eql(r2),
                else => false,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| v1 == v2,
                else => false,
            },
        };
    }

    pub fn hash(self: AbstractValue) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag_byte: u8 = switch (self) {
            .unknown => 0,
            .null_val => 1,
            .non_null => 2,
            .int_range => 3,
            .concrete_int => 4,
        };
        hasher.update(&[_]u8{tag_byte});
        switch (self) {
            .int_range => |r| {
                hasher.update(std.mem.asBytes(&r.min));
                hasher.update(std.mem.asBytes(&r.max));
            },
            .concrete_int => |v| {
                hasher.update(std.mem.asBytes(&v));
            },
            else => {},
        }
        return hasher.final();
    }

    pub fn isUnknown(self: AbstractValue) bool {
        return self == .unknown;
    }

    pub fn isNull(self: AbstractValue) bool {
        return self == .null_val;
    }

    pub fn isNonNull(self: AbstractValue) bool {
        return self == .non_null;
    }

    pub fn isConcrete(self: AbstractValue) bool {
        return self == .concrete_int;
    }

    pub fn toConcreteInt(self: AbstractValue) ?i64 {
        return switch (self) {
            .concrete_int => |v| v,
            .int_range => |r| if (r.min == r.max) r.min else null,
            else => null,
        };
    }

    pub fn merge(self: AbstractValue, other: AbstractValue) AbstractValue {
        if (self.eql(other)) return self;

        return switch (self) {
            .unknown => .unknown,
            .null_val => switch (other) {
                .unknown => .unknown,
                else => .unknown,
            },
            .non_null => switch (other) {
                .unknown => .unknown,
                .non_null => .non_null,
                else => .unknown,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| .{ .int_range = IntRange.init(@min(v1, v2), @max(v1, v2)) },
                .int_range => |r| .{ .int_range = r.merge(IntRange.single(v1)) },
                else => .unknown,
            },
            .int_range => |r1| switch (other) {
                .int_range => |r2| .{ .int_range = r1.merge(r2) },
                .concrete_int => |v| .{ .int_range = r1.merge(IntRange.single(v)) },
                else => .unknown,
            },
        };
    }
};

/// A variable identifier used as a key in the environment.
/// Currently uses AST node index to identify variables.
pub const VarId = struct {
    /// AST node index of the variable declaration
    ast_node: u32,

    pub fn init(ast_node: u32) VarId {
        return .{ .ast_node = ast_node };
    }

    pub fn eql(self: VarId, other: VarId) bool {
        return self.ast_node == other.ast_node;
    }

    pub fn hash(self: VarId) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.ast_node));
        return hasher.final();
    }
};

/// Environment: mapping from variables to abstract values.
/// Represents the known values of variables at a program point.
pub const Environment = struct {
    /// Map from variable ID to abstract value
    bindings: std.AutoHashMap(u32, AbstractValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .bindings = std.AutoHashMap(u32, AbstractValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
    }

    pub fn clone(self: *const Environment) !Environment {
        var new_env = Environment.init(self.allocator);
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            try new_env.bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_env;
    }

    pub fn get(self: *const Environment, var_id: u32) ?AbstractValue {
        return self.bindings.get(var_id);
    }

    pub fn set(self: *Environment, var_id: u32, value: AbstractValue) !void {
        try self.bindings.put(var_id, value);
    }

    pub fn remove(self: *Environment, var_id: u32) void {
        _ = self.bindings.remove(var_id);
    }

    pub fn size(self: *const Environment) usize {
        return self.bindings.count();
    }

    pub fn eql(self: *const Environment, other: *const Environment) bool {
        if (self.bindings.count() != other.bindings.count()) return false;

        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            if (other.bindings.get(entry.key_ptr.*)) |other_val| {
                if (!entry.value_ptr.*.eql(other_val)) return false;
            } else {
                return false;
            }
        }
        return true;
    }

    pub fn computeHash(self: *const Environment) u64 {
        // Use XOR-based hashing which is order-independent and requires no allocation
        var combined_hash: u64 = 0;

        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(entry.key_ptr));
            const val_hash = entry.value_ptr.*.hash();
            hasher.update(std.mem.asBytes(&val_hash));
            combined_hash ^= hasher.final();
        }

        return combined_hash;
    }
};

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

/// Abstract program state for path-sensitive analysis.
/// Stores the environment mapping variables to abstract values.
/// States are compared structurally for deduplication.
pub const ProgramState = struct {
    /// Environment mapping variables to abstract values
    env: Environment,
    /// Cached hash for efficient deduplication
    cached_hash: ?u64,

    pub fn init(allocator: std.mem.Allocator) ProgramState {
        return .{
            .env = Environment.init(allocator),
            .cached_hash = null,
        };
    }

    pub fn deinit(self: *ProgramState) void {
        self.env.deinit();
    }

    pub fn eql(self: *const ProgramState, other: *const ProgramState) bool {
        return self.env.eql(&other.env);
    }

    pub fn computeHash(self: *ProgramState) u64 {
        if (self.cached_hash) |h| return h;
        const h = self.env.computeHash();
        self.cached_hash = h;
        return h;
    }

    pub fn clone(self: *const ProgramState, allocator: std.mem.Allocator) !ProgramState {
        _ = allocator;
        return .{
            .env = try self.env.clone(),
            .cached_hash = self.cached_hash,
        };
    }

    pub fn invalidateCache(self: *ProgramState) void {
        self.cached_hash = null;
    }

    pub fn getVar(self: *const ProgramState, var_id: u32) ?AbstractValue {
        return self.env.get(var_id);
    }

    pub fn setVar(self: *ProgramState, var_id: u32, value: AbstractValue) !void {
        try self.env.set(var_id, value);
        self.invalidateCache();
    }

    pub fn envSize(self: *const ProgramState) usize {
        return self.env.size();
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
        self.state.deinit();
        self.predecessors.deinit(allocator);
        self.successors.deinit(allocator);
    }

    /// Compute a combined hash for point and state (used for deduplication)
    pub fn computeKey(point: ProgramPoint, state: *ProgramState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&point.node_index));
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
    /// Note: if a node already exists, the state is not consumed and caller should deinit it.
    pub fn getOrCreateNode(self: *ExplodedGraph, point: ProgramPoint, state: *ProgramState) EngineError!struct { index: u32, is_new: bool } {
        const key = ExplodedNode.computeKey(point, state);

        if (self.node_map.get(key)) |existing_index| {
            return .{ .index = existing_index, .is_new = false };
        }

        const index: u32 = @intCast(self.nodes.items.len);
        const node = ExplodedNode.init(point, state.*, index);

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
/// Evaluates abstract values for literals and assignments.
pub const AnalysisEngine = struct {
    allocator: std.mem.Allocator,
    /// The exploded graph being built
    graph: ExplodedGraph,
    /// Worklist of (exploded node index, edge kind from predecessor) pairs to process
    worklist: std.ArrayList(WorklistItem),

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
        };
    }

    pub fn deinit(self: *AnalysisEngine) void {
        self.graph.deinit();
        self.worklist.deinit(self.allocator);
    }

    /// Run the analysis on the CFG, building the exploded graph.
    pub fn run(self: *AnalysisEngine) EngineError!void {
        const cfg = self.graph.cfg;

        var initial_state = ProgramState.init(self.allocator);
        const entry_point = ProgramPoint.initPre(cfg.entry);

        const result = try self.graph.getOrCreateNode(entry_point, &initial_state);
        if (!result.is_new) {
            initial_state.deinit();
        }
        try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal });

        while (self.worklist.pop()) |item| {
            try self.processNode(item.node_index, item.edge_kind);
        }
    }

    fn processNode(self: *AnalysisEngine, node_index: u32, edge_kind: EdgeKind) EngineError!void {
        _ = edge_kind;

        const exploded_node = self.graph.getNode(node_index) orelse return;
        const point = exploded_node.point;
        const state = &exploded_node.state;

        switch (point.kind) {
            .pre => {
                const post_point = ProgramPoint.initPost(point.node_index);
                var new_state = try self.transferFunction(point, state);

                const result = try self.graph.getOrCreateNode(post_point, &new_state);
                if (!result.is_new) {
                    new_state.deinit();
                }
                try self.graph.addEdge(node_index, result.index);

                if (result.is_new) {
                    try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal });
                }
            },
            .post => {
                const cfg = self.graph.cfg;

                for (cfg.edges.items) |edge| {
                    if (edge.from == point.node_index) {
                        const succ_point = ProgramPoint.initPre(edge.to);
                        var succ_state = try state.clone(self.allocator);

                        const result = try self.graph.getOrCreateNode(succ_point, &succ_state);
                        if (!result.is_new) {
                            succ_state.deinit();
                        }
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
    /// Evaluates literals and assignments, updating the environment.
    fn transferFunction(self: *AnalysisEngine, point: ProgramPoint, state: *const ProgramState) EngineError!ProgramState {
        const cfg = self.graph.cfg;
        const cfg_node = cfg.getNode(point.node_index) orelse return try state.clone(self.allocator);
        const ir_node = cfg_node.ir_node;

        var new_state = try state.clone(self.allocator);

        switch (ir_node.tag) {
            .var_decl => {
                if (ir_node.ast_node) |ast_node| {
                    try new_state.setVar(ast_node, .unknown);
                }
            },
            .assign => {
                // For assignments, use the LHS identifier node as the key
                // operand_node contains the LHS, operand2_node contains the RHS
                if (ir_node.operand_node) |lhs_node| {
                    // For now, set to unknown. Future enhancement: evaluate RHS literals
                    try new_state.setVar(lhs_node, .unknown);
                }
            },
            else => {},
        }

        return new_state;
    }

    /// Get the exploded graph after analysis
    pub fn getGraph(self: *const AnalysisEngine) *const ExplodedGraph {
        return &self.graph;
    }

    /// Get the state at a specific exploded node
    pub fn getStateAt(self: *const AnalysisEngine, exploded_node_index: u32) ?*const ProgramState {
        if (self.graph.getNode(exploded_node_index)) |node| {
            return &node.state;
        }
        return null;
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
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    try testing.expectEqual(@as(usize, 0), state1.envSize());

    try state1.setVar(42, .{ .concrete_int = 10 });
    try testing.expectEqual(@as(usize, 1), state1.envSize());

    const val = state1.getVar(42);
    try testing.expect(val != null);
    try testing.expect(val.?.eql(.{ .concrete_int = 10 }));

    var state2 = try state1.clone(allocator);
    defer state2.deinit();

    try testing.expect(state1.eql(&state2));

    try state2.setVar(42, .{ .concrete_int = 20 });
    try testing.expect(!state1.eql(&state2));
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

    var state1 = ProgramState.init(allocator);
    try state1.setVar(1, .{ .concrete_int = 42 });

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
    try state2.setVar(1, .{ .concrete_int = 100 });
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

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point1 = ProgramPoint.initPre(0);
    const point2 = ProgramPoint.initPost(0);

    var state1 = ProgramState.init(allocator);
    var state2 = ProgramState.init(allocator);

    const result1 = try graph.getOrCreateNode(point1, &state1);
    const result2 = try graph.getOrCreateNode(point2, &state2);

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

test "AbstractValue basic operations" {
    const testing = std.testing;

    const unknown: AbstractValue = .unknown;
    try testing.expect(unknown.isUnknown());
    try testing.expect(!unknown.isNull());
    try testing.expect(!unknown.isNonNull());
    try testing.expect(!unknown.isConcrete());

    const null_val: AbstractValue = .null_val;
    try testing.expect(null_val.isNull());
    try testing.expect(!null_val.isUnknown());

    const non_null: AbstractValue = .non_null;
    try testing.expect(non_null.isNonNull());

    const concrete: AbstractValue = .{ .concrete_int = 42 };
    try testing.expect(concrete.isConcrete());
    try testing.expectEqual(@as(?i64, 42), concrete.toConcreteInt());

    try testing.expect(!unknown.eql(null_val));
    try testing.expect(unknown.eql(.unknown));
}

test "AbstractValue IntRange operations" {
    const testing = std.testing;
    const IntRange = AbstractValue.IntRange;

    const range1 = IntRange.init(0, 10);
    try testing.expect(range1.contains(5));
    try testing.expect(range1.contains(0));
    try testing.expect(range1.contains(10));
    try testing.expect(!range1.contains(-1));
    try testing.expect(!range1.contains(11));

    const range2 = IntRange.init(5, 15);
    try testing.expect(range1.overlaps(range2));

    const merged = range1.merge(range2);
    try testing.expectEqual(@as(i64, 0), merged.min);
    try testing.expectEqual(@as(i64, 15), merged.max);

    const single = IntRange.single(42);
    try testing.expectEqual(@as(i64, 42), single.min);
    try testing.expectEqual(@as(i64, 42), single.max);
}

test "AbstractValue merge operations" {
    const testing = std.testing;

    const concrete1: AbstractValue = .{ .concrete_int = 10 };
    const concrete2: AbstractValue = .{ .concrete_int = 20 };

    const merged = concrete1.merge(concrete2);
    switch (merged) {
        .int_range => |r| {
            try testing.expectEqual(@as(i64, 10), r.min);
            try testing.expectEqual(@as(i64, 20), r.max);
        },
        else => try testing.expect(false),
    }

    const unknown: AbstractValue = .unknown;
    const merged_unknown = concrete1.merge(unknown);
    try testing.expect(merged_unknown.isUnknown());

    const null_val: AbstractValue = .null_val;
    const non_null: AbstractValue = .non_null;
    const merged_nulls = null_val.merge(non_null);
    try testing.expect(merged_nulls.isUnknown());

    // Verify that merging two null_vals returns null_val (idempotent)
    const null_val2: AbstractValue = .null_val;
    const merged_same_nulls = null_val.merge(null_val2);
    try testing.expect(merged_same_nulls.isNull());
}

test "Environment operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try testing.expectEqual(@as(usize, 0), env.size());
    try testing.expect(env.get(1) == null);

    try env.set(1, .{ .concrete_int = 42 });
    try testing.expectEqual(@as(usize, 1), env.size());

    const val = env.get(1);
    try testing.expect(val != null);
    try testing.expect(val.?.eql(.{ .concrete_int = 42 }));

    try env.set(2, .non_null);
    try testing.expectEqual(@as(usize, 2), env.size());

    env.remove(1);
    try testing.expectEqual(@as(usize, 1), env.size());
    try testing.expect(env.get(1) == null);
}

test "Environment equality and cloning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env1 = Environment.init(allocator);
    defer env1.deinit();

    try env1.set(1, .{ .concrete_int = 10 });
    try env1.set(2, .non_null);

    var env2 = try env1.clone();
    defer env2.deinit();

    try testing.expect(env1.eql(&env2));

    try env2.set(1, .{ .concrete_int = 20 });
    try testing.expect(!env1.eql(&env2));

    const env1_val = env1.get(1);
    try testing.expect(env1_val.?.eql(.{ .concrete_int = 10 }));
}

test "AnalysisEngine with var_decl propagates state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const var_decl = try cfg.addNode(cfg_mod.IrNode.initWithAst(.var_decl, 100));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, var_decl);
    try cfg.addEdge(var_decl, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();
    try testing.expect(graph.nodeCount() >= 6);

    // Find the post-state of var_decl node
    var found_var_decl_post = false;
    for (graph.nodes.items) |node| {
        if (node.point.node_index == var_decl and node.point.kind == .post) {
            const val = node.state.getVar(100);
            try testing.expect(val != null);
            try testing.expect(val.?.isUnknown());
            found_var_decl_post = true;
            break;
        }
    }
    try testing.expect(found_var_decl_post);
}
