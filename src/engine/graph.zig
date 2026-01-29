const std = @import("std");
const cfg_mod = @import("../cfg.zig");
const ids = @import("../ids.zig");
const Cfg = cfg_mod.Cfg;
const IrNode = cfg_mod.IrNode;
const EngineError = @import("base.zig").EngineError;
const state_mod = @import("state.zig");
const ProgramPoint = state_mod.ProgramPoint;
const ProgramState = state_mod.ProgramState;
const LoopHeaderKey = state_mod.LoopHeaderKey;

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
    /// Stored states at loop headers for widening (keyed by LoopHeaderKey)
    loop_header_states: std.HashMap(LoopHeaderKey, ProgramState, LoopHeaderKey.HashContext, std.hash_map.default_max_load_percentage),
    /// Visit count at loop headers for delayed widening (keyed by LoopHeaderKey)
    loop_header_visits: std.HashMap(LoopHeaderKey, u32, LoopHeaderKey.HashContext, std.hash_map.default_max_load_percentage),
    /// Count of nodes created after widening
    widened_nodes: u32,
    /// Count of times widening converged (widened state equals previous)
    widening_converged: u32,

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) ExplodedGraph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .node_map = std.AutoHashMap(u64, u32).init(allocator),
            .cfg = cfg,
            .point_state_counts = std.AutoHashMap(u64, u32).init(allocator),
            .max_states_per_point = default_max_states_per_point,
            .dropped_state_count = 0,
            .loop_header_states = std.HashMap(LoopHeaderKey, ProgramState, LoopHeaderKey.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .loop_header_visits = std.HashMap(LoopHeaderKey, u32, LoopHeaderKey.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .widened_nodes = 0,
            .widening_converged = 0,
        };
    }

    pub fn deinit(self: *ExplodedGraph) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.node_map.deinit();
        self.point_state_counts.deinit();
        // Deinit stored loop header states
        var it = self.loop_header_states.valueIterator();
        while (it.next()) |state_ptr| {
            state_ptr.deinit();
        }
        self.loop_header_states.deinit();
        self.loop_header_visits.deinit();
    }

    /// Options for widening at loop headers.
    pub const WideningOptions = struct {
        /// Whether to apply widening at this loop header
        widen_at_header: bool = false,
        /// The loop header key (must be provided if widen_at_header is true)
        header_key: ?LoopHeaderKey = null,
    };

    /// Result of getOrCreateNode operation.
    pub const GetOrCreateResult = struct {
        /// Index of the node (maxInt(u32) if dropped)
        index: u32,
        /// Whether this is a newly created node
        is_new: bool,
        /// Whether widening was applied
        widening_applied: bool = false,
        /// Whether widening converged (state unchanged after widening)
        converged: bool = false,
        /// Whether the caller should deinit the input state.
        /// True when: (1) node already exists (is_new == false), or
        ///            (2) widening was applied (the widened state, not input, was consumed)
        caller_should_deinit: bool = false,
    };

    /// Get or create a node for the given point and state.
    /// Returns the node index and whether it was newly created.
    /// Ownership: The caller should deinit `state` if `is_new == false` OR if `widening_applied == true`.
    /// When widening is applied, the widened state (not the original) is used for the new node.
    pub fn getOrCreateNode(self: *ExplodedGraph, point: ProgramPoint, state: *ProgramState) EngineError!GetOrCreateResult {
        return self.getOrCreateNodeWithWidening(point, state, .{});
    }

    /// Get or create a node for the given point and state, with optional widening support.
    ///
    /// Flow:
    /// 1. Deduplicate by (point, state) hash as usual.
    /// 2. If widen_at_header is true:
    ///    - If first visit: store clone of state and continue.
    ///    - Else: widen incoming state with stored state and check for convergence.
    /// 3. Apply max_states_per_point **after** widening as safety net.
    pub fn getOrCreateNodeWithWidening(
        self: *ExplodedGraph,
        point: ProgramPoint,
        state: *ProgramState,
        options: WideningOptions,
    ) EngineError!GetOrCreateResult {
        var current_state = state;
        var widened_state: ?ProgramState = null;
        var widening_applied = false;
        var converged = false;

        // Step 2: Apply widening if at a loop header via loop_back edge
        if (options.widen_at_header) {
            if (options.header_key) |header_key| {
                const visit_count = self.loop_header_visits.get(header_key) orelse 0;

                if (visit_count == 0) {
                    // First visit: store a clone of the state for future widening
                    const state_clone = state.clone(self.allocator) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                    self.loop_header_states.put(header_key, state_clone) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                    self.loop_header_visits.put(header_key, 1) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                } else {
                    // Subsequent visits: widen incoming state with stored state
                    if (self.loop_header_states.getPtr(header_key)) |stored_state| {
                        widened_state = stored_state.widen(state) catch |err| switch (err) {
                            error.OutOfMemory => return EngineError.OutOfMemory,
                        };
                        widening_applied = true;

                        // Check for convergence: if widened state equals stored state, we've converged
                        if (widened_state.?.eql(stored_state)) {
                            converged = true;
                            self.widening_converged += 1;
                        } else {
                            // Update stored state with widened result for next iteration
                            // Clone first, then replace to avoid leaving invalid state on OOM
                            var new_clone = widened_state.?.clone(self.allocator) catch |err| switch (err) {
                                error.OutOfMemory => return EngineError.OutOfMemory,
                            };
                            errdefer new_clone.deinit();
                            // Save old state before put() overwrites it
                            var old_state = stored_state.*;
                            // put() for existing key replaces value without allocation failure
                            // (capacity already exists), but we handle it defensively
                            self.loop_header_states.put(header_key, new_clone) catch |err| switch (err) {
                                error.OutOfMemory => return EngineError.OutOfMemory,
                            };
                            // Deinit old state after successful replacement
                            old_state.deinit();
                        }

                        // Increment visit count
                        self.loop_header_visits.put(header_key, visit_count + 1) catch |err| switch (err) {
                            error.OutOfMemory => return EngineError.OutOfMemory,
                        };
                    }

                    // Use widened state for deduplication
                    if (widened_state != null) {
                        current_state = &widened_state.?;
                    }
                }
            }
        }

        errdefer {
            if (widened_state) |*ws| {
                ws.deinit();
            }
        }

        // Step 1: Deduplicate by (point, state) hash
        const key = ExplodedNode.computeKey(point, current_state);

        if (self.node_map.get(key)) |existing_index| {
            if (widened_state) |*ws| {
                ws.deinit();
            }
            return .{ .index = existing_index, .is_new = false, .widening_applied = widening_applied, .converged = converged, .caller_should_deinit = true };
        }

        // Step 3: Check per-point state limit (safety net after widening)
        const point_key = point.hash();
        const current_count = self.point_state_counts.get(point_key) orelse 0;
        if (current_count >= self.max_states_per_point) {
            // Too many states at this point - approximate by not exploring further.
            // Use maxInt as sentinel; addEdge will reject it via bounds check.
            self.dropped_state_count += 1;
            if (widened_state) |*ws| {
                ws.deinit();
            }
            return .{ .index = std.math.maxInt(u32), .is_new = false, .widening_applied = widening_applied, .converged = converged, .caller_should_deinit = true };
        }

        const index: u32 = @intCast(self.nodes.items.len);

        // Use widened state if available, otherwise use original state
        const node_state = if (widened_state) |ws| ws else state.*;
        const node = ExplodedNode.init(point, node_state, index);

        self.nodes.append(self.allocator, node) catch |err| switch (err) {
            error.OutOfMemory => {
                if (widened_state) |*ws| {
                    ws.deinit();
                }
                return EngineError.OutOfMemory;
            },
        };
        self.node_map.put(key, index) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };
        self.point_state_counts.put(point_key, current_count + 1) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };

        if (widening_applied) {
            self.widened_nodes += 1;
        }

        // Caller should deinit the input state if widening was applied (the widened state was consumed, not the input)
        return .{ .index = index, .is_new = true, .widening_applied = widening_applied, .converged = converged, .caller_should_deinit = widening_applied };
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

    /// Get the count of nodes created after widening.
    pub fn getWidenedNodeCount(self: *const ExplodedGraph) u32 {
        return self.widened_nodes;
    }

    /// Get the count of times widening converged.
    pub fn getWideningConvergedCount(self: *const ExplodedGraph) u32 {
        return self.widening_converged;
    }

    /// Get the count of distinct loop headers being tracked for widening.
    /// Each loop header in a unique calling context is counted separately.
    pub fn getTrackedLoopHeaderCount(self: *const ExplodedGraph) u32 {
        return @intCast(self.loop_header_states.count());
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
    if (result2.caller_should_deinit) {
        state1_clone.deinit();
    }
    try testing.expect(!result2.is_new);
    try testing.expect(result2.caller_should_deinit);
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

test "ExplodedGraph widening first visit stores state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state = ProgramState.init(allocator);
    try state.setVar(ids.varId(1), .{ .concrete_int = 10 });

    const header_key = LoopHeaderKey.init(point, &state);

    const result = try graph.getOrCreateNodeWithWidening(point, &state, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    try testing.expect(result.is_new);
    try testing.expect(!result.widening_applied);
    try testing.expect(!result.converged);
    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(u32, 0), graph.getWideningConvergedCount());

    // Verify state was stored
    try testing.expect(graph.loop_header_states.get(header_key) != null);
    try testing.expectEqual(@as(?u32, 1), graph.loop_header_visits.get(header_key));
}

test "ExplodedGraph widening subsequent visit applies widening" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    // First visit: store state
    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 10 });

    const header_key = LoopHeaderKey.init(point, &state1);

    _ = try graph.getOrCreateNodeWithWidening(point, &state1, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    // Second visit: different state should be widened
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 20 }); // different value

    const result = try graph.getOrCreateNodeWithWidening(point, &state2, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    try testing.expect(result.is_new);
    try testing.expect(result.widening_applied);
    try testing.expect(!result.converged); // widened to unknown, different from stored
    try testing.expectEqual(@as(u32, 1), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(?u32, 2), graph.loop_header_visits.get(header_key));
    // Caller needs to clean up state2 since it wasn't consumed (widened state was used instead)
    state2.deinit();
}

test "ExplodedGraph widening convergence detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    // First visit: store state with unknown value
    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .unknown);

    const header_key = LoopHeaderKey.init(point, &state1);

    _ = try graph.getOrCreateNodeWithWidening(point, &state1, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    // Second visit: same unknown value should converge
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .unknown);

    const result = try graph.getOrCreateNodeWithWidening(point, &state2, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    // Should deduplicate since widened state equals stored state
    try testing.expect(!result.is_new);
    try testing.expect(result.widening_applied);
    try testing.expect(result.converged);
    try testing.expectEqual(@as(u32, 1), graph.getWideningConvergedCount());
    // Caller needs to clean up state2 since it wasn't consumed
    state2.deinit();
}

test "ExplodedGraph widening stats tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(u32, 0), graph.getWideningConvergedCount());
    try testing.expectEqual(@as(u32, 0), graph.getDroppedStateCount());
}

test "ExplodedGraph widening respects max_states_per_point as fallback" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    graph.setMaxStatesPerPoint(2);

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    // Create first state (no widening)
    var state1 = ProgramState.init(allocator);
    _ = try graph.getOrCreateNode(point, &state1);

    // Create second state (no widening)
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 10 });
    _ = try graph.getOrCreateNode(point, &state2);

    // Third state should be dropped even with widening enabled
    var state3 = ProgramState.init(allocator);
    try state3.setVar(ids.varId(1), .{ .concrete_int = 20 });

    const header_key = LoopHeaderKey.init(point, &state3);

    const result = try graph.getOrCreateNodeWithWidening(point, &state3, .{
        .widen_at_header = true,
        .header_key = header_key,
    });

    try testing.expect(!result.is_new);
    try testing.expectEqual(std.math.maxInt(u32), result.index);
    try testing.expectEqual(@as(u32, 1), graph.getDroppedStateCount());
    // Cleanup state3 since it wasn't consumed
    state3.deinit();
}

test "ExplodedGraph without widening options works as before" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state = ProgramState.init(allocator);
    try state.setVar(ids.varId(1), .{ .concrete_int = 42 });

    const result = try graph.getOrCreateNode(point, &state);

    try testing.expect(result.is_new);
    try testing.expect(!result.widening_applied);
    try testing.expect(!result.converged);
    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
}
