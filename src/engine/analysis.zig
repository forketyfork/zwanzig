const std = @import("std");
const log = std.log.scoped(.analysis_engine);
const cfg_mod = @import("../cfg.zig");
const ids = @import("../ids.zig");
const Cfg = cfg_mod.Cfg;
const CfgNode = cfg_mod.CfgNode;
const EdgeKind = cfg_mod.EdgeKind;
const CfgBuilder = cfg_mod.CfgBuilder;
const Source = @import("../source.zig").Source;
const BuildMetadata = @import("../build_metadata.zig").BuildMetadata;
const base = @import("base.zig");
const EngineError = base.EngineError;
const default_max_inline_depth = base.default_max_inline_depth;
const default_max_worklist_steps = base.default_max_worklist_steps;
const Constraint = @import("constraints.zig").Constraint;
const FunctionSummary = @import("summary.zig").FunctionSummary;
const SummaryCache = @import("summary.zig").SummaryCache;
const ProgramPoint = @import("state.zig").ProgramPoint;
const ProgramState = @import("state.zig").ProgramState;
const ResourceState = @import("store.zig").ResourceState;
const ExplodedGraph = @import("graph.zig").ExplodedGraph;
const AstNodeId = ids.AstNodeId;
const CfgNodeId = ids.CfgNodeId;

/// Worklist-based analysis engine.
/// Traverses the CFG and builds an exploded graph with deduplication.
/// Evaluates abstract values for literals and assignments.
/// Applies branch constraints and prunes infeasible paths.
/// Supports interprocedural analysis via function inlining and summaries.
pub const AnalysisEngine = struct {
    allocator: std.mem.Allocator,
    /// The exploded graph being built
    graph: ExplodedGraph,
    /// Worklist of (exploded node index, edge kind from predecessor, optional constraint) pairs to process
    worklist: std.ArrayList(WorklistItem),
    /// Count of pruned paths (for testing/debugging)
    pruned_path_count: u32,
    /// Maximum inline depth for interprocedural analysis
    max_inline_depth: u32,
    /// Maximum number of worklist steps before aborting analysis
    max_worklist_steps: usize,
    /// Source file for resolving function calls (optional)
    source: ?*Source,
    /// Cache of built CFGs for functions (by AST node index).
    /// Stores pointers to heap-allocated CFGs for stable addresses that survive
    /// hashmap rehashing.
    function_cfgs: std.AutoHashMap(AstNodeId, *Cfg),
    /// Map from function name to AST node index
    function_names: std.StringHashMap(AstNodeId),
    /// Count of inlined calls (for testing/debugging)
    inlined_call_count: u32,
    /// Cache of function summaries for interprocedural analysis
    summary_cache: SummaryCache,
    /// Whether to use summaries instead of inlining when available
    use_summaries: bool,
    /// Count of summary applications (for testing/debugging)
    summary_use_count: u32,
    /// Build metadata (target configuration, etc.) - shared pointer
    build_metadata: ?*const BuildMetadata,
    /// Name of the checker using this engine (for logging).
    /// This is an unowned slice; callers must ensure the underlying data
    /// remains valid for at least as long as this AnalysisEngine instance.
    checker_name: ?[]const u8,

    const WorklistItem = struct {
        /// Index of the exploded graph node to process
        node_index: u32,
        /// The kind of edge that led to this node (for path-sensitive analysis)
        edge_kind: EdgeKind,
        /// Optional constraint to apply (from branch condition)
        pending_constraint: ?Constraint,
        /// CFG to use for this worklist item (for interprocedural analysis)
        cfg: *const Cfg,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) AnalysisEngine {
        return .{
            .allocator = allocator,
            .graph = ExplodedGraph.init(allocator, cfg),
            .worklist = .empty,
            .pruned_path_count = 0,
            .max_inline_depth = default_max_inline_depth,
            .max_worklist_steps = default_max_worklist_steps,
            .source = null,
            .function_cfgs = std.AutoHashMap(AstNodeId, *Cfg).init(allocator),
            .function_names = std.StringHashMap(AstNodeId).init(allocator),
            .inlined_call_count = 0,
            .summary_cache = SummaryCache.init(allocator),
            .use_summaries = true,
            .summary_use_count = 0,
            .build_metadata = null,
            .checker_name = null,
        };
    }

    /// Initialize with interprocedural analysis support.
    pub fn initWithSource(allocator: std.mem.Allocator, cfg: *const Cfg, source: *Source) AnalysisEngine {
        var engine = init(allocator, cfg);
        engine.source = source;
        return engine;
    }

    pub fn deinit(self: *AnalysisEngine) void {
        self.graph.deinit();
        self.worklist.deinit(self.allocator);
        // Deinit and free all cached CFGs
        var iter = self.function_cfgs.valueIterator();
        while (iter.next()) |cfg_ptr| {
            cfg_ptr.*.deinit();
            self.allocator.destroy(cfg_ptr.*);
        }
        self.function_cfgs.deinit();
        self.function_names.deinit();
        self.summary_cache.deinit();
    }

    /// Set the maximum inline depth for interprocedural analysis.
    pub fn setMaxInlineDepth(self: *AnalysisEngine, depth: u32) void {
        self.max_inline_depth = depth;
    }

    /// Set the maximum number of worklist steps before aborting analysis.
    pub fn setMaxWorklistSteps(self: *AnalysisEngine, steps: usize) void {
        self.max_worklist_steps = steps;
    }

    /// Set the checker name for logging purposes.
    pub fn setCheckerName(self: *AnalysisEngine, name: []const u8) void {
        self.checker_name = name;
    }

    /// Enable or disable the use of function summaries.
    pub fn setUseSummaries(self: *AnalysisEngine, use_summaries: bool) void {
        self.use_summaries = use_summaries;
    }

    /// Get the count of inlined function calls.
    pub fn getInlinedCallCount(self: *const AnalysisEngine) u32 {
        return self.inlined_call_count;
    }

    /// Get the count of summary applications.
    pub fn getSummaryUseCount(self: *const AnalysisEngine) u32 {
        return self.summary_use_count;
    }

    /// Get the summary cache for inspection.
    pub fn getSummaryCache(self: *const AnalysisEngine) *const SummaryCache {
        return &self.summary_cache;
    }

    /// Set build metadata for the analysis engine.
    pub fn setBuildMetadata(self: *AnalysisEngine, metadata: *const BuildMetadata) void {
        self.build_metadata = metadata;
    }

    /// Get the build metadata if set.
    pub fn getBuildMetadata(self: *const AnalysisEngine) ?*const BuildMetadata {
        return self.build_metadata;
    }

    /// Get or compute a summary for a function.
    /// Returns the summary if it can be computed, or null if the function
    /// cannot be analyzed (e.g., missing source, external function).
    pub fn getOrComputeSummary(self: *AnalysisEngine, fn_ast_node: AstNodeId) ?*FunctionSummary {
        // Check cache first
        if (self.summary_cache.get(fn_ast_node)) |summary| {
            return summary;
        }

        // Try to compute a summary
        const summary = self.computeSummary(fn_ast_node) catch return null;
        if (summary) |s| {
            self.summary_cache.put(s) catch return null;
            return self.summary_cache.get(fn_ast_node);
        }
        return null;
    }

    /// Compute a summary for a function by analyzing its CFG.
    fn computeSummary(self: *AnalysisEngine, fn_ast_node: AstNodeId) EngineError!?FunctionSummary {
        // Get or build the function's CFG
        const callee_cfg = self.getOrBuildFunctionCfg(fn_ast_node) orelse return null;

        var summary = FunctionSummary.init(self.allocator, fn_ast_node);

        // Analyze the CFG to extract summary information
        // We do a lightweight traversal to determine error behavior and effects

        var has_error_return = false;
        var has_call = false;

        for (callee_cfg.nodes.items) |cfg_node| {
            switch (cfg_node.ir_node.tag) {
                .try_expr => {
                    has_error_return = true;
                },
                .call => {
                    has_call = true;
                },
                else => {},
            }
        }

        // Check edges for error paths
        for (callee_cfg.edges.items) |edge| {
            if (edge.kind == .try_error) {
                has_error_return = true;
            }
        }

        // Set error behavior based on analysis
        summary.setErrorBehavior(has_error_return, false);

        // If the function has calls, it likely has side effects
        // (conservative: we don't track pure functions yet)
        if (!has_call) {
            // Check if the function only does computation (no I/O, etc.)
            // For now, be conservative and assume all functions have side effects
            // unless they're trivially simple
            var only_computation = true;
            for (callee_cfg.nodes.items) |cfg_node| {
                switch (cfg_node.ir_node.tag) {
                    .fn_entry, .fn_exit, .ret, .var_decl, .assign, .block, .expr, .nop, .branch => {},
                    else => {
                        only_computation = false;
                        break;
                    },
                }
            }
            if (only_computation and !has_error_return) {
                summary.markPure();
            }
        }

        // Set return value to unknown (conservative)
        // More precise analysis could track concrete return values
        summary.setReturnValue(.unknown);

        return summary;
    }

    /// Run the analysis on the CFG, building the exploded graph.
    pub fn run(self: *AnalysisEngine) EngineError!void {
        const cfg = self.graph.cfg;

        // Build function name index if source is available
        if (self.source) |src| {
            try self.buildFunctionIndex(src);
        }

        var initial_state = ProgramState.init(self.allocator);
        initial_state.build_metadata = self.build_metadata;
        const entry_point = ProgramPoint.initPre(cfg.entry, cfg);

        const result = try self.graph.getOrCreateNode(entry_point, &initial_state);
        if (!result.is_new) {
            initial_state.deinit();
        }
        try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null, .cfg = cfg });

        var worklist_steps: usize = 0;
        while (self.worklist.pop()) |item| {
            worklist_steps += 1;
            if (worklist_steps > self.max_worklist_steps) {
                const file_path = if (self.source) |src| src.getFilePath() else "unknown";
                const checker = self.checker_name orelse "unknown";
                const cfg_size = item.cfg.nodeCount();
                const inlined_cfgs = self.function_cfgs.count();
                log.warn("[{s}] analysis limit exceeded: {d} steps, {d} unique states, worklist {d}, cfg nodes {d}, inlined fns {d} in {s}", .{
                    checker,
                    worklist_steps,
                    self.graph.nodes.items.len,
                    self.worklist.items.len,
                    cfg_size,
                    inlined_cfgs,
                    file_path,
                });
                return error.AnalysisLimitExceeded;
            }
            try self.processNode(item.node_index, item.edge_kind, item.pending_constraint, item.cfg);
        }
    }

    /// Build an index of function names to AST node indices.
    fn buildFunctionIndex(self: *AnalysisEngine, src: *Source) EngineError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .fn_decl) {
                // Get the function name from the main token
                const main_token = main_tokens[i];
                // For fn_decl, main_token is the 'fn' keyword, name follows
                if (main_token + 1 < token_tags.len and token_tags[main_token + 1] == .identifier) {
                    const name_token = main_token + 1;
                    // Use tokenSlice to properly handle all identifier forms including @"escaped"
                    const name = tree.tokenSlice(name_token);
                    try self.function_names.put(name, ids.astId(@intCast(i)));
                }
            }
        }
    }

    /// Get or build a CFG for a function by its AST node index.
    fn getOrBuildFunctionCfg(self: *AnalysisEngine, fn_ast_node: AstNodeId) ?*const Cfg {
        // Check cache first - returns the pointer stored in the map
        if (self.function_cfgs.get(fn_ast_node)) |cfg_ptr| {
            return cfg_ptr;
        }

        // Build the CFG if source is available
        const src = self.source orelse return null;
        var builder = CfgBuilder.init(self.allocator);
        const cfg_opt = builder.buildFromFn(src, fn_ast_node) catch return null;
        if (cfg_opt) |cfg| {
            // Allocate CFG on the heap for stable address
            const cfg_ptr = self.allocator.create(Cfg) catch return null;
            cfg_ptr.* = cfg;
            self.function_cfgs.put(fn_ast_node, cfg_ptr) catch {
                cfg_ptr.deinit();
                self.allocator.destroy(cfg_ptr);
                return null;
            };
            return cfg_ptr;
        }
        return null;
    }

    /// Resolve a function call to a function AST node index.
    /// Returns null for external or unresolvable calls.
    fn resolveFunctionCall(self: *AnalysisEngine, call_ast_node: u32) ?AstNodeId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (call_ast_node >= tags.len) return null;
        const tag = tags[call_ast_node];

        // For call nodes, use fullCall to extract the callee
        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tag) {
            .call, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_ast_node)),
            else => return null,
        } orelse return null;

        // Extract callee node index
        const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= tags.len) return null;
        const callee_tag = tags[callee_node];

        // Only handle simple identifier calls for now
        if (callee_tag == .identifier) {
            const callee_token = main_tokens[callee_node];
            if (callee_token < token_tags.len and token_tags[callee_token] == .identifier) {
                // Use tokenSlice to properly handle all identifier forms including @"escaped"
                const name = tree.tokenSlice(callee_token);

                // Look up in function index
                return self.function_names.get(name);
            }
        }

        return null;
    }

    const AllocatorCallKind = enum {
        alloc,
        free,
    };

    const AllocatorCall = struct {
        kind: AllocatorCallKind,
        first_arg: ?u32,
        call_node: u32,
    };

    fn resolveAllocatorCall(self: *AnalysisEngine, expr_node: u32) ?AllocatorCall {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        return self.resolveAllocatorCallFromExpr(tree, expr_node);
    }

    fn isDefinitelyNonAlloc(self: *AnalysisEngine, expr_node: u32) bool {
        const src = self.source orelse return false;
        const tree = src.ast() catch return false;
        return self.isDefinitelyNonAllocExpr(tree, expr_node);
    }

    fn resolveAllocatorCallFromExpr(self: *AnalysisEngine, tree: *const std.zig.Ast, expr_node: u32) ?AllocatorCall {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return null;
        const tag = tags[expr_node];

        return switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => self.resolveAllocatorCallFromCall(tree, expr_node),
            .@"try" => self.resolveAllocatorCallFromExpr(tree, @intFromEnum(datas[expr_node].node)),
            .@"catch" => blk: {
                const pair = datas[expr_node].node_and_node;
                if (self.resolveAllocatorCallFromExpr(tree, @intFromEnum(pair[0]))) |call_info| {
                    break :blk call_info;
                }
                break :blk self.resolveAllocatorCallFromExpr(tree, @intFromEnum(pair[1]));
            },
            .unwrap_optional, .grouped_expression => self.resolveAllocatorCallFromExpr(tree, @intFromEnum(datas[expr_node].node_and_token[0])),
            else => null,
        };
    }

    fn resolveAllocatorCallFromCall(self: *AnalysisEngine, tree: *const std.zig.Ast, call_ast_node: u32) ?AllocatorCall {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);

        if (call_ast_node >= tags.len) return null;
        const tag = tags[call_ast_node];

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_ast_node)),
            else => return null,
        } orelse return null;

        const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= tags.len) return null;
        if (tags[callee_node] != .field_access) return null;

        const field_access_data = datas[callee_node].node_and_token;
        const base_node = @intFromEnum(field_access_data[0]);
        const field_token = field_access_data[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
        const field_name = tree.tokenSlice(field_token);

        const first_arg: ?u32 = if (full_call.ast.params.len > 0)
            @intFromEnum(full_call.ast.params[0])
        else
            null;

        if (self.isAllocatorBase(tree, base_node)) {
            if (std.mem.eql(u8, field_name, "alloc") or std.mem.eql(u8, field_name, "dupe")) {
                return .{ .kind = .alloc, .first_arg = first_arg, .call_node = call_ast_node };
            }
            if (std.mem.eql(u8, field_name, "free")) {
                return .{ .kind = .free, .first_arg = first_arg, .call_node = call_ast_node };
            }
        }

        if (std.mem.eql(u8, field_name, "allocPrint")) {
            if (first_arg) |arg_node| {
                if (self.isAllocatorBase(tree, arg_node)) {
                    return .{ .kind = .alloc, .first_arg = first_arg, .call_node = call_ast_node };
                }
            }
        }
        return null;
    }

    fn isAllocatorBase(self: *AnalysisEngine, tree: *const std.zig.Ast, base_node: u32) bool {
        _ = self;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (base_node >= tags.len) return false;
        switch (tags[base_node]) {
            .identifier => {
                const base_token = main_tokens[base_node];
                if (base_token >= token_tags.len or token_tags[base_token] != .identifier) return false;
                const base_name = tree.tokenSlice(base_token);
                return std.mem.eql(u8, base_name, "allocator");
            },
            .field_access => {
                const field_access_data = datas[base_node].node_and_token;
                const field_token = field_access_data[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return false;
                const field_name = tree.tokenSlice(field_token);
                return std.mem.eql(u8, field_name, "allocator");
            },
            else => return false,
        }
    }

    fn resolveVarIdFromVarDecl(self: *AnalysisEngine, var_decl_node: u32) ?ids.VarId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const full = tree.fullVarDecl(@enumFromInt(var_decl_node)) orelse return null;
        const token_tags = tree.tokens.items(.tag);
        const name_token = full.ast.mut_token + 1;
        if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return null;
        return ids.varId(name_token);
    }

    fn resolveVarIdFromIdentifier(self: *AnalysisEngine, identifier_node: u32) ?ids.VarId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (identifier_node >= tags.len) return null;
        if (tags[identifier_node] != .identifier) return null;
        const token = main_tokens[identifier_node];
        if (token >= token_tags.len or token_tags[token] != .identifier) return null;
        const name = tree.tokenSlice(token);
        if (self.resolveDeclTokenForName(name, token)) |decl_token| {
            return ids.varId(decl_token);
        }
        return ids.varId(token);
    }

    fn resolveVarIdFromExpr(self: *AnalysisEngine, expr_node: u32) ?ids.VarId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return null;
        return switch (tags[expr_node]) {
            .identifier => self.resolveVarIdFromIdentifier(expr_node),
            .grouped_expression, .unwrap_optional => blk: {
                const data = datas[expr_node].node_and_token;
                break :blk self.resolveVarIdFromExpr(@intFromEnum(data[0]));
            },
            else => null,
        };
    }

    fn resolveDeclTokenForName(self: *AnalysisEngine, name: []const u8, ident_token: u32) ?u32 {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        var best_token: ?u32 = null;

        for (tags, 0..) |tag, i| {
            switch (tag) {
                .simple_var_decl,
                .aligned_var_decl,
                .local_var_decl,
                .global_var_decl,
                => {
                    const full = tree.fullVarDecl(@enumFromInt(i)) orelse continue;
                    const name_token = full.ast.mut_token + 1;
                    if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                    if (name_token >= ident_token) continue;
                    const decl_name = tree.tokenSlice(name_token);
                    if (!std.mem.eql(u8, decl_name, name)) continue;
                    if (best_token == null or name_token > best_token.?) {
                        best_token = name_token;
                    }
                },
                .fn_decl,
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                => {
                    var buf: [1]std.zig.Ast.Node.Index = undefined;
                    const full = tree.fullFnProto(&buf, @enumFromInt(i)) orelse continue;
                    var it = full.iterate(tree);
                    while (it.next()) |param| {
                        const name_token = param.name_token orelse continue;
                        if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                        if (name_token >= ident_token) continue;
                        const decl_name = tree.tokenSlice(name_token);
                        if (!std.mem.eql(u8, decl_name, name)) continue;
                        if (best_token == null or name_token > best_token.?) {
                            best_token = name_token;
                        }
                    }
                },
                else => {},
            }
        }

        return best_token;
    }

    fn resolveVarDeclInitNode(self: *AnalysisEngine, var_decl_node: u32) ?u32 {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const full = tree.fullVarDecl(@enumFromInt(var_decl_node)) orelse return null;
        if (full.ast.init_node.unwrap()) |init_node| {
            return @intFromEnum(init_node);
        }
        return null;
    }

    fn isDefinitelyNonAllocExpr(self: *AnalysisEngine, tree: *const std.zig.Ast, expr_node: u32) bool {
        if (self.resolveAllocatorCallFromExpr(tree, expr_node) != null) return false;

        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return false;
        return switch (tags[expr_node]) {
            .slice,
            .slice_open,
            .slice_sentinel,
            .address_of,
            .array_mult,
            .array_cat,
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => true,
            .grouped_expression, .unwrap_optional => blk: {
                const data = datas[expr_node].node_and_token;
                break :blk self.isDefinitelyNonAllocExpr(tree, @intFromEnum(data[0]));
            },
            .@"try" => self.isDefinitelyNonAllocExpr(tree, @intFromEnum(datas[expr_node].node)),
            .@"catch" => blk: {
                const pair = datas[expr_node].node_and_node;
                const left = self.isDefinitelyNonAllocExpr(tree, @intFromEnum(pair[0]));
                const right = self.isDefinitelyNonAllocExpr(tree, @intFromEnum(pair[1]));
                break :blk left and right;
            },
            else => false,
        };
    }

    fn resolveCallToken(self: *AnalysisEngine, call_node: u32) ?u32 {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const main_tokens = tree.nodes.items(.main_token);
        if (call_node >= main_tokens.len) return null;
        return main_tokens[call_node];
    }

    fn processNode(self: *AnalysisEngine, node_index: u32, edge_kind: EdgeKind, pending_constraint: ?Constraint, current_cfg: *const Cfg) EngineError!void {
        _ = edge_kind;

        const exploded_node = self.graph.getNode(node_index) orelse return;
        const point = exploded_node.point;

        // Clone the state immediately - we can't hold a reference to exploded_node.state
        // because graph operations may reallocate the nodes array and invalidate pointers.
        var state_copy = try exploded_node.state.clone(self.allocator);
        defer state_copy.deinit();

        switch (point.kind) {
            .pre => {
                const cfg_node = current_cfg.getNode(point.node_index);

                // Check if this is a call node that should be inlined
                if (cfg_node) |node| {
                    if (node.ir_node.tag == .call) {
                        const inline_result = try self.handleCallNode(node_index, node, &state_copy, current_cfg);
                        if (inline_result.inlined) {
                            // Call was inlined, don't process normally
                            return;
                        }
                        // Fall through to normal processing for external/unresolvable calls
                    }
                }

                const post_point = ProgramPoint.initPost(point.node_index, current_cfg);
                var new_state = try self.transferFunction(point, &state_copy, current_cfg);

                // Apply any pending constraint from a branch edge
                if (pending_constraint) |constraint| {
                    try new_state.addConstraint(constraint);

                    // Check if the state is still satisfiable after adding the constraint
                    if (!new_state.isSatisfiable()) {
                        self.pruned_path_count += 1;
                        new_state.deinit();
                        return; // Prune this path
                    }
                }

                const result = try self.graph.getOrCreateNode(post_point, &new_state);
                if (!result.is_new) {
                    new_state.deinit();
                }
                try self.graph.addEdge(node_index, result.index);

                if (result.is_new) {
                    try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null, .cfg = current_cfg });
                }
            },
            .post => {
                const cfg_node = current_cfg.getNode(point.node_index);

                // Check if we're at a function exit and need to return to caller
                if (cfg_node) |node| {
                    if (node.ir_node.tag == .fn_exit and state_copy.isInlined()) {
                        try self.handleFunctionReturn(node_index, &state_copy);
                        return;
                    }
                }

                // Check if this is a branch node - if so, we need to extract constraints
                const is_branch_node = if (cfg_node) |node| node.ir_node.tag == .branch else false;
                const branch_constraint = if (is_branch_node)
                    self.extractBranchConstraint(cfg_node.?)
                else
                    null;

                for (current_cfg.edges.items) |edge| {
                    if (edge.from == point.node_index) {
                        const succ_point = ProgramPoint.initPre(edge.to, current_cfg);
                        var succ_state = try state_copy.clone(self.allocator);

                        // Handle error state transitions based on edge kind
                        switch (edge.kind) {
                            .try_error => {
                                succ_state.setErrorState(.error_active);
                            },
                            .try_success => {
                                // Continue on normal path
                            },
                            .catch_error => {
                                // Entering catch block - error is being handled
                                succ_state.setErrorState(.error_handled);
                            },
                            .catch_success => {
                                // Exiting catch block - return to normal
                                succ_state.setErrorState(.normal);
                            },
                            .errdefer_edge => {
                                // Errdefer only executes on error path
                                if (!succ_state.isErrorPath()) {
                                    succ_state.deinit();
                                    continue;
                                }
                            },
                            else => {},
                        }

                        // Determine the constraint to apply based on the edge kind
                        var constraint_to_apply: ?Constraint = null;
                        if (branch_constraint) |bc| {
                            if (edge.kind == .branch_true) {
                                constraint_to_apply = bc;
                            } else if (edge.kind == .branch_false) {
                                constraint_to_apply = bc.negate();
                            }
                        }

                        // If we have a constraint, apply it to the state before deduplication
                        if (constraint_to_apply) |constraint| {
                            try succ_state.addConstraint(constraint);
                            if (!succ_state.isSatisfiable()) {
                                self.pruned_path_count += 1;
                                succ_state.deinit();
                                continue;
                            }
                        }

                        const result = try self.graph.getOrCreateNode(succ_point, &succ_state);
                        if (!result.is_new) {
                            succ_state.deinit();
                        }
                        try self.graph.addEdge(node_index, result.index);

                        if (result.is_new) {
                            try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = edge.kind, .pending_constraint = null, .cfg = current_cfg });
                        }
                    }
                }
            },
        }
    }

    const InlineResult = struct {
        inlined: bool,
        summary_applied: bool,
    };

    /// Handle a call node, potentially using a summary or inlining the callee.
    fn handleCallNode(
        self: *AnalysisEngine,
        exploded_node_index: u32,
        cfg_node: *const CfgNode,
        state: *const ProgramState,
        caller_cfg: *const Cfg,
    ) EngineError!InlineResult {
        // Try to resolve the call target
        const call_ast_node = cfg_node.ir_node.ast_node orelse return .{ .inlined = false, .summary_applied = false };
        const callee_fn_node = self.resolveFunctionCall(call_ast_node) orelse return .{ .inlined = false, .summary_applied = false };

        // Try to use a cached summary if summaries are enabled
        // Only use summaries for pure functions (no side effects) to avoid losing
        // callee effects when skipping inlining
        if (self.use_summaries) {
            if (self.getOrComputeSummary(callee_fn_node)) |summary| {
                // Only apply summaries for pure functions to preserve side effect semantics
                if (!summary.has_side_effects and summary.isApplicable(state)) {
                    // Find the return point (successor of the call node in the caller)
                    var return_node: ?CfgNodeId = null;
                    for (caller_cfg.edges.items) |edge| {
                        if (edge.from == cfg_node.index) {
                            return_node = edge.to;
                            break;
                        }
                    }
                    const ret_node = return_node orelse return .{ .inlined = false, .summary_applied = false };

                    // Apply the summary to the state
                    var summary_state = try state.clone(self.allocator);
                    const is_satisfiable = try summary.applyToState(&summary_state);

                    // If postconditions contradict existing constraints, fall back to inlining
                    if (!is_satisfiable) {
                        summary_state.deinit();
                        // Fall through to inlining below
                    } else {
                        self.summary_use_count += 1;

                        // Create the post-call point
                        const post_call_point = ProgramPoint.initPre(ret_node, caller_cfg);
                        const result = try self.graph.getOrCreateNode(post_call_point, &summary_state);
                        if (!result.is_new) {
                            summary_state.deinit();
                        } else {
                            try self.worklist.append(self.allocator, .{
                                .node_index = result.index,
                                .edge_kind = .normal,
                                .pending_constraint = null,
                                .cfg = caller_cfg,
                            });
                        }

                        try self.graph.addEdge(exploded_node_index, result.index);

                        return .{ .inlined = true, .summary_applied = true };
                    }
                }
            }
        }

        // Fall back to inlining if no applicable summary or summaries are disabled
        // Check if we've exceeded the inline depth limit
        if (state.getInlineDepth() >= self.max_inline_depth) {
            return .{ .inlined = false, .summary_applied = false };
        }

        // Get or build the callee's CFG
        const callee_cfg = self.getOrBuildFunctionCfg(callee_fn_node) orelse return .{ .inlined = false, .summary_applied = false };

        // Find the return point (successor of the call node in the caller)
        var return_node: ?CfgNodeId = null;
        for (caller_cfg.edges.items) |edge| {
            if (edge.from == cfg_node.index) {
                return_node = edge.to;
                break;
            }
        }
        const ret_node = return_node orelse return .{ .inlined = false, .summary_applied = false };

        // Create a new state for the inlined call
        var inline_state = try state.clone(self.allocator);
        inline_state.incrementInlineDepth();

        // Push the call site onto the stack
        try inline_state.pushCallSite(.{
            .call_node = cfg_node.index,
            .caller_cfg = caller_cfg,
            .return_node = ret_node,
        });

        // Create entry point for the callee
        const callee_entry_point = ProgramPoint.initPre(callee_cfg.entry, callee_cfg);
        const result = try self.graph.getOrCreateNode(callee_entry_point, &inline_state);
        if (!result.is_new) {
            inline_state.deinit();
        } else {
            try self.worklist.append(self.allocator, .{
                .node_index = result.index,
                .edge_kind = .normal,
                .pending_constraint = null,
                .cfg = callee_cfg,
            });
        }

        try self.graph.addEdge(exploded_node_index, result.index);
        self.inlined_call_count += 1;

        return .{ .inlined = true, .summary_applied = false };
    }

    /// Handle returning from an inlined function.
    fn handleFunctionReturn(
        self: *AnalysisEngine,
        exploded_node_index: u32,
        state: *ProgramState,
    ) EngineError!void {
        // Pop the call site from the stack
        const call_site = state.popCallSite() orelse return;
        state.decrementInlineDepth();

        // Create a state for continuing after the call
        var return_state = try state.clone(self.allocator);

        // Create the return point in the caller
        const return_point = ProgramPoint.initPre(call_site.return_node, call_site.caller_cfg);
        const result = try self.graph.getOrCreateNode(return_point, &return_state);
        if (!result.is_new) {
            return_state.deinit();
        } else {
            try self.worklist.append(self.allocator, .{
                .node_index = result.index,
                .edge_kind = .normal,
                .pending_constraint = null,
                .cfg = call_site.caller_cfg,
            });
        }

        try self.graph.addEdge(exploded_node_index, result.index);
    }

    /// Extract a constraint from a branch node's condition.
    /// Returns null if no constraint can be extracted.
    fn extractBranchConstraint(self: *AnalysisEngine, cfg_node: *const CfgNode) ?Constraint {
        // The branch node has ast_node pointing to the if expression
        // In a more complete implementation, we would analyze the condition expression
        // to extract constraints like "x == 5" or "x != null"
        //
        // For now, we support a simple pattern where the branch node's operand_node
        // contains the variable being tested, and operand2_node contains information
        // about the comparison.
        //
        // This is a placeholder that can be enhanced when the CFG builder provides
        // more detailed information about branch conditions.
        const ir_node = cfg_node.ir_node;
        if (ir_node.operand_node) |var_id| {
            const var_key = if (self.source != null)
                (self.resolveVarIdFromExpr(var_id) orelse ids.varId(var_id))
            else
                ids.varId(var_id);
            if (ir_node.operand2_node) |cmp_info| {
                // Interpret operand2_node as encoded comparison info:
                // High 32 bits of the value represent the comparison constant
                // This is a simplified encoding for now
                return Constraint.intCompare(var_key, .eq, @as(i64, cmp_info));
            }
            // If we only have a variable and no comparison info, assume null check
            return Constraint.nullCheck(var_key, true);
        }
        return null;
    }

    /// Transfer function: compute the new state after executing a CFG node.
    /// Evaluates literals and assignments, updating the environment.
    /// For call nodes that couldn't be inlined, treats them as having unknown effects.
    fn transferFunction(self: *AnalysisEngine, point: ProgramPoint, state: *const ProgramState, current_cfg: *const Cfg) EngineError!ProgramState {
        const cfg_node = current_cfg.getNode(point.node_index) orelse return try state.clone(self.allocator);
        const ir_node = cfg_node.ir_node;

        var new_state = try state.clone(self.allocator);

        switch (ir_node.tag) {
            .var_decl => {
                if (ir_node.ast_node) |ast_node| {
                    const var_id = self.resolveVarIdFromVarDecl(ast_node) orelse ids.varId(ast_node);
                    try new_state.setVar(var_id, .unknown);
                    if (self.resolveVarDeclInitNode(ast_node)) |init_node| {
                        if (self.resolveAllocatorCall(init_node)) |call_info| {
                            if (call_info.kind == .alloc) {
                                try new_state.trackAllocation(var_id);
                            }
                        } else if (self.isDefinitelyNonAlloc(init_node)) {
                            try new_state.trackNonAllocation(var_id);
                        }
                    }
                }
            },
            .assign => {
                // For assignments, use the LHS identifier node as the key
                // operand_node contains the LHS, operand2_node contains the RHS
                if (ir_node.operand_node) |lhs_node| {
                    // For now, set to unknown. Future enhancement: evaluate RHS literals
                    const var_id = self.resolveVarIdFromIdentifier(lhs_node) orelse ids.varId(lhs_node);
                    try new_state.setVar(var_id, .unknown);
                    if (ir_node.operand2_node) |rhs_node| {
                        if (self.resolveAllocatorCall(rhs_node)) |call_info| {
                            if (call_info.kind == .alloc) {
                                try new_state.trackAllocation(var_id);
                            }
                        } else if (self.isDefinitelyNonAlloc(rhs_node)) {
                            try new_state.trackNonAllocation(var_id);
                        }
                    }
                }
            },
            .call => {
                // External or unresolvable calls: treat as unknown effects.
                // This means we conservatively assume the call could modify any state.
                // For now, we don't invalidate any specific variables since we don't
                // have precise aliasing information. Future enhancement: track which
                // variables could be modified by external calls.
                //
                // The call node itself doesn't change the abstract state significantly,
                // but the return value (if captured) would be unknown.
                if (ir_node.ast_node) |ast_node| {
                    if (self.resolveAllocatorCall(ast_node)) |call_info| {
                        if (call_info.kind == .free) {
                            if (call_info.first_arg) |arg_node| {
                                if (self.resolveVarIdFromExpr(arg_node)) |var_id| {
                                    const call_token = self.resolveCallToken(call_info.call_node);
                                    try new_state.trackFree(var_id, call_token);
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }

        return new_state;
    }

    /// Get the count of pruned paths
    pub fn getPrunedPathCount(self: *const AnalysisEngine) u32 {
        return self.pruned_path_count;
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
    try testing.expectEqual(entry, node0.point.node_index);
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
            const val = node.state.getVar(ids.varId(100));
            try testing.expect(val != null);
            try testing.expect(val.?.isUnknown());
            found_var_decl_post = true;
            break;
        }
    }
    try testing.expect(found_var_decl_post);
}

test "AnalysisEngine branch constraint pruning" {
    const allocator = std.testing.allocator;

    // Create a CFG with a branch where one path should be pruned:
    // entry -> assign (x = 5) -> branch (x == 10?) -> then/else -> merge -> exit
    //
    // We'll manually set x = 5 in the initial state, then the branch "x == 10"
    // should prune the then-branch since 5 != 10

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    // Create a branch node with condition info embedded
    // operand_node = variable being tested (100)
    // operand2_node = value being compared to (10)
    var branch_ir = cfg_mod.IrNode.init(.branch);
    branch_ir.operand_node = 100;
    branch_ir.operand2_node = 10;
    const branch = try cfg.addNode(branch_ir);

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

    // Manually set the initial state: x = 5
    // This simulates the effect of an assignment before the branch
    const entry_point = ProgramPoint.initPre(entry, &cfg);
    var initial_state = ProgramState.init(allocator);
    try initial_state.setVar(ids.varId(100), .{ .concrete_int = 5 });
    const result = try engine.graph.getOrCreateNode(entry_point, &initial_state);
    try engine.worklist.append(allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null, .cfg = &cfg });
    if (!result.is_new) {
        initial_state.deinit();
    }

    try engine.run();

    // With x = 5 and branch condition x == 10, the then-branch (x == 10) should be pruned
    // We should see exactly 1 pruned path
    try std.testing.expect(engine.pruned_path_count == 1);
}

test "AnalysisEngine try edge sets error state" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const try_node = try cfg.addNode(cfg_mod.IrNode.init(.try_expr));
    const success_node = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const error_node = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, try_node);
    try cfg.addEdgeWithKind(try_node, success_node, .try_success);
    try cfg.addEdgeWithKind(try_node, error_node, .try_error);
    try cfg.addEdge(success_node, exit);
    try cfg.addEdge(error_node, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();

    var found_error_state = false;
    var found_normal_state = false;

    for (graph.nodes.items) |node| {
        if (node.point.node_index == error_node and node.point.kind == .pre) {
            if (node.state.isErrorPath()) {
                found_error_state = true;
            }
        }
        if (node.point.node_index == success_node and node.point.kind == .pre) {
            if (node.state.isNormalPath()) {
                found_normal_state = true;
            }
        }
    }

    try std.testing.expect(found_error_state);
    try std.testing.expect(found_normal_state);
}

test "AnalysisEngine catch edge handles error" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const try_node = try cfg.addNode(cfg_mod.IrNode.init(.try_expr));
    const catch_node = try cfg.addNode(cfg_mod.IrNode.init(.catch_expr));
    const after_catch = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, try_node);
    try cfg.addEdgeWithKind(try_node, catch_node, .try_error);
    try cfg.addEdgeWithKind(catch_node, after_catch, .catch_error);
    try cfg.addEdgeWithKind(after_catch, exit, .catch_success);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();

    var found_handled_state = false;
    var found_normal_after_catch = false;

    for (graph.nodes.items) |node| {
        if (node.point.node_index == after_catch and node.point.kind == .pre) {
            if (node.state.getErrorState() == .error_handled) {
                found_handled_state = true;
            }
        }
        if (node.point.node_index == exit and node.point.kind == .pre) {
            if (node.state.isNormalPath()) {
                found_normal_after_catch = true;
            }
        }
    }

    try std.testing.expect(found_handled_state);
    try std.testing.expect(found_normal_after_catch);
}

test "AnalysisEngine errdefer only on error path" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const try_node = try cfg.addNode(cfg_mod.IrNode.init(.try_expr));
    const success_node = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const errdefer_node = try cfg.addNode(cfg_mod.IrNode.init(.errdefer_stmt));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, try_node);
    try cfg.addEdgeWithKind(try_node, success_node, .try_success);
    try cfg.addEdgeWithKind(try_node, errdefer_node, .try_error);
    try cfg.addEdgeWithKind(success_node, errdefer_node, .errdefer_edge);
    try cfg.addEdge(errdefer_node, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    const graph = engine.getGraph();

    var errdefer_reached_from_error = false;
    var errdefer_reached_from_success = false;

    for (graph.nodes.items) |node| {
        if (node.point.node_index == errdefer_node and node.point.kind == .pre) {
            if (node.state.isErrorPath()) {
                errdefer_reached_from_error = true;
            } else if (node.state.isNormalPath()) {
                errdefer_reached_from_success = true;
            }
        }
    }

    try std.testing.expect(errdefer_reached_from_error);
    try std.testing.expect(!errdefer_reached_from_success);
}

test "AnalysisEngine max inline depth configuration" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try std.testing.expectEqual(default_max_inline_depth, engine.max_inline_depth);

    engine.setMaxInlineDepth(5);
    try std.testing.expectEqual(@as(u32, 5), engine.max_inline_depth);

    engine.setMaxInlineDepth(0);
    try std.testing.expectEqual(@as(u32, 0), engine.max_inline_depth);
}

test "AnalysisEngine inlined call count starts at zero" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try std.testing.expectEqual(@as(u32, 0), engine.getInlinedCallCount());

    try engine.run();

    // Without source, no calls can be inlined
    try std.testing.expectEqual(@as(u32, 0), engine.getInlinedCallCount());
}

test "AnalysisEngine with source processes simple function" {
    const allocator = std.testing.allocator;

    // Simple source with a function
    const code: [:0]const u8 =
        \\fn foo() void {
        \\    return;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Find the fn_decl node
    const tree = source.ast() catch return;
    const tags = tree.nodes.items(.tag);
    var fn_node: ?AstNodeId = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = ids.astId(@intCast(i));
            break;
        }
    }
    const fn_idx = fn_node orelse return; // No fn_decl found, skip test

    // Build CFG for the function
    var builder = CfgBuilder.init(allocator);
    var cfg_opt = builder.buildFromFn(&source, fn_idx) catch return;

    if (cfg_opt) |*cfg| {
        defer cfg.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg, &source);
        defer engine.deinit();

        try engine.run();

        // Should complete without error
        try std.testing.expect(engine.getGraph().nodeCount() > 0);
    }
}

test "AnalysisEngine transfer function handles call nodes" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const call = try cfg.addNode(cfg_mod.IrNode.initWithAst(.call, 100));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, call);
    try cfg.addEdge(call, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    // Should complete without error - call is treated as unknown effect
    const graph = engine.getGraph();
    try std.testing.expect(graph.nodeCount() >= 6); // entry pre/post, call pre/post, exit pre/post
}

test "AnalysisEngine store tracks allocator alloc/free" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.alloc(u8, 1);
        \\    allocator.free(ptr);
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = source.ast() catch return;
    const tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);

    var fn_node: ?AstNodeId = null;
    var ptr_var_id: ?ids.VarId = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = ids.astId(@intCast(i));
        }
        switch (tag) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                const full = tree.fullVarDecl(@enumFromInt(i)) orelse continue;
                const name_token = full.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const name = tree.tokenSlice(name_token);
                if (std.mem.eql(u8, name, "ptr")) {
                    ptr_var_id = ids.varId(name_token);
                }
            },
            else => {},
        }
    }
    const fn_idx = fn_node orelse return;
    const region = ptr_var_id orelse return;

    var builder = CfgBuilder.init(allocator);
    var cfg_opt = builder.buildFromFn(&source, fn_idx) catch return;
    if (cfg_opt) |*cfg| {
        defer cfg.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg, &source);
        defer engine.deinit();

        try engine.run();

        var call_node_id: ?CfgNodeId = null;
        var call_count: usize = 0;
        for (cfg.nodes.items) |node| {
            if (node.ir_node.tag == .call) {
                call_node_id = node.index;
                call_count += 1;
            }
        }
        try testing.expect(call_count >= 1);
        const call_id = call_node_id orelse return;

        var found = false;
        for (engine.getGraph().nodes.items) |node| {
            if (node.point.node_index == call_id and node.point.kind == .post) {
                const state = &node.state;
                try testing.expectEqual(ResourceState.freed, state.getRegionState(region).?);
                try testing.expectEqual(@as(usize, 0), state.getStoreViolations().len);
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "AnalysisEngine store records double free violations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const StoreViolationKind = @import("store.zig").StoreViolationKind;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.alloc(u8, 1);
        \\    allocator.free(ptr);
        \\    allocator.free(ptr);
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = source.ast() catch return;
    const tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);

    var fn_node: ?AstNodeId = null;
    var ptr_var_id: ?ids.VarId = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = ids.astId(@intCast(i));
        }
        switch (tag) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                const full = tree.fullVarDecl(@enumFromInt(i)) orelse continue;
                const name_token = full.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const name = tree.tokenSlice(name_token);
                if (std.mem.eql(u8, name, "ptr")) {
                    ptr_var_id = ids.varId(name_token);
                }
            },
            else => {},
        }
    }
    const fn_idx = fn_node orelse return;
    const region = ptr_var_id orelse return;

    var builder = CfgBuilder.init(allocator);
    var cfg_opt = builder.buildFromFn(&source, fn_idx) catch return;
    if (cfg_opt) |*cfg| {
        defer cfg.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg, &source);
        defer engine.deinit();

        try engine.run();

        var call_node_id: ?CfgNodeId = null;
        var call_count: usize = 0;
        for (cfg.nodes.items) |node| {
            if (node.ir_node.tag == .call) {
                call_node_id = node.index;
                call_count += 1;
            }
        }
        try testing.expect(call_count >= 2);
        const second_call = call_node_id orelse return;

        var found = false;
        for (engine.getGraph().nodes.items) |node| {
            if (node.point.node_index == second_call and node.point.kind == .post) {
                const state = &node.state;
                try testing.expectEqual(ResourceState.freed, state.getRegionState(region).?);
                try testing.expectEqual(@as(usize, 1), state.getStoreViolations().len);
                try testing.expectEqual(StoreViolationKind.double_free, state.getStoreViolations()[0].kind);
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "AnalysisEngine store tracks self allocator calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\const Foo = struct {
        \\    allocator: std.mem.Allocator,
        \\    fn bar(self: *Foo) !void {
        \\        var ptr = try self.allocator.alloc(u8, 1);
        \\        self.allocator.free(ptr);
        \\        self.allocator.free(ptr);
        \\    }
        \\};
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = source.ast() catch return;
    const tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);

    var fn_node: ?AstNodeId = null;
    var ptr_var_id: ?ids.VarId = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = ids.astId(@intCast(i));
        }
        switch (tag) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                const full = tree.fullVarDecl(@enumFromInt(i)) orelse continue;
                const name_token = full.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const name = tree.tokenSlice(name_token);
                if (std.mem.eql(u8, name, "ptr")) {
                    ptr_var_id = ids.varId(name_token);
                }
            },
            else => {},
        }
    }
    const fn_idx = fn_node orelse return;
    const region = ptr_var_id orelse return;

    var builder = CfgBuilder.init(allocator);
    var cfg_opt = builder.buildFromFn(&source, fn_idx) catch return;
    if (cfg_opt) |*cfg| {
        defer cfg.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg, &source);
        defer engine.deinit();

        try engine.run();

        var found = false;
        for (engine.getGraph().nodes.items) |node| {
            if (node.point.kind == .post) {
                const state = &node.state;
                if (state.getRegionState(region)) |region_state| {
                    if (region_state == .freed and state.getStoreViolations().len == 1) {
                        found = true;
                        break;
                    }
                }
            }
        }
        try testing.expect(found);
    }
}

test "AnalysisEngine summary cache initialization" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    // Summary cache should be initialized
    try std.testing.expectEqual(@as(u32, 0), engine.getSummaryUseCount());

    // use_summaries should default to true
    try std.testing.expect(engine.use_summaries);

    // Can disable summaries
    engine.setUseSummaries(false);
    try std.testing.expect(!engine.use_summaries);
}

test "AnalysisEngine summary use count" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));
    cfg.entry = entry;
    cfg.exit = exit;
    try cfg.addEdge(entry, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    // Without any calls, summary use count should be 0
    try engine.run();
    try std.testing.expectEqual(@as(u32, 0), engine.getSummaryUseCount());
}
