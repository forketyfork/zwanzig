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
const TypeContext = @import("../type_context.zig").TypeContext;
const Config = @import("../config.zig").Config;
const base = @import("base.zig");
const EngineError = base.EngineError;
const default_max_inline_depth = base.default_max_inline_depth;
const default_max_worklist_steps = base.default_max_worklist_steps;
const Constraint = @import("constraints.zig").Constraint;
const FunctionSummary = @import("summary.zig").FunctionSummary;
const SummaryCache = @import("summary.zig").SummaryCache;
const ProgramPoint = @import("state.zig").ProgramPoint;
const ProgramState = @import("state.zig").ProgramState;
const LoopHeaderKey = @import("state.zig").LoopHeaderKey;
const ResourceState = @import("store.zig").ResourceState;
const VarResolver = @import("var_resolver.zig").VarResolver;
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
    /// Cache of scope-aware variable resolvers per function
    var_resolvers: std.AutoHashMap(AstNodeId, *VarResolver),
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
    /// Type context for type-aware analysis (optional, not owned).
    type_context: ?*TypeContext,
    /// Config for resource models (optional, not owned).
    config: ?*const Config,
    /// Scratch buffer for FQN construction
    fqn_buffer: [256]u8 = undefined,

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
            .var_resolvers = std.AutoHashMap(AstNodeId, *VarResolver).init(allocator),
            .inlined_call_count = 0,
            .summary_cache = SummaryCache.init(allocator),
            .use_summaries = true,
            .summary_use_count = 0,
            .build_metadata = null,
            .checker_name = null,
            .type_context = null,
            .config = null,
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
        var resolver_iter = self.var_resolvers.valueIterator();
        while (resolver_iter.next()) |resolver_ptr| {
            resolver_ptr.*.deinit();
            self.allocator.destroy(resolver_ptr.*);
        }
        self.var_resolvers.deinit();
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

    /// Set the maximum number of states per program point before dropping.
    pub fn setMaxStatesPerPoint(self: *AnalysisEngine, max: u32) void {
        self.graph.setMaxStatesPerPoint(max);
    }

    /// Set the checker name for logging purposes.
    pub fn setCheckerName(self: *AnalysisEngine, name: []const u8) void {
        self.checker_name = name;
    }

    /// Set the type context for type-aware analysis.
    pub fn setTypeContext(self: *AnalysisEngine, type_ctx: *TypeContext) void {
        self.type_context = type_ctx;
    }

    /// Set the config for resource models.
    pub fn setConfig(self: *AnalysisEngine, config: *const Config) void {
        self.config = config;
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
        if (result.caller_should_deinit) {
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

    const ResourceCallKind = enum {
        alloc,
        free,
        open,
        close,
    };

    const ResourceCall = struct {
        kind: ResourceCallKind,
        target_expr: ?u32,
        call_node: u32,
    };

    fn resolveResourceCall(self: *AnalysisEngine, expr_node: u32) ?ResourceCall {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        return self.resolveResourceCallFromExpr(tree, expr_node);
    }

    fn isDefinitelyNonAlloc(self: *AnalysisEngine, expr_node: u32) bool {
        const src = self.source orelse return false;
        const tree = src.ast() catch return false;
        return self.isDefinitelyNonAllocExpr(tree, expr_node);
    }

    fn resolveResourceCallFromExpr(self: *AnalysisEngine, tree: *const std.zig.Ast, expr_node: u32) ?ResourceCall {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return null;
        const tag = tags[expr_node];

        return switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => self.resolveResourceCallFromCall(tree, expr_node),
            .@"try" => self.resolveResourceCallFromExpr(tree, @intFromEnum(datas[expr_node].node)),
            .@"catch" => blk: {
                const pair = datas[expr_node].node_and_node;
                if (self.resolveResourceCallFromExpr(tree, @intFromEnum(pair[0]))) |call_info| {
                    break :blk call_info;
                }
                break :blk self.resolveResourceCallFromExpr(tree, @intFromEnum(pair[1]));
            },
            .unwrap_optional, .grouped_expression => self.resolveResourceCallFromExpr(tree, @intFromEnum(datas[expr_node].node_and_token[0])),
            .slice, .slice_open, .slice_sentinel => blk: {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse break :blk null;
                break :blk self.resolveResourceCallFromExpr(tree, @intFromEnum(slice.ast.sliced));
            },
            else => null,
        };
    }

    fn resolveResourceCallFromCall(self: *AnalysisEngine, tree: *const std.zig.Ast, call_ast_node: u32) ?ResourceCall {
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

        // Priority 1: Config-driven resource models
        if (self.config) |config| {
            // Get return type info if available
            var return_type_str: ?[]const u8 = null;
            if (self.type_context) |type_ctx| {
                if (type_ctx.getExpressionType(call_ast_node)) |ti| {
                    return_type_str = ti.type_str;
                }
            }

            // Extract receiver type from the base expression
            const receiver_type = self.getReceiverTypeName(tree, base_node);

            // Construct FQN from receiver.method
            const fqn = self.constructFqn(tree, base_node, field_name);

            // Match against config resource models
            if (config.matchResourceModel(field_name, receiver_type, return_type_str, fqn)) |model_kind| {
                const kind: ResourceCallKind = switch (model_kind) {
                    .alloc => .alloc,
                    .free => .free,
                    .open => .open,
                    .close => .close,
                };
                const target_expr: ?u32 = if (kind == .free or kind == .close) (first_arg orelse base_node) else null;
                return .{ .kind = kind, .target_expr = target_expr, .call_node = call_ast_node };
            }
        }

        // Priority 2: Built-in heuristics (allocator methods)
        if (self.isAllocatorBase(tree, base_node)) {
            if (std.mem.eql(u8, field_name, "alloc") or std.mem.eql(u8, field_name, "dupe")) {
                return .{ .kind = .alloc, .target_expr = null, .call_node = call_ast_node };
            }
            if (std.mem.eql(u8, field_name, "free")) {
                return .{ .kind = .free, .target_expr = first_arg, .call_node = call_ast_node };
            }
        }

        if (std.mem.eql(u8, field_name, "allocPrint")) {
            if (first_arg) |arg_node| {
                if (self.isAllocatorBase(tree, arg_node)) {
                    return .{ .kind = .alloc, .target_expr = null, .call_node = call_ast_node };
                }
            }
        }

        // Priority 3: Type-based open detection with strict type info.
        const type_status = self.classifyResourceReturningCall(call_ast_node);
        if (type_status == .resource) {
            return .{ .kind = .open, .target_expr = null, .call_node = call_ast_node };
        }

        // Priority 4: Name-based open detection with known base types (only when type info is missing).
        if (type_status == .unknown) {
            if ((std.mem.eql(u8, field_name, "open") or
                std.mem.eql(u8, field_name, "openFile") or
                std.mem.eql(u8, field_name, "openDir") or
                std.mem.eql(u8, field_name, "openIterableDir") or
                std.mem.eql(u8, field_name, "createFile")) and
                self.isKnownOpenBase(tree, base_node))
            {
                return .{ .kind = .open, .target_expr = null, .call_node = call_ast_node };
            }
        }

        if (std.mem.eql(u8, field_name, "close")) {
            const target_expr = first_arg orelse base_node;
            return .{ .kind = .close, .target_expr = target_expr, .call_node = call_ast_node };
        }
        return null;
    }

    const ResourceReturnStatus = enum {
        unknown,
        resource,
        non_resource,
    };

    /// Classify whether a call returns a known resource type.
    /// Uses strict type information and avoids name-only heuristics.
    fn classifyResourceReturningCall(self: *AnalysisEngine, call_ast_node: u32) ResourceReturnStatus {
        const type_ctx = self.type_context orelse return .unknown;
        if (type_ctx.getExpressionTypeStrict(call_ast_node)) |strict_info| {
            if (strict_info.type_str) |type_str| {
                if (std.mem.eql(u8, type_str, "std.fs.File") or
                    std.mem.eql(u8, type_str, "std.posix.fd_t") or
                    std.mem.eql(u8, type_str, "std.fs.Dir") or
                    std.mem.eql(u8, type_str, "std.fs.IterableDir"))
                {
                    return .resource;
                }
                return .non_resource;
            }

            return switch (strict_info.kind) {
                .int,
                .uint,
                .float,
                .bool_type,
                .void_type,
                .error_union,
                => .non_resource,
                else => .unknown,
            };
        }

        if (type_ctx.getExpressionType(call_ast_node)) |loose_info| {
            if (loose_info.type_str) |type_str| {
                if (std.mem.eql(u8, type_str, "std.fs.File") or
                    std.mem.eql(u8, type_str, "std.posix.fd_t") or
                    std.mem.eql(u8, type_str, "std.fs.Dir") or
                    std.mem.eql(u8, type_str, "std.fs.IterableDir"))
                {
                    return .resource;
                }
            }
        }

        return .unknown;
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

    fn isKnownOpenBase(self: *AnalysisEngine, tree: *const std.zig.Ast, base_node: u32) bool {
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
                return std.mem.eql(u8, base_name, "posix");
            },
            .field_access => {
                const field_access_data = datas[base_node].node_and_token;
                const base_expr = @intFromEnum(field_access_data[0]);
                const field_token = field_access_data[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return false;
                const field_name = tree.tokenSlice(field_token);
                if (!std.mem.eql(u8, field_name, "posix") and !std.mem.eql(u8, field_name, "fs")) return false;
                if (base_expr >= tags.len or tags[base_expr] != .identifier) return false;
                const base_token = main_tokens[base_expr];
                if (base_token >= token_tags.len or token_tags[base_token] != .identifier) return false;
                const base_name = tree.tokenSlice(base_token);
                return std.mem.eql(u8, base_name, "std");
            },
            else => return false,
        }
    }

    /// Get the type name of the receiver expression (for receiver_type matching).
    /// For an expression like `myPool.open()`, this returns the type of `myPool`.
    fn getReceiverTypeName(self: *AnalysisEngine, tree: *const std.zig.Ast, base_node: u32) ?[]const u8 {
        const tags = tree.nodes.items(.tag);

        if (base_node >= tags.len) return null;

        // If the base is an identifier, try to get its type from TypeContext
        if (tags[base_node] == .identifier) {
            if (self.type_context) |type_ctx| {
                if (type_ctx.getExpressionType(base_node)) |ti| {
                    return ti.type_str;
                }
            }
        }

        // For field access, try to get the final field type
        if (tags[base_node] == .field_access) {
            if (self.type_context) |type_ctx| {
                if (type_ctx.getExpressionType(base_node)) |ti| {
                    return ti.type_str;
                }
            }
        }

        return null;
    }

    /// Construct a fully qualified name from a method call.
    /// For `my.pool.open()`, this returns "my.pool.open".
    /// Uses a static buffer, so the result is only valid until the next call.
    fn constructFqn(self: *AnalysisEngine, tree: *const std.zig.Ast, base_node: u32, method_name: []const u8) ?[]const u8 {
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
            if (!self.appendFqnPart(parts[idx - 1], &pos)) return null;
            if (idx > 1) {
                if (!self.appendFqnSeparator(&pos)) return null;
            }
        }

        if (!self.appendFqnSeparator(&pos)) return null;
        if (!self.appendFqnPart(method_name, &pos)) return null;

        return self.fqn_buffer[0..pos];
    }

    fn appendFqnPart(self: *AnalysisEngine, part: []const u8, pos: *usize) bool {
        if (part.len == 0) return false;
        if (pos.* + part.len > self.fqn_buffer.len) return false;
        std.mem.copyForwards(u8, self.fqn_buffer[pos.* .. pos.* + part.len], part);
        pos.* += part.len;
        return true;
    }

    fn appendFqnSeparator(self: *AnalysisEngine, pos: *usize) bool {
        if (pos.* >= self.fqn_buffer.len) return false;
        self.fqn_buffer[pos.*] = '.';
        pos.* += 1;
        return true;
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

    fn resolveVarIdFromIdentifier(self: *AnalysisEngine, identifier_node: u32, current_cfg: *const Cfg) ?ids.VarId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        if (identifier_node >= tags.len) return null;
        if (tags[identifier_node] != .identifier) return null;
        const token = main_tokens[identifier_node];
        if (token >= token_tags.len or token_tags[token] != .identifier) return null;

        if (current_cfg.fn_ast_node) |fn_node| {
            if (self.getOrBuildVarResolver(fn_node)) |resolver| {
                if (resolver.resolve(identifier_node)) |var_id| {
                    return var_id;
                }
            }
        }

        return ids.varId(token);
    }

    fn resolveVarIdFromExpr(self: *AnalysisEngine, expr_node: u32, current_cfg: *const Cfg) ?ids.VarId {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return null;
        return switch (tags[expr_node]) {
            .identifier => self.resolveVarIdFromIdentifier(expr_node, current_cfg),
            .grouped_expression, .unwrap_optional => blk: {
                const data = datas[expr_node].node_and_token;
                break :blk self.resolveVarIdFromExpr(@intFromEnum(data[0]), current_cfg);
            },
            .slice, .slice_open, .slice_sentinel => blk: {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse break :blk null;
                break :blk self.resolveVarIdFromExpr(@intFromEnum(slice.ast.sliced), current_cfg);
            },
            .array_access => blk: {
                const pair = datas[expr_node].node_and_node;
                break :blk self.resolveVarIdFromExpr(@intFromEnum(pair[0]), current_cfg);
            },
            .address_of, .deref, .@"try" => blk: {
                const child = datas[expr_node].node;
                break :blk self.resolveVarIdFromExpr(@intFromEnum(child), current_cfg);
            },
            .@"catch" => blk: {
                const pair = datas[expr_node].node_and_node;
                if (self.resolveVarIdFromExpr(@intFromEnum(pair[0]), current_cfg)) |var_id| {
                    break :blk var_id;
                }
                break :blk self.resolveVarIdFromExpr(@intFromEnum(pair[1]), current_cfg);
            },
            else => null,
        };
    }

    fn getOrBuildVarResolver(self: *AnalysisEngine, fn_node: AstNodeId) ?*VarResolver {
        if (self.var_resolvers.get(fn_node)) |resolver| return resolver;
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;

        const resolver_ptr = self.allocator.create(VarResolver) catch return null;
        resolver_ptr.* = VarResolver.init(self.allocator, tree, fn_node) catch {
            self.allocator.destroy(resolver_ptr);
            return null;
        };

        self.var_resolvers.put(fn_node, resolver_ptr) catch {
            resolver_ptr.deinit();
            self.allocator.destroy(resolver_ptr);
            return null;
        };
        return resolver_ptr;
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
        if (self.resolveResourceCallFromExpr(tree, expr_node)) |call_info| {
            return call_info.kind != .alloc and call_info.kind != .open;
        }

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
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
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

    fn checkUseAfterFreeInCall(self: *AnalysisEngine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        if (call_node >= tags.len) return;

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tags[call_node]) {
            .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
            else => null,
        } orelse return;

        for (full_call.ast.params) |param| {
            try self.checkUseAfterFreeInExpr(state, @intFromEnum(param), current_cfg);
        }
    }

    fn checkUseAfterFreeInExpr(self: *AnalysisEngine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);

        if (expr_node >= tags.len) return;

        switch (tags[expr_node]) {
            .identifier => {
                if (self.resolveVarIdFromIdentifier(expr_node, current_cfg)) |var_id| {
                    const token = main_tokens[expr_node];
                    try state.trackUse(var_id, token);
                }
            },
            .grouped_expression, .unwrap_optional => {
                const data = datas[expr_node].node_and_token;
                try self.checkUseAfterFreeInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                try self.checkUseAfterFreeInExpr(state, @intFromEnum(slice.ast.sliced), current_cfg);
            },
            .array_access => {
                const pair = datas[expr_node].node_and_node;
                try self.checkUseAfterFreeInExpr(state, @intFromEnum(pair[0]), current_cfg);
            },
            .field_access => {
                const data = datas[expr_node].node_and_token;
                try self.checkUseAfterFreeInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                try self.checkUseAfterFreeInCall(state, expr_node, current_cfg);
            },
            else => {},
        }
    }

    fn markEscapedInExpr(self: *AnalysisEngine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        if (expr_node >= tags.len) return;

        switch (tags[expr_node]) {
            .identifier => {
                if (self.resolveVarIdFromIdentifier(expr_node, current_cfg)) |var_id| {
                    try state.trackEscapeOwned(var_id);
                    state.trackEscape(var_id);
                    const token = main_tokens[expr_node];
                    if (ids.varIndex(var_id) == token and token < token_tags.len and token_tags[token] == .identifier) {
                        const name = tree.tokenSlice(token);
                        try state.trackEscapeByName(tree, name);
                    }
                }
            },
            .grouped_expression, .unwrap_optional => {
                const data = datas[expr_node].node_and_token;
                try self.markEscapedInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                try self.markEscapedInExpr(state, @intFromEnum(slice.ast.sliced), current_cfg);
            },
            .array_access => {
                const pair = datas[expr_node].node_and_node;
                try self.markEscapedInExpr(state, @intFromEnum(pair[0]), current_cfg);
            },
            .field_access => {
                const data = datas[expr_node].node_and_token;
                try self.markEscapedInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .address_of, .deref, .@"try" => {
                const child = datas[expr_node].node;
                try self.markEscapedInExpr(state, @intFromEnum(child), current_cfg);
            },
            .@"catch" => {
                const pair = datas[expr_node].node_and_node;
                try self.markEscapedInExpr(state, @intFromEnum(pair[0]), current_cfg);
                try self.markEscapedInExpr(state, @intFromEnum(pair[1]), current_cfg);
            },
            .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return;
                for (struct_init.ast.fields) |field| {
                    try self.markEscapedInExpr(state, @intFromEnum(field), current_cfg);
                }
            },
            .container_field, .container_field_init, .container_field_align => {
                const field = tree.fullContainerField(@enumFromInt(expr_node)) orelse return;
                if (field.ast.value_expr.unwrap()) |value_expr| {
                    try self.markEscapedInExpr(state, @intFromEnum(value_expr), current_cfg);
                } else if (field.ast.tuple_like) {
                    if (field.ast.type_expr.unwrap()) |value_expr| {
                        try self.markEscapedInExpr(state, @intFromEnum(value_expr), current_cfg);
                    }
                }
            },
            .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return;
                for (array_init.ast.elements) |elem| {
                    try self.markEscapedInExpr(state, @intFromEnum(elem), current_cfg);
                }
            },
            else => {},
        }
    }

    fn trackEscapesFromCall(self: *AnalysisEngine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        if (call_node >= tags.len) return;

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tags[call_node]) {
            .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
            else => null,
        } orelse return;

        const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= tags.len) return;

        const fn_name = blk: {
            switch (tags[callee_node]) {
                .field_access => {
                    const field_access_data = datas[callee_node].node_and_token;
                    const field_token = field_access_data[1];
                    if (field_token >= token_tags.len or token_tags[field_token] != .identifier) break :blk null;
                    break :blk tree.tokenSlice(field_token);
                },
                .identifier => {
                    const fn_token = main_tokens[callee_node];
                    if (fn_token >= token_tags.len or token_tags[fn_token] != .identifier) break :blk null;
                    break :blk tree.tokenSlice(fn_token);
                },
                else => break :blk null,
            }
        } orelse return;

        if (std.mem.eql(u8, fn_name, "append") or
            std.mem.eql(u8, fn_name, "appendAssumeCapacity") or
            std.mem.eql(u8, fn_name, "appendSlice") or
            std.mem.eql(u8, fn_name, "appendSliceAssumeCapacity") or
            std.mem.eql(u8, fn_name, "insert") or
            std.mem.eql(u8, fn_name, "insertAssumeCapacity"))
        {
            if (full_call.ast.params.len == 0) return;
            const item_node = @intFromEnum(full_call.ast.params[full_call.ast.params.len - 1]);
            self.markEscapedInExpr(state, item_node, current_cfg) catch return;
            return;
        }

        if (std.mem.eql(u8, fn_name, "put") or
            std.mem.eql(u8, fn_name, "putNoClobber") or
            std.mem.eql(u8, fn_name, "putAssumeCapacity") or
            std.mem.eql(u8, fn_name, "putNoClobberAssumeCapacity"))
        {
            if (full_call.ast.params.len >= 1) {
                const key_node = @intFromEnum(full_call.ast.params[0]);
                self.markEscapedInExpr(state, key_node, current_cfg) catch return;
            }
            if (full_call.ast.params.len >= 2) {
                const value_node = @intFromEnum(full_call.ast.params[1]);
                self.markEscapedInExpr(state, value_node, current_cfg) catch return;
            }
            return;
        }

        if (std.mem.startsWith(u8, fn_name, "init") or
            std.mem.startsWith(u8, fn_name, "setup") or
            std.mem.startsWith(u8, fn_name, "set") or
            std.mem.startsWith(u8, fn_name, "store") or
            std.mem.startsWith(u8, fn_name, "register") or
            std.mem.startsWith(u8, fn_name, "add") or
            std.mem.startsWith(u8, fn_name, "push"))
        {
            for (full_call.ast.params) |param| {
                const param_node = @intFromEnum(param);
                self.markEscapedInExpr(state, param_node, current_cfg) catch return;
            }
        }
    }

    /// Record ownership when passing resources to functions that take a pointer as first argument.
    /// This handles patterns like `initCache(cache, entries, ...)` where entries becomes owned by cache.
    fn recordOwnershipFromCall(self: *AnalysisEngine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        if (call_node >= tags.len) return;

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tags[call_node]) {
            .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
            else => null,
        } orelse return;

        if (full_call.ast.params.len < 2) return;

        const first_arg_node = @intFromEnum(full_call.ast.params[0]);
        const first_arg_var = self.resolveVarIdFromExpr(first_arg_node, current_cfg) orelse return;

        const first_arg_is_ptr = blk: {
            if (self.type_context) |type_ctx| {
                const token = ids.varIndex(first_arg_var);
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const name = tree.tokenSlice(token);
                    if (type_ctx.getDeclType(name)) |type_info| {
                        if (type_info.kind == .pointer) break :blk true;
                    }
                }
            }
            if (first_arg_node < tags.len and tags[first_arg_node] == .address_of) {
                break :blk true;
            }
            if (state.getRegionState(first_arg_var)) |rs| {
                if (rs == .allocated) break :blk true;
            }
            break :blk false;
        };

        const callee_is_init_fn = blk: {
            const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
            if (callee_node >= tags.len) break :blk false;
            const fn_name_token = switch (tags[callee_node]) {
                .identifier => main_tokens[callee_node],
                .field_access => datas[callee_node].node_and_token[1],
                else => break :blk false,
            };
            if (fn_name_token >= token_tags.len or token_tags[fn_name_token] != .identifier) break :blk false;
            const fn_name = tree.tokenSlice(fn_name_token);
            break :blk std.mem.startsWith(u8, fn_name, "init");
        };

        for (full_call.ast.params[1..]) |param| {
            const param_node = @intFromEnum(param);
            if (self.resolveVarIdFromExpr(param_node, current_cfg)) |param_var| {
                if (state.getRegionState(param_var)) |rs| {
                    if (rs == .allocated or rs == .open) {
                        if (first_arg_is_ptr or callee_is_init_fn) {
                            try state.trackOwnership(param_var, first_arg_var);
                            try state.trackEscapeOwned(param_var);
                            state.trackEscape(param_var);
                        }
                    }
                }
            }
        }
    }

    fn trackEscapesInExpr(self: *AnalysisEngine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return;

        switch (tags[expr_node]) {
            .call, .call_comma, .call_one, .call_one_comma => {
                self.trackEscapesFromCall(state, expr_node, current_cfg);
            },
            .grouped_expression, .unwrap_optional => {
                const data = datas[expr_node].node_and_token;
                self.trackEscapesInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                self.trackEscapesInExpr(state, @intFromEnum(slice.ast.sliced), current_cfg);
            },
            .array_access => {
                const pair = datas[expr_node].node_and_node;
                self.trackEscapesInExpr(state, @intFromEnum(pair[0]), current_cfg);
            },
            .field_access => {
                const data = datas[expr_node].node_and_token;
                self.trackEscapesInExpr(state, @intFromEnum(data[0]), current_cfg);
            },
            .address_of, .deref, .@"try" => {
                const child = datas[expr_node].node;
                self.trackEscapesInExpr(state, @intFromEnum(child), current_cfg);
            },
            .@"catch" => {
                const pair = datas[expr_node].node_and_node;
                self.trackEscapesInExpr(state, @intFromEnum(pair[0]), current_cfg);
                self.trackEscapesInExpr(state, @intFromEnum(pair[1]), current_cfg);
            },
            .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return;
                for (struct_init.ast.fields) |field| {
                    self.trackEscapesInExpr(state, @intFromEnum(field), current_cfg);
                }
            },
            .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return;
                for (array_init.ast.elements) |elem| {
                    self.trackEscapesInExpr(state, @intFromEnum(elem), current_cfg);
                }
            },
            else => {},
        }
    }

    fn recordOwnershipFromExpr(
        self: *AnalysisEngine,
        state: *ProgramState,
        expr_node: u32,
        container_var: ids.VarId,
        current_cfg: *const Cfg,
    ) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return;

        switch (tags[expr_node]) {
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => try self.recordOwnershipFromStructInit(state, expr_node, container_var, current_cfg),
            .grouped_expression, .unwrap_optional => {
                const data = datas[expr_node].node_and_token;
                try self.recordOwnershipFromExpr(state, @intFromEnum(data[0]), container_var, current_cfg);
            },
            .@"try" => try self.recordOwnershipFromExpr(state, @intFromEnum(datas[expr_node].node), container_var, current_cfg),
            .@"catch" => {
                const pair = datas[expr_node].node_and_node;
                try self.recordOwnershipFromExpr(state, @intFromEnum(pair[0]), container_var, current_cfg);
                try self.recordOwnershipFromExpr(state, @intFromEnum(pair[1]), container_var, current_cfg);
            },
            else => {},
        }
    }

    fn recordOwnershipFromStructInit(
        self: *AnalysisEngine,
        state: *ProgramState,
        struct_node: u32,
        container_var: ids.VarId,
        current_cfg: *const Cfg,
    ) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        if (struct_node >= tags.len) return;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = tree.fullStructInit(&buf, @enumFromInt(struct_node)) orelse return;

        for (struct_init.ast.fields) |field| {
            const field_idx = @intFromEnum(field);
            if (field_idx >= tags.len) continue;

            switch (tags[field_idx]) {
                .container_field, .container_field_init, .container_field_align => {
                    const full_field = tree.fullContainerField(@enumFromInt(field_idx)) orelse continue;
                    if (full_field.ast.value_expr.unwrap()) |value_expr| {
                        if (self.resolveVarIdFromExpr(@intFromEnum(value_expr), current_cfg)) |var_id| {
                            try state.trackOwnership(var_id, container_var);
                        }
                    } else if (full_field.ast.tuple_like) {
                        if (full_field.ast.type_expr.unwrap()) |value_expr| {
                            if (self.resolveVarIdFromExpr(@intFromEnum(value_expr), current_cfg)) |var_id| {
                                try state.trackOwnership(var_id, container_var);
                            }
                        }
                    }
                },
                else => {
                    if (self.resolveVarIdFromExpr(field_idx, current_cfg)) |var_id| {
                        try state.trackOwnership(var_id, container_var);
                    }
                },
            }
        }
    }

    fn recordOwnershipFromFieldAssign(
        self: *AnalysisEngine,
        state: *ProgramState,
        lhs_node: u32,
        rhs_node: u32,
        current_cfg: *const Cfg,
    ) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        if (lhs_node >= tags.len or tags[lhs_node] != .field_access) return;

        const field_access_data = datas[lhs_node].node_and_token;
        const base_node = @intFromEnum(field_access_data[0]);
        const container_var = self.resolveVarIdFromExpr(base_node, current_cfg) orelse return;
        const resource_var = self.resolveVarIdFromExpr(rhs_node, current_cfg) orelse return;
        try state.trackOwnership(resource_var, container_var);

        const base_escapes = blk: {
            if (base_node < tags.len and tags[base_node] == .identifier) {
                const token = main_tokens[base_node];
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const name = tree.tokenSlice(token);
                    if (std.mem.eql(u8, name, "self")) {
                        break :blk true;
                    }
                }
            }
            if (self.type_context) |type_ctx| {
                const token = ids.varIndex(container_var);
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const var_name = tree.tokenSlice(token);
                    if (type_ctx.getDeclType(var_name)) |type_info| {
                        if (type_info.kind == .pointer) {
                            break :blk true;
                        }
                    }
                }
            }
            if (state.getRegionState(container_var) == null) {
                break :blk true;
            }
            break :blk false;
        };

        if (base_escapes) {
            try state.trackEscapeOwned(resource_var);
            state.trackEscape(resource_var);
        }
    }

    fn bindPayloadAlias(self: *AnalysisEngine, state: *ProgramState, payload_token: u32, expr_node: u32, current_cfg: *const Cfg) EngineError!void {
        const var_id = ids.varId(payload_token);
        state.resetRegion(var_id);
        try state.setVar(var_id, .unknown);
        if (self.resolveVarIdFromExpr(expr_node, current_cfg)) |alias_target| {
            if (alias_target != var_id) {
                try state.trackAlias(var_id, alias_target);
            }
        }
    }

    fn bindPayloadUnknown(self: *AnalysisEngine, state: *ProgramState, payload_token: u32) EngineError!void {
        _ = self;
        const var_id = ids.varId(payload_token);
        state.resetRegion(var_id);
        try state.setVar(var_id, .unknown);
    }

    fn bindForPayloads(self: *AnalysisEngine, state: *ProgramState, payload_token: u32) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const token_tags = tree.tokens.items(.tag);

        var idx = payload_token;
        if (idx < token_tags.len and token_tags[idx] == .pipe) {
            idx += 1;
        }

        while (idx < token_tags.len) : (idx += 1) {
            const tag = token_tags[idx];
            if (tag == .pipe) break;
            if (tag == .asterisk) {
                idx += 1;
                if (idx < token_tags.len and token_tags[idx] == .identifier) {
                    try self.bindPayloadUnknown(state, idx);
                }
            } else if (tag == .identifier) {
                try self.bindPayloadUnknown(state, idx);
            }
        }
    }

    fn applyPayloadBindings(self: *AnalysisEngine, cfg_node: *const CfgNode, edge_kind: EdgeKind, state: *ProgramState, current_cfg: *const Cfg) EngineError!void {
        const ast_node = cfg_node.ir_node.ast_node orelse return;
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        if (ast_node >= tags.len) return;

        switch (tags[ast_node]) {
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(ast_node)) orelse return;
                if (edge_kind == .branch_true) {
                    if (full_if.payload_token) |tok| {
                        try self.bindPayloadAlias(state, tok, @intFromEnum(full_if.ast.cond_expr), current_cfg);
                    }
                } else if (edge_kind == .branch_false) {
                    if (full_if.error_token) |tok| {
                        try self.bindPayloadUnknown(state, tok);
                    }
                }
            },
            .@"while", .while_simple, .while_cont => {
                const full_while = tree.fullWhile(@enumFromInt(ast_node)) orelse return;
                if (edge_kind == .branch_true) {
                    if (full_while.payload_token) |tok| {
                        try self.bindPayloadAlias(state, tok, @intFromEnum(full_while.ast.cond_expr), current_cfg);
                    }
                }
            },
            .@"for", .for_simple => {
                if (edge_kind != .branch_true) return;
                const full_for = tree.fullFor(@enumFromInt(ast_node)) orelse return;
                try self.bindForPayloads(state, full_for.payload_token);
            },
            else => {},
        }
    }

    fn escapeReturnedVars(self: *AnalysisEngine, state: *ProgramState, fn_node: AstNodeId, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const fn_index = ids.astIndex(fn_node);
        if (fn_index >= tags.len or tags[fn_index] != .fn_decl) return;
        const fn_data = tree.nodes.items(.data)[fn_index];
        const body_node = @intFromEnum(fn_data.node_and_node[1]);
        if (body_node == 0) return;
        try self.escapeReturnedVarsInNode(state, body_node, current_cfg, tree);
    }

    fn escapeReturnedVarsInNode(
        self: *AnalysisEngine,
        state: *ProgramState,
        node: u32,
        current_cfg: *const Cfg,
        tree: *const std.zig.Ast,
    ) EngineError!void {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (node == 0 or node >= tags.len) return;

        switch (tags[node]) {
            .@"return" => {
                if (datas[node].opt_node.unwrap()) |ret_expr| {
                    try self.markEscapedInExpr(state, @intFromEnum(ret_expr), current_cfg);
                }
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var statements: []const u32 = &.{};
                var scratch_buf: [2]u32 = undefined;

                switch (tags[node]) {
                    .block, .block_semicolon => {
                        const extra_range = datas[node].extra_range;
                        const start = @intFromEnum(extra_range.start);
                        const end = @intFromEnum(extra_range.end);
                        statements = tree.extra_data[start..end];
                    },
                    .block_two, .block_two_semicolon => {
                        const opt_nodes = datas[node].opt_node_and_opt_node;
                        var count: usize = 0;
                        if (opt_nodes[0].unwrap()) |n| {
                            scratch_buf[count] = @intFromEnum(n);
                            count += 1;
                        }
                        if (opt_nodes[1].unwrap()) |n| {
                            scratch_buf[count] = @intFromEnum(n);
                            count += 1;
                        }
                        statements = scratch_buf[0..count];
                    },
                    else => {},
                }

                for (statements) |stmt| {
                    try self.escapeReturnedVarsInNode(state, stmt, current_cfg, tree);
                }
            },
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(node)) orelse return;
                try self.escapeReturnedVarsInNode(state, @intFromEnum(full_if.ast.then_expr), current_cfg, tree);
                if (full_if.ast.else_expr.unwrap()) |else_node| {
                    try self.escapeReturnedVarsInNode(state, @intFromEnum(else_node), current_cfg, tree);
                }
            },
            .@"while", .while_simple, .while_cont => {
                const full_while = tree.fullWhile(@enumFromInt(node)) orelse return;
                try self.escapeReturnedVarsInNode(state, @intFromEnum(full_while.ast.then_expr), current_cfg, tree);
                if (full_while.ast.else_expr.unwrap()) |else_node| {
                    try self.escapeReturnedVarsInNode(state, @intFromEnum(else_node), current_cfg, tree);
                }
                if (full_while.ast.cont_expr.unwrap()) |cont_node| {
                    try self.escapeReturnedVarsInNode(state, @intFromEnum(cont_node), current_cfg, tree);
                }
            },
            .@"for", .for_simple => {
                const full_for = tree.fullFor(@enumFromInt(node)) orelse return;
                try self.escapeReturnedVarsInNode(state, @intFromEnum(full_for.ast.then_expr), current_cfg, tree);
                if (full_for.ast.else_expr.unwrap()) |else_node| {
                    try self.escapeReturnedVarsInNode(state, @intFromEnum(else_node), current_cfg, tree);
                }
            },
            .@"switch", .switch_comma => {
                const full_switch = tree.switchFull(@enumFromInt(node));
                for (full_switch.ast.cases) |case_node| {
                    const full_case = tree.fullSwitchCase(case_node) orelse continue;
                    try self.escapeReturnedVarsInNode(state, @intFromEnum(full_case.ast.target_expr), current_cfg, tree);
                }
            },
            else => {},
        }
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
                        // Track escapes BEFORE inlining, since inlining will skip normal processing
                        if (node.ir_node.ast_node) |ast_node| {
                            self.trackEscapesFromCall(&state_copy, ast_node, current_cfg);
                            try self.recordOwnershipFromCall(&state_copy, ast_node, current_cfg);
                        }

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
                if (result.caller_should_deinit) {
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
                    self.extractBranchConstraint(cfg_node.?, current_cfg)
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

                        if (cfg_node) |node| {
                            try self.applyPayloadBindings(node, edge.kind, &succ_state, current_cfg);
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

                        // Determine if widening should be applied at this loop header.
                        // Widening triggers only on loop_back edges into loop_header pre-states.
                        const widening_options = blk: {
                            if (edge.kind == .loop_back) {
                                // Check if successor is a loop_header node
                                if (current_cfg.getNode(edge.to)) |succ_cfg_node| {
                                    if (succ_cfg_node.ir_node.tag == .loop_header) {
                                        // succ_point is already a pre-state (from ProgramPoint.initPre above)
                                        const header_key = LoopHeaderKey.init(succ_point, &succ_state);
                                        break :blk ExplodedGraph.WideningOptions{
                                            .widen_at_header = true,
                                            .header_key = header_key,
                                        };
                                    }
                                }
                            }
                            break :blk ExplodedGraph.WideningOptions{};
                        };

                        const result = try self.graph.getOrCreateNodeWithWidening(succ_point, &succ_state, widening_options);
                        if (result.caller_should_deinit) {
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
                        if (result.caller_should_deinit) {
                            summary_state.deinit();
                        }
                        if (result.is_new) {
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
        if (result.caller_should_deinit) {
            inline_state.deinit();
        }
        if (result.is_new) {
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
        if (result.caller_should_deinit) {
            return_state.deinit();
        }
        if (result.is_new) {
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
    fn extractBranchConstraint(self: *AnalysisEngine, cfg_node: *const CfgNode, current_cfg: *const Cfg) ?Constraint {
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
                (self.resolveVarIdFromExpr(var_id, current_cfg) orelse ids.varId(var_id))
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
                    new_state.resetRegion(var_id);
                    try new_state.setVar(var_id, .unknown);
                    if (self.resolveVarDeclInitNode(ast_node)) |init_node| {
                        if (self.resolveResourceCall(init_node)) |call_info| {
                            switch (call_info.kind) {
                                .alloc => try new_state.trackAllocation(var_id),
                                .open => try new_state.trackOpen(var_id),
                                else => {},
                            }
                        } else if (self.resolveVarIdFromExpr(init_node, current_cfg)) |alias_target| {
                            if (alias_target != var_id) {
                                try new_state.trackAlias(var_id, alias_target);
                            }
                        } else if (self.isDefinitelyNonAlloc(init_node)) {
                            try new_state.trackNonAllocation(var_id);
                        }
                        try self.recordOwnershipFromExpr(&new_state, init_node, var_id, current_cfg);
                        try self.checkUseAfterFreeInExpr(&new_state, init_node, current_cfg);
                    }
                }
            },
            .assign => {
                // For assignments, use the LHS identifier node as the key
                // operand_node contains the LHS, operand2_node contains the RHS
                if (ir_node.operand_node) |lhs_node| {
                    var lhs_is_identifier = false;
                    if (self.source) |src| {
                        if (src.ast() catch null) |tree| {
                            const tags = tree.nodes.items(.tag);
                            lhs_is_identifier = lhs_node < tags.len and tags[lhs_node] == .identifier;
                        }
                    }

                    if (lhs_is_identifier) {
                        // For now, set to unknown. Future enhancement: evaluate RHS literals
                        const var_id = self.resolveVarIdFromIdentifier(lhs_node, current_cfg) orelse ids.varId(lhs_node);
                        new_state.resetRegion(var_id);
                        try new_state.setVar(var_id, .unknown);
                        if (ir_node.operand2_node) |rhs_node| {
                            if (self.resolveResourceCall(rhs_node)) |call_info| {
                                switch (call_info.kind) {
                                    .alloc => try new_state.trackAllocation(var_id),
                                    .open => try new_state.trackOpen(var_id),
                                    else => {},
                                }
                            } else if (self.resolveVarIdFromExpr(rhs_node, current_cfg)) |alias_target| {
                                if (alias_target != var_id) {
                                    try new_state.trackAlias(var_id, alias_target);
                                }
                            } else if (self.isDefinitelyNonAlloc(rhs_node)) {
                                try new_state.trackNonAllocation(var_id);
                            }
                            try self.recordOwnershipFromExpr(&new_state, rhs_node, var_id, current_cfg);
                            try self.checkUseAfterFreeInExpr(&new_state, rhs_node, current_cfg);
                        }
                    } else if (ir_node.operand2_node) |rhs_node| {
                        try self.checkUseAfterFreeInExpr(&new_state, rhs_node, current_cfg);
                        try self.markEscapedInExpr(&new_state, rhs_node, current_cfg);
                        try self.recordOwnershipFromFieldAssign(&new_state, lhs_node, rhs_node, current_cfg);
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
                    if (self.resolveResourceCall(ast_node)) |call_info| {
                        switch (call_info.kind) {
                            .free => {
                                if (call_info.target_expr) |arg_node| {
                                    if (self.resolveVarIdFromExpr(arg_node, current_cfg)) |var_id| {
                                        const call_token = self.resolveCallToken(call_info.call_node);
                                        try new_state.trackFree(var_id, call_token);
                                    }
                                }
                            },
                            .close => {
                                if (call_info.target_expr) |arg_node| {
                                    if (self.resolveVarIdFromExpr(arg_node, current_cfg)) |var_id| {
                                        const call_token = self.resolveCallToken(call_info.call_node);
                                        try new_state.trackClose(var_id, call_token);
                                    }
                                }
                            },
                            else => {},
                        }
                        if (call_info.kind != .free and call_info.kind != .close) {
                            try self.checkUseAfterFreeInCall(&new_state, ast_node, current_cfg);
                        }
                    } else {
                        try self.checkUseAfterFreeInCall(&new_state, ast_node, current_cfg);
                    }
                    self.trackEscapesFromCall(&new_state, ast_node, current_cfg);
                    try self.recordOwnershipFromCall(&new_state, ast_node, current_cfg);
                }
            },
            .defer_stmt => {
                if (ir_node.ast_node) |ast_node| {
                    try self.applyDeferredReleases(&new_state, ast_node, current_cfg);
                }
            },
            .errdefer_stmt => {
                if (ir_node.ast_node) |ast_node| {
                    try self.applyErrdeferredReleases(&new_state, ast_node, current_cfg);
                }
            },
            .ret => {
                if (ir_node.ast_node) |ast_node| {
                    if (self.source) |src| {
                        if (src.ast() catch null) |tree| {
                            const data = tree.nodes.items(.data);
                            const tags = tree.nodes.items(.tag);
                            if (ast_node < data.len) {
                                if (data[ast_node].opt_node.unwrap()) |ret_expr| {
                                    const ret_expr_idx = @intFromEnum(ret_expr);
                                    try self.checkUseAfterFreeInExpr(&new_state, ret_expr_idx, current_cfg);

                                    // Fast path: literal error value (e.g., return error.Foo)
                                    if (ret_expr_idx < tags.len and tags[ret_expr_idx] == .error_value) {
                                        new_state.setErrorState(.error_active);
                                    } else if (self.type_context) |type_ctx| {
                                        // Type-based check: return expression is an error union
                                        // This handles cases like `return err;` or `return someFn();`
                                        if (type_ctx.getExpressionTypeStrict(ret_expr_idx)) |ti| {
                                            if (ti.kind == .error_union) {
                                                new_state.setErrorState(.error_active);
                                            }
                                        }
                                    }

                                    if (self.resolveVarIdFromExpr(ret_expr_idx, current_cfg)) |var_id| {
                                        try new_state.trackEscapeOwned(var_id);
                                        new_state.trackEscape(var_id);
                                    }
                                    try self.markEscapedInExpr(&new_state, ret_expr_idx, current_cfg);
                                }
                            }
                        }
                    }
                }
            },
            .try_expr, .catch_expr => {
                if (ir_node.ast_node) |ast_node| {
                    try self.checkUseAfterFreeInExpr(&new_state, ast_node, current_cfg);
                    self.trackEscapesInExpr(&new_state, ast_node, current_cfg);
                }
            },
            .expr => {
                if (ir_node.ast_node) |ast_node| {
                    try self.checkUseAfterFreeInExpr(&new_state, ast_node, current_cfg);
                    self.trackEscapesInExpr(&new_state, ast_node, current_cfg);
                }
            },
            .fn_exit => {
                if (current_cfg.fn_ast_node) |fn_node| {
                    try self.escapeReturnedVars(&new_state, fn_node, current_cfg);
                }
                if (!new_state.isErrorPath()) {
                    try new_state.trackLeaks();
                }
            },
            else => {},
        }

        return new_state;
    }

    fn applyDeferredReleases(self: *AnalysisEngine, state: *ProgramState, defer_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const data = tree.nodes.items(.data);
        if (defer_node >= data.len) return;
        const body_node = @intFromEnum(data[defer_node].node);
        try self.scanDeferredBody(state, body_node, current_cfg, false);
    }

    fn applyErrdeferredReleases(self: *AnalysisEngine, state: *ProgramState, defer_node: u32, current_cfg: *const Cfg) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const data = tree.nodes.items(.data);
        if (defer_node >= data.len) return;
        const body_node = @intFromEnum(data[defer_node].opt_token_and_node[1]);
        if (body_node == 0) return;
        try self.scanDeferredBody(state, body_node, current_cfg, true);
    }

    fn scanDeferredBody(self: *AnalysisEngine, state: *ProgramState, node: u32, current_cfg: *const Cfg, error_only: bool) EngineError!void {
        const src = self.source orelse return;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (node == 0 or node >= tags.len) return;

        switch (tags[node]) {
            .call, .call_comma, .call_one, .call_one_comma => {
                if (self.resolveResourceCallFromExpr(tree, node)) |call_info| {
                    const call_token = self.resolveCallToken(call_info.call_node);
                    switch (call_info.kind) {
                        .free => {
                            if (call_info.target_expr) |arg_node| {
                                if (self.resolveVarIdFromExpr(arg_node, current_cfg)) |var_id| {
                                    if (error_only) {
                                        try state.trackErrdeferredFree(var_id);
                                    } else {
                                        try state.trackDeferredFree(var_id, call_token);
                                    }
                                }
                            }
                        },
                        .close => {
                            if (call_info.target_expr) |arg_node| {
                                if (self.resolveVarIdFromExpr(arg_node, current_cfg)) |var_id| {
                                    if (error_only) {
                                        try state.trackErrdeferredClose(var_id);
                                    } else {
                                        try state.trackDeferredClose(var_id, call_token);
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var statements: []const u32 = &.{};
                var scratch_buf: [2]u32 = undefined;

                switch (tags[node]) {
                    .block, .block_semicolon => {
                        const extra_range = datas[node].extra_range;
                        const start = @intFromEnum(extra_range.start);
                        const end = @intFromEnum(extra_range.end);
                        statements = tree.extra_data[start..end];
                    },
                    .block_two, .block_two_semicolon => {
                        const opt_nodes = datas[node].opt_node_and_opt_node;
                        var count: usize = 0;
                        if (opt_nodes[0].unwrap()) |n| {
                            scratch_buf[count] = @intFromEnum(n);
                            count += 1;
                        }
                        if (opt_nodes[1].unwrap()) |n| {
                            scratch_buf[count] = @intFromEnum(n);
                            count += 1;
                        }
                        statements = scratch_buf[0..count];
                    },
                    else => {},
                }

                for (statements) |stmt| {
                    try self.scanDeferredBody(state, stmt, current_cfg, error_only);
                }
            },
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(node)) orelse return;
                if (full_if.payload_token) |tok| {
                    try self.bindPayloadAlias(state, tok, @intFromEnum(full_if.ast.cond_expr), current_cfg);
                    try self.scanDeferredBody(state, @intFromEnum(full_if.ast.then_expr), current_cfg, error_only);
                    state.resetRegion(ids.varId(tok));
                } else {
                    try self.scanDeferredBody(state, @intFromEnum(full_if.ast.then_expr), current_cfg, error_only);
                }
                if (full_if.ast.else_expr.unwrap()) |else_node| {
                    if (full_if.error_token) |tok| {
                        try self.bindPayloadUnknown(state, tok);
                        try self.scanDeferredBody(state, @intFromEnum(else_node), current_cfg, error_only);
                        state.resetRegion(ids.varId(tok));
                    } else {
                        try self.scanDeferredBody(state, @intFromEnum(else_node), current_cfg, error_only);
                    }
                }
            },
            .@"while", .while_simple, .while_cont => {
                const full_while = tree.fullWhile(@enumFromInt(node)) orelse return;
                if (full_while.payload_token) |tok| {
                    try self.bindPayloadAlias(state, tok, @intFromEnum(full_while.ast.cond_expr), current_cfg);
                    try self.scanDeferredBody(state, @intFromEnum(full_while.ast.then_expr), current_cfg, error_only);
                    state.resetRegion(ids.varId(tok));
                } else {
                    try self.scanDeferredBody(state, @intFromEnum(full_while.ast.then_expr), current_cfg, error_only);
                }
                if (full_while.ast.else_expr.unwrap()) |else_node| {
                    if (full_while.error_token) |tok| {
                        try self.bindPayloadUnknown(state, tok);
                        try self.scanDeferredBody(state, @intFromEnum(else_node), current_cfg, error_only);
                        state.resetRegion(ids.varId(tok));
                    } else {
                        try self.scanDeferredBody(state, @intFromEnum(else_node), current_cfg, error_only);
                    }
                }
            },
            .@"for", .for_simple => {
                const full_for = tree.fullFor(@enumFromInt(node)) orelse return;
                if (full_for.payload_token != 0) {
                    try self.bindForPayloads(state, full_for.payload_token);
                    try self.scanDeferredBody(state, @intFromEnum(full_for.ast.then_expr), current_cfg, error_only);
                } else {
                    try self.scanDeferredBody(state, @intFromEnum(full_for.ast.then_expr), current_cfg, error_only);
                }
                if (full_for.ast.else_expr.unwrap()) |else_node| {
                    try self.scanDeferredBody(state, @intFromEnum(else_node), current_cfg, error_only);
                }
            },
            .@"switch", .switch_comma => {
                const full_switch = tree.switchFull(@enumFromInt(node));
                for (full_switch.ast.cases) |case_node| {
                    const full_case = tree.fullSwitchCase(case_node) orelse continue;
                    try self.scanDeferredBody(state, @intFromEnum(full_case.ast.target_expr), current_cfg, error_only);
                }
            },
            else => {},
        }
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
    if (result.caller_should_deinit) {
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

test "AnalysisEngine widening simple loop converges without drops" {
    // Integration test: simple loop with state-changing operations.
    // Uses var_decl in the loop body to modify state on each iteration.
    // Note: When the same state is produced on successive iterations, deduplication
    // handles convergence. Widening only applies when states differ.
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    // CFG: entry -> loop_header -> loop_body (var_decl) -> loop_header (back edge)
    //                           -> exit (loop exit)
    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));
    // Use var_decl with ast_node to trigger state changes in the loop body
    const body_ir = cfg_mod.IrNode.initWithAst(.var_decl, 100);
    const body = try cfg.addNode(body_ir);
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, header);
    try cfg.addEdgeWithKind(header, body, .branch_true);
    try cfg.addEdgeWithKind(header, exit, .loop_exit);
    try cfg.addEdgeWithKind(body, header, .loop_back);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    // Set a low max_states_per_point
    engine.setMaxStatesPerPoint(5);

    try engine.run();

    const graph = engine.getGraph();

    // Analysis should complete without hitting state limits
    // Combination of deduplication and widening ensures convergence
    try testing.expect(graph.nodeCount() > 0);
    try testing.expect(graph.nodeCount() <= 20);

    // No states should be dropped
    try testing.expectEqual(@as(u32, 0), graph.getDroppedStateCount());

    // Verify loop header widening infrastructure was used (visit tracking)
    // The header should be tracked for widening even if convergence happened via dedup
    try testing.expect(graph.getTrackedLoopHeaderCount() >= 1);
}

test "AnalysisEngine widening nested loops widen per header" {
    // Integration test: nested loops with separate loop headers
    // Verifies that each loop header maintains its own widening state.
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    // CFG: entry -> outer_header -> inner_header -> inner_body -> inner_header (back)
    //                            |                            -> outer_body
    //                            -> outer_exit -> exit
    //              outer_body -> outer_header (back)
    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const outer_header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));
    const inner_header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));

    const inner_body_ir = cfg_mod.IrNode.initWithAst(.var_decl, 100);
    const inner_body = try cfg.addNode(inner_body_ir);

    const outer_body_ir = cfg_mod.IrNode.initWithAst(.var_decl, 200);
    const outer_body = try cfg.addNode(outer_body_ir);

    const outer_exit_node = try cfg.addNode(cfg_mod.IrNode.init(.nop));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    // Entry to outer loop
    try cfg.addEdge(entry, outer_header);

    // Outer loop: header -> inner or exit
    try cfg.addEdgeWithKind(outer_header, inner_header, .branch_true);
    try cfg.addEdgeWithKind(outer_header, outer_exit_node, .loop_exit);

    // Inner loop: header -> body -> header (back) or -> outer_body (exit)
    try cfg.addEdgeWithKind(inner_header, inner_body, .branch_true);
    try cfg.addEdgeWithKind(inner_header, outer_body, .loop_exit);
    try cfg.addEdgeWithKind(inner_body, inner_header, .loop_back);

    // Outer loop back edge
    try cfg.addEdgeWithKind(outer_body, outer_header, .loop_back);

    // Exit
    try cfg.addEdge(outer_exit_node, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    engine.setMaxStatesPerPoint(5);

    try engine.run();

    const graph = engine.getGraph();

    // Widening should have been applied at both loop headers
    // With nested loops, we expect widening to occur
    try testing.expect(graph.getWidenedNodeCount() > 0 or graph.getWideningConvergedCount() > 0);

    // Verify that both loop headers are tracked separately for widening.
    // Each loop header has a distinct CFG node index, so they should have
    // different LoopHeaderKeys and be tracked independently.
    try testing.expect(graph.getTrackedLoopHeaderCount() >= 2);

    // Analysis should complete without hitting limits
    try testing.expect(graph.nodeCount() > 0);
}

test "AnalysisEngine widening branching loop preserves constraints conservatively" {
    // Integration test: loop with branching inside
    // Verifies that constraints from branches are handled conservatively during widening.
    // The branch node has operand_node set to enable constraint extraction.
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    // CFG: entry -> header -> branch (with constraint on var 50) -> then/else -> merge -> header (back)
    //                      -> exit
    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));

    // Create branch node with operand_node set to enable constraint extraction.
    // operand_node = 50 means we're testing variable at AST node 50.
    // operand2_node = 1 means we're comparing against the value 1.
    var branch_ir = cfg_mod.IrNode.init(.branch);
    branch_ir.operand_node = 50;
    branch_ir.operand2_node = 1;
    const branch = try cfg.addNode(branch_ir);

    // Use var_decl nodes in then/else to modify state differently in each branch
    const then_ir = cfg_mod.IrNode.initWithAst(.var_decl, 100);
    const then_node = try cfg.addNode(then_ir);
    const else_ir = cfg_mod.IrNode.initWithAst(.var_decl, 101);
    const else_node = try cfg.addNode(else_ir);

    const merge = try cfg.addNode(cfg_mod.IrNode.init(.nop));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, header);
    try cfg.addEdgeWithKind(header, branch, .branch_true);
    try cfg.addEdgeWithKind(header, exit, .loop_exit);
    try cfg.addEdgeWithKind(branch, then_node, .branch_true);
    try cfg.addEdgeWithKind(branch, else_node, .branch_false);
    try cfg.addEdge(then_node, merge);
    try cfg.addEdge(else_node, merge);
    try cfg.addEdgeWithKind(merge, header, .loop_back);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    engine.setMaxStatesPerPoint(5);

    try engine.run();

    const graph = engine.getGraph();

    // Analysis should complete without issues
    try testing.expect(graph.nodeCount() > 0);

    // Should have explored multiple paths through the loop
    // With branching, states at the header may be widened
    try testing.expect(graph.getDroppedStateCount() == 0 or graph.getWidenedNodeCount() > 0);
}

test "AnalysisEngine widening error path in loop remains sound" {
    // Integration test: loop with error handling (try/catch)
    // Verifies that error_state is handled correctly during widening.
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    // CFG: entry -> header -> try_expr -> success -> body -> header (back)
    //                                  -> error -> error_handler -> header (back)
    //            -> exit
    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));
    const try_node = try cfg.addNode(cfg_mod.IrNode.init(.try_expr));
    const success_body = try cfg.addNode(cfg_mod.IrNode.init(.block));
    const error_handler = try cfg.addNode(cfg_mod.IrNode.init(.catch_expr));
    const merge = try cfg.addNode(cfg_mod.IrNode.init(.nop));
    const exit = try cfg.addNode(cfg_mod.IrNode.init(.fn_exit));

    cfg.entry = entry;
    cfg.exit = exit;

    try cfg.addEdge(entry, header);
    try cfg.addEdgeWithKind(header, try_node, .branch_true);
    try cfg.addEdgeWithKind(header, exit, .loop_exit);
    try cfg.addEdgeWithKind(try_node, success_body, .try_success);
    try cfg.addEdgeWithKind(try_node, error_handler, .try_error);
    try cfg.addEdge(success_body, merge);
    try cfg.addEdgeWithKind(error_handler, merge, .catch_error);
    try cfg.addEdgeWithKind(merge, header, .loop_back);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    engine.setMaxStatesPerPoint(10);

    try engine.run();

    const graph = engine.getGraph();

    // Analysis should complete
    try testing.expect(graph.nodeCount() > 0);

    // Verify error path states exist at relevant nodes
    var found_error_path_at_handler = false;
    var found_normal_path_at_success = false;

    for (graph.nodes.items) |node| {
        if (node.point.node_index == error_handler and node.point.kind == .pre) {
            if (node.state.isErrorPath()) {
                found_error_path_at_handler = true;
            }
        }
        if (node.point.node_index == success_body and node.point.kind == .pre) {
            if (node.state.isNormalPath()) {
                found_normal_path_at_success = true;
            }
        }
    }

    // Error states should be tracked correctly through the loop
    try testing.expect(found_error_path_at_handler);
    try testing.expect(found_normal_path_at_success);
}

test "AnalysisEngine widening convergence stops exploration" {
    // Integration test: verifies that loop exploration is bounded.
    // When state doesn't change in the loop body, deduplication ensures
    // convergence by recognizing that we've seen this (point, state) before.
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    // Simple loop that doesn't change state - deduplication handles convergence
    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const header = try cfg.addNode(cfg_mod.IrNode.init(.loop_header));
    const body = try cfg.addNode(cfg_mod.IrNode.init(.nop)); // No state change
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

    // Analysis should complete and node count should be bounded
    // (deduplication prevents infinite exploration)
    try testing.expect(graph.nodeCount() > 0);
    try testing.expect(graph.nodeCount() <= 20);

    // No states should be dropped (deduplication is sufficient)
    try testing.expectEqual(@as(u32, 0), graph.getDroppedStateCount());
}

test "AnalysisEngine widening regression test with real loop code" {
    // Fixture-based regression test: parses actual Zig code with a loop
    // and verifies that widening ensures convergence without state explosion.
    // This is the type of loop that could hit max_states_per_point without widening.
    const testing = std.testing;
    const allocator = testing.allocator;

    // Code with a for loop that iterates over a slice and allocates in each iteration.
    // This pattern is common in real code and was previously prone to state explosion.
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn process(allocator: std.mem.Allocator, items: []const u8) !void {
        \\    for (items) |item| {
        \\        const buf = try allocator.alloc(u8, 1);
        \\        defer allocator.free(buf);
        \\        buf[0] = item;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = source.ast() catch return;
    const tags = tree.nodes.items(.tag);
    var fn_node: ?AstNodeId = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = ids.astId(@intCast(i));
            break;
        }
    }
    const fn_idx = fn_node orelse return;

    var builder = CfgBuilder.init(allocator);
    var cfg_opt = builder.buildFromFn(&source, fn_idx) catch return;

    if (cfg_opt) |*cfg| {
        defer cfg.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg, &source);
        defer engine.deinit();

        // Set a low max_states_per_point to verify widening prevents state explosion
        engine.setMaxStatesPerPoint(5);

        try engine.run();

        const graph = engine.getGraph();

        // Analysis should complete successfully
        try testing.expect(graph.nodeCount() > 0);

        // Widening should prevent state explosion - no states dropped
        try testing.expectEqual(@as(u32, 0), graph.getDroppedStateCount());
    }
}
