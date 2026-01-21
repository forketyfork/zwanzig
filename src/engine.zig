const std = @import("std");
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgNode = cfg_mod.CfgNode;
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;
const IrTag = cfg_mod.IrTag;
const CfgBuilder = cfg_mod.CfgBuilder;
const Source = @import("source.zig").Source;

pub const EngineError = std.mem.Allocator.Error;

/// Default maximum inlining depth for interprocedural analysis.
/// Functions are inlined up to this depth; deeper calls are treated as unknown effects.
pub const DEFAULT_MAX_INLINE_DEPTH: u32 = 3;

/// Comparison operator for constraints.
pub const CompareOp = enum {
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
};

/// A constraint on a variable's value.
/// Constraints are used to track path conditions from branch expressions.
pub const Constraint = union(enum) {
    /// Variable compared to an integer value: var <op> value
    int_compare: struct {
        var_id: u32,
        op: CompareOp,
        value: i64,
    },
    /// Variable compared to null: var == null or var != null
    null_check: struct {
        var_id: u32,
        is_null: bool, // true = var is null, false = var is non-null
    },
    /// Variable compared to another variable: var1 <op> var2
    var_compare: struct {
        var1_id: u32,
        op: CompareOp,
        var2_id: u32,
    },

    pub fn eql(self: Constraint, other: Constraint) bool {
        return switch (self) {
            .int_compare => |ic1| switch (other) {
                .int_compare => |ic2| ic1.var_id == ic2.var_id and ic1.op == ic2.op and ic1.value == ic2.value,
                else => false,
            },
            .null_check => |nc1| switch (other) {
                .null_check => |nc2| nc1.var_id == nc2.var_id and nc1.is_null == nc2.is_null,
                else => false,
            },
            .var_compare => |vc1| switch (other) {
                .var_compare => |vc2| vc1.var1_id == vc2.var1_id and vc1.op == vc2.op and vc1.var2_id == vc2.var2_id,
                else => false,
            },
        };
    }

    pub fn hash(self: Constraint) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag_byte: u8 = switch (self) {
            .int_compare => 0,
            .null_check => 1,
            .var_compare => 2,
        };
        hasher.update(&[_]u8{tag_byte});
        switch (self) {
            .int_compare => |ic| {
                hasher.update(std.mem.asBytes(&ic.var_id));
                hasher.update(std.mem.asBytes(&ic.op));
                hasher.update(std.mem.asBytes(&ic.value));
            },
            .null_check => |nc| {
                hasher.update(std.mem.asBytes(&nc.var_id));
                hasher.update(std.mem.asBytes(&nc.is_null));
            },
            .var_compare => |vc| {
                hasher.update(std.mem.asBytes(&vc.var1_id));
                hasher.update(std.mem.asBytes(&vc.op));
                hasher.update(std.mem.asBytes(&vc.var2_id));
            },
        }
        return hasher.final();
    }

    /// Create an integer comparison constraint.
    pub fn intCompare(var_id: u32, op: CompareOp, value: i64) Constraint {
        return .{ .int_compare = .{ .var_id = var_id, .op = op, .value = value } };
    }

    /// Create a null check constraint.
    pub fn nullCheck(var_id: u32, is_null: bool) Constraint {
        return .{ .null_check = .{ .var_id = var_id, .is_null = is_null } };
    }

    /// Create a variable comparison constraint.
    pub fn varCompare(var1_id: u32, op: CompareOp, var2_id: u32) Constraint {
        return .{ .var_compare = .{ .var1_id = var1_id, .op = op, .var2_id = var2_id } };
    }

    /// Get the negation of this constraint (for else branches).
    pub fn negate(self: Constraint) Constraint {
        return switch (self) {
            .int_compare => |ic| .{ .int_compare = .{
                .var_id = ic.var_id,
                .op = negateOp(ic.op),
                .value = ic.value,
            } },
            .null_check => |nc| .{ .null_check = .{
                .var_id = nc.var_id,
                .is_null = !nc.is_null,
            } },
            .var_compare => |vc| .{ .var_compare = .{
                .var1_id = vc.var1_id,
                .op = negateOp(vc.op),
                .var2_id = vc.var2_id,
            } },
        };
    }

    fn negateOp(op: CompareOp) CompareOp {
        return switch (op) {
            .eq => .ne,
            .ne => .eq,
            .lt => .ge,
            .le => .gt,
            .gt => .le,
            .ge => .lt,
        };
    }
};

/// Manages path constraints for symbolic execution.
/// Tracks a set of constraints that must all hold on a given path.
pub const ConstraintManager = struct {
    /// List of active constraints on this path
    constraints: std.ArrayList(Constraint),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConstraintManager {
        return .{
            .constraints = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConstraintManager) void {
        self.constraints.deinit(self.allocator);
    }

    pub fn clone(self: *const ConstraintManager) !ConstraintManager {
        var new_cm = ConstraintManager.init(self.allocator);
        for (self.constraints.items) |c| {
            try new_cm.constraints.append(self.allocator, c);
        }
        return new_cm;
    }

    /// Add a constraint to the manager.
    pub fn addConstraint(self: *ConstraintManager, constraint: Constraint) !void {
        // Check for duplicate before adding
        for (self.constraints.items) |c| {
            if (c.eql(constraint)) return;
        }
        try self.constraints.append(self.allocator, constraint);
    }

    /// Check if the current constraint set is satisfiable.
    /// Returns false if there's a definite contradiction.
    pub fn isSatisfiable(self: *const ConstraintManager, env: *const Environment) bool {
        // Check each constraint against the environment
        for (self.constraints.items) |constraint| {
            if (!self.isConstraintSatisfiable(constraint, env)) {
                return false;
            }
        }

        // Check for contradictions between constraints
        for (self.constraints.items, 0..) |c1, i| {
            for (self.constraints.items[i + 1 ..]) |c2| {
                if (self.areContradictory(c1, c2)) {
                    return false;
                }
            }
        }

        return true;
    }

    fn isConstraintSatisfiable(self: *const ConstraintManager, constraint: Constraint, env: *const Environment) bool {
        _ = self;
        switch (constraint) {
            .int_compare => |ic| {
                if (env.get(ic.var_id)) |val| {
                    return isValueCompatibleWithIntConstraint(val, ic.op, ic.value);
                }
                return true; // Unknown variable, constraint might be satisfiable
            },
            .null_check => |nc| {
                if (env.get(nc.var_id)) |val| {
                    return isValueCompatibleWithNullCheck(val, nc.is_null);
                }
                return true;
            },
            .var_compare => {
                // Variable comparisons are conservatively satisfiable unless we have concrete values
                return true;
            },
        }
    }

    fn areContradictory(self: *const ConstraintManager, c1: Constraint, c2: Constraint) bool {
        _ = self;
        switch (c1) {
            .int_compare => |ic1| {
                switch (c2) {
                    .int_compare => |ic2| {
                        if (ic1.var_id != ic2.var_id) return false;
                        return areIntConstraintsContradictory(ic1.op, ic1.value, ic2.op, ic2.value);
                    },
                    else => return false,
                }
            },
            .null_check => |nc1| {
                switch (c2) {
                    .null_check => |nc2| {
                        // x == null AND x != null is contradictory
                        return nc1.var_id == nc2.var_id and nc1.is_null != nc2.is_null;
                    },
                    else => return false,
                }
            },
            .var_compare => return false,
        }
    }

    pub fn size(self: *const ConstraintManager) usize {
        return self.constraints.items.len;
    }

    pub fn eql(self: *const ConstraintManager, other: *const ConstraintManager) bool {
        if (self.constraints.items.len != other.constraints.items.len) return false;
        for (self.constraints.items) |c1| {
            var found = false;
            for (other.constraints.items) |c2| {
                if (c1.eql(c2)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    pub fn computeHash(self: *const ConstraintManager) u64 {
        var combined_hash: u64 = 0;
        for (self.constraints.items) |c| {
            combined_hash ^= c.hash();
        }
        return combined_hash;
    }

    /// Refine an abstract value based on a constraint.
    /// Returns the refined value, or null if the constraint is unsatisfiable.
    pub fn refineValue(value: AbstractValue, constraint: Constraint) ?AbstractValue {
        switch (constraint) {
            .int_compare => |ic| {
                return refineValueWithIntConstraint(value, ic.op, ic.value);
            },
            .null_check => |nc| {
                if (nc.is_null) {
                    // Constraint: variable is null
                    return switch (value) {
                        .null_val => .null_val,
                        .non_null => null, // Contradiction
                        .unknown => .null_val,
                        else => null, // Concrete int or range can't be null
                    };
                } else {
                    // Constraint: variable is non-null
                    return switch (value) {
                        .null_val => null, // Contradiction
                        .non_null => .non_null,
                        .unknown => .non_null,
                        .int_range, .concrete_int => value, // Ints are non-null
                    };
                }
            },
            .var_compare => return value, // No refinement for var-var comparisons yet
        }
    }
};

fn isValueCompatibleWithIntConstraint(val: AbstractValue, op: CompareOp, value: i64) bool {
    switch (val) {
        .concrete_int => |v| {
            return switch (op) {
                .eq => v == value,
                .ne => v != value,
                .lt => v < value,
                .le => v <= value,
                .gt => v > value,
                .ge => v >= value,
            };
        },
        .int_range => |r| {
            return switch (op) {
                .eq => r.contains(value),
                .ne => !(r.min == value and r.max == value), // Only contradictory if range is single value equal to value
                .lt => r.min < value, // At least some values can be < value
                .le => r.min <= value,
                .gt => r.max > value,
                .ge => r.max >= value,
            };
        },
        else => return true, // Unknown, null, non_null are conservatively compatible
    }
}

fn isValueCompatibleWithNullCheck(val: AbstractValue, is_null: bool) bool {
    if (is_null) {
        // Checking if variable is null
        return switch (val) {
            .null_val => true,
            .non_null => false,
            .concrete_int, .int_range => false, // Ints are not null
            .unknown => true,
        };
    } else {
        // Checking if variable is non-null
        return switch (val) {
            .null_val => false,
            .non_null => true,
            .concrete_int, .int_range => true,
            .unknown => true,
        };
    }
}

fn areIntConstraintsContradictory(op1: CompareOp, val1: i64, op2: CompareOp, val2: i64) bool {
    // Check for obvious contradictions
    // x == 5 AND x == 6 is contradictory
    if (op1 == .eq and op2 == .eq and val1 != val2) return true;

    // x == 5 AND x != 5 is contradictory
    if (op1 == .eq and op2 == .ne and val1 == val2) return true;
    if (op1 == .ne and op2 == .eq and val1 == val2) return true;

    // x < 5 AND x > 10 is contradictory (or x > 5 AND x < 5)
    if (op1 == .lt and op2 == .gt and val1 <= val2) return true;
    if (op1 == .gt and op2 == .lt and val1 >= val2) return true;

    // x < 5 AND x >= 5 is contradictory
    if (op1 == .lt and op2 == .ge and val1 <= val2) return true;
    if (op1 == .ge and op2 == .lt and val1 >= val2) return true;

    // x <= 5 AND x > 5 is contradictory
    if (op1 == .le and op2 == .gt and val1 == val2) return true;
    if (op1 == .gt and op2 == .le and val1 == val2) return true;

    // x == 5 AND x < 5 is contradictory
    if (op1 == .eq and op2 == .lt and val1 >= val2) return true;
    if (op1 == .lt and op2 == .eq and val1 <= val2) return true;

    // x == 5 AND x > 5 is contradictory
    if (op1 == .eq and op2 == .gt and val1 <= val2) return true;
    if (op1 == .gt and op2 == .eq and val1 >= val2) return true;

    return false;
}

fn refineValueWithIntConstraint(value: AbstractValue, op: CompareOp, constraint_val: i64) ?AbstractValue {
    switch (value) {
        .unknown => {
            // Refine unknown based on constraint
            return switch (op) {
                .eq => .{ .concrete_int = constraint_val },
                .ne => .unknown, // Still unknown, just not equal to one value
                .lt => blk: {
                    // x < minInt is unsatisfiable
                    if (constraint_val == std.math.minInt(i64)) return null;
                    break :blk .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val - 1) };
                },
                .le => .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val) },
                .gt => blk: {
                    // x > maxInt is unsatisfiable
                    if (constraint_val == std.math.maxInt(i64)) return null;
                    break :blk .{ .int_range = AbstractValue.IntRange.init(constraint_val + 1, std.math.maxInt(i64)) };
                },
                .ge => .{ .int_range = AbstractValue.IntRange.init(constraint_val, std.math.maxInt(i64)) },
            };
        },
        .concrete_int => |v| {
            const satisfies = switch (op) {
                .eq => v == constraint_val,
                .ne => v != constraint_val,
                .lt => v < constraint_val,
                .le => v <= constraint_val,
                .gt => v > constraint_val,
                .ge => v >= constraint_val,
            };
            return if (satisfies) value else null;
        },
        .int_range => |r| {
            const new_range = switch (op) {
                .eq => if (r.contains(constraint_val)) AbstractValue.IntRange.single(constraint_val) else return null,
                .ne => r, // Can't easily narrow a range for !=
                .lt => blk: {
                    // x < minInt is unsatisfiable
                    if (constraint_val == std.math.minInt(i64)) return null;
                    if (r.min >= constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val - 1));
                },
                .le => blk: {
                    if (r.min > constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val));
                },
                .gt => blk: {
                    // x > maxInt is unsatisfiable
                    if (constraint_val == std.math.maxInt(i64)) return null;
                    if (r.max <= constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(@max(r.min, constraint_val + 1), r.max);
                },
                .ge => blk: {
                    if (r.max < constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(@max(r.min, constraint_val), r.max);
                },
            };
            return .{ .int_range = new_range };
        },
        .null_val, .non_null => return value,
    }
}

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

/// Error state of the program: whether we are on an error path or success path.
pub const ErrorState = enum {
    /// Normal execution path (no error)
    normal,
    /// Error path (error has been produced but not yet handled)
    error_active,
    /// Error has been caught and handled
    error_handled,
};

/// Represents a call site in the inline call stack.
/// Used to track interprocedural analysis context.
pub const CallSite = struct {
    /// CFG node index of the call instruction
    call_node: u32,
    /// The CFG containing the call site
    caller_cfg: *const Cfg,
    /// Return point: the CFG node to continue from after the call returns
    return_node: u32,
};

/// Abstract program state for path-sensitive analysis.
/// Stores the environment mapping variables to abstract values,
/// plus path constraints from branch conditions, and error state.
pub const ProgramState = struct {
    /// Environment mapping variables to abstract values
    env: Environment,
    /// Constraint manager for path conditions
    constraints: ConstraintManager,
    /// Error state tracking (normal, error_active, error_handled)
    error_state: ErrorState,
    /// Cached hash for efficient deduplication
    cached_hash: ?u64,
    /// Current inlining depth (0 = top-level function)
    inline_depth: u32,
    /// Call stack for interprocedural analysis (stored as indices into call_sites)
    call_stack: std.ArrayList(CallSite),

    pub fn init(allocator: std.mem.Allocator) ProgramState {
        return .{
            .env = Environment.init(allocator),
            .constraints = ConstraintManager.init(allocator),
            .error_state = .normal,
            .cached_hash = null,
            .inline_depth = 0,
            .call_stack = .empty,
        };
    }

    pub fn deinit(self: *ProgramState) void {
        self.env.deinit();
        self.constraints.deinit();
        self.call_stack.deinit(self.env.allocator);
    }

    pub fn eql(self: *const ProgramState, other: *const ProgramState) bool {
        if (self.inline_depth != other.inline_depth) return false;
        return self.env.eql(&other.env) and
            self.constraints.eql(&other.constraints) and
            self.error_state == other.error_state;
    }

    pub fn computeHash(self: *ProgramState) u64 {
        if (self.cached_hash) |h| return h;
        var hasher = std.hash.Wyhash.init(0);
        const env_hash = self.env.computeHash();
        hasher.update(std.mem.asBytes(&env_hash));
        const constraints_hash = self.constraints.computeHash();
        hasher.update(std.mem.asBytes(&constraints_hash));
        hasher.update(std.mem.asBytes(&self.error_state));
        hasher.update(std.mem.asBytes(&self.inline_depth));
        const h = hasher.final();
        self.cached_hash = h;
        return h;
    }

    pub fn clone(self: *const ProgramState, allocator: std.mem.Allocator) !ProgramState {
        var new_call_stack: std.ArrayList(CallSite) = .empty;
        for (self.call_stack.items) |cs| {
            try new_call_stack.append(allocator, cs);
        }
        return .{
            .env = try self.env.clone(),
            .constraints = try self.constraints.clone(),
            .error_state = self.error_state,
            .cached_hash = self.cached_hash,
            .inline_depth = self.inline_depth,
            .call_stack = new_call_stack,
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

    /// Add a constraint to this state and refine variable values accordingly.
    pub fn addConstraint(self: *ProgramState, constraint: Constraint) !void {
        try self.constraints.addConstraint(constraint);
        self.invalidateCache();

        // Refine the relevant variable's value based on the constraint
        const var_id = switch (constraint) {
            .int_compare => |ic| ic.var_id,
            .null_check => |nc| nc.var_id,
            .var_compare => |vc| vc.var1_id,
        };

        if (self.env.get(var_id)) |current_val| {
            if (ConstraintManager.refineValue(current_val, constraint)) |refined| {
                try self.env.set(var_id, refined);
            }
        }
    }

    /// Check if this state's constraints are satisfiable.
    pub fn isSatisfiable(self: *const ProgramState) bool {
        return self.constraints.isSatisfiable(&self.env);
    }

    pub fn constraintCount(self: *const ProgramState) usize {
        return self.constraints.size();
    }

    /// Set the error state of this program state.
    pub fn setErrorState(self: *ProgramState, error_state: ErrorState) void {
        self.error_state = error_state;
        self.invalidateCache();
    }

    /// Get the current error state.
    pub fn getErrorState(self: *const ProgramState) ErrorState {
        return self.error_state;
    }

    /// Check if we are on an error path.
    pub fn isErrorPath(self: *const ProgramState) bool {
        return self.error_state == .error_active;
    }

    /// Check if we are on a normal (non-error) path.
    pub fn isNormalPath(self: *const ProgramState) bool {
        return self.error_state == .normal;
    }

    /// Get the current inlining depth.
    pub fn getInlineDepth(self: *const ProgramState) u32 {
        return self.inline_depth;
    }

    /// Increment inline depth when entering an inlined function.
    pub fn incrementInlineDepth(self: *ProgramState) void {
        self.inline_depth += 1;
        self.invalidateCache();
    }

    /// Decrement inline depth when returning from an inlined function.
    pub fn decrementInlineDepth(self: *ProgramState) void {
        if (self.inline_depth > 0) {
            self.inline_depth -= 1;
        }
        self.invalidateCache();
    }

    /// Push a call site onto the call stack.
    pub fn pushCallSite(self: *ProgramState, call_site: CallSite) !void {
        try self.call_stack.append(self.env.allocator, call_site);
        self.invalidateCache();
    }

    /// Pop a call site from the call stack.
    pub fn popCallSite(self: *ProgramState) ?CallSite {
        if (self.call_stack.items.len > 0) {
            self.invalidateCache();
            return self.call_stack.pop();
        }
        return null;
    }

    /// Get the top of the call stack without removing it.
    pub fn peekCallSite(self: *const ProgramState) ?CallSite {
        if (self.call_stack.items.len > 0) {
            return self.call_stack.items[self.call_stack.items.len - 1];
        }
        return null;
    }

    /// Check if we are at an inline call site (depth > 0).
    pub fn isInlined(self: *const ProgramState) bool {
        return self.inline_depth > 0;
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
/// Applies branch constraints and prunes infeasible paths.
/// Supports interprocedural analysis via function inlining.
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
    /// Source file for resolving function calls (optional)
    source: ?*Source,
    /// Cache of built CFGs for functions (by AST node index)
    function_cfgs: std.AutoHashMap(u32, Cfg),
    /// Map from function name to AST node index
    function_names: std.StringHashMap(u32),
    /// Count of inlined calls (for testing/debugging)
    inlined_call_count: u32,

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
            .max_inline_depth = DEFAULT_MAX_INLINE_DEPTH,
            .source = null,
            .function_cfgs = std.AutoHashMap(u32, Cfg).init(allocator),
            .function_names = std.StringHashMap(u32).init(allocator),
            .inlined_call_count = 0,
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
        // Deinit all cached CFGs
        var iter = self.function_cfgs.valueIterator();
        while (iter.next()) |cfg| {
            cfg.deinit();
        }
        self.function_cfgs.deinit();
        self.function_names.deinit();
    }

    /// Set the maximum inline depth for interprocedural analysis.
    pub fn setMaxInlineDepth(self: *AnalysisEngine, depth: u32) void {
        self.max_inline_depth = depth;
    }

    /// Get the count of inlined function calls.
    pub fn getInlinedCallCount(self: *const AnalysisEngine) u32 {
        return self.inlined_call_count;
    }

    /// Run the analysis on the CFG, building the exploded graph.
    pub fn run(self: *AnalysisEngine) EngineError!void {
        const cfg = self.graph.cfg;

        // Build function name index if source is available
        if (self.source) |src| {
            try self.buildFunctionIndex(src);
        }

        var initial_state = ProgramState.init(self.allocator);
        const entry_point = ProgramPoint.initPre(cfg.entry);

        const result = try self.graph.getOrCreateNode(entry_point, &initial_state);
        if (!result.is_new) {
            initial_state.deinit();
        }
        try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null, .cfg = cfg });

        while (self.worklist.pop()) |item| {
            try self.processNode(item.node_index, item.edge_kind, item.pending_constraint, item.cfg);
        }
    }

    /// Build an index of function names to AST node indices.
    fn buildFunctionIndex(self: *AnalysisEngine, src: *Source) EngineError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const main_tokens = tree.nodes.items(.main_token);
        const content = src.getContent();

        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .fn_decl) {
                // Get the function name from the main token
                const main_token = main_tokens[i];
                // For fn_decl, main_token is the 'fn' keyword, name follows
                if (main_token + 1 < token_tags.len and token_tags[main_token + 1] == .identifier) {
                    const name_token = main_token + 1;
                    const name_start = token_starts[name_token];
                    // Find the end of the identifier
                    var name_end = name_start;
                    while (name_end < content.len and (std.ascii.isAlphanumeric(content[name_end]) or content[name_end] == '_')) {
                        name_end += 1;
                    }
                    const name = content[name_start..name_end];
                    try self.function_names.put(name, @intCast(i));
                }
            }
        }
    }

    /// Get or build a CFG for a function by its AST node index.
    fn getOrBuildFunctionCfg(self: *AnalysisEngine, fn_ast_node: u32) ?*const Cfg {
        // Check cache first
        if (self.function_cfgs.getPtr(fn_ast_node)) |cfg| {
            return cfg;
        }

        // Build the CFG if source is available
        const src = self.source orelse return null;
        var builder = CfgBuilder.init(self.allocator);
        const cfg_opt = builder.buildFromFn(src, fn_ast_node) catch return null;
        if (cfg_opt) |cfg| {
            self.function_cfgs.put(fn_ast_node, cfg) catch return null;
            return self.function_cfgs.getPtr(fn_ast_node);
        }
        return null;
    }

    /// Resolve a function call to a function AST node index.
    /// Returns null for external or unresolvable calls.
    fn resolveFunctionCall(self: *AnalysisEngine, call_ast_node: u32) ?u32 {
        const src = self.source orelse return null;
        const tree = src.ast() catch return null;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const main_tokens = tree.nodes.items(.main_token);
        const content = src.getContent();

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
                const name_start = token_starts[callee_token];
                var name_end = name_start;
                while (name_end < content.len and (std.ascii.isAlphanumeric(content[name_end]) or content[name_end] == '_')) {
                    name_end += 1;
                }
                const name = content[name_start..name_end];

                // Look up in function index
                return self.function_names.get(name);
            }
        }

        return null;
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

                const post_point = ProgramPoint.initPost(point.node_index);
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
                        const succ_point = ProgramPoint.initPre(edge.to);
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
    };

    /// Handle a call node, potentially inlining the callee.
    fn handleCallNode(
        self: *AnalysisEngine,
        exploded_node_index: u32,
        cfg_node: *const CfgNode,
        state: *const ProgramState,
        caller_cfg: *const Cfg,
    ) EngineError!InlineResult {
        // Check if we've exceeded the inline depth limit
        if (state.getInlineDepth() >= self.max_inline_depth) {
            return .{ .inlined = false };
        }

        // Try to resolve the call target
        const call_ast_node = cfg_node.ir_node.ast_node orelse return .{ .inlined = false };
        const callee_fn_node = self.resolveFunctionCall(call_ast_node) orelse return .{ .inlined = false };

        // Get or build the callee's CFG
        const callee_cfg = self.getOrBuildFunctionCfg(callee_fn_node) orelse return .{ .inlined = false };

        // Find the return point (successor of the call node in the caller)
        var return_node: ?u32 = null;
        for (caller_cfg.edges.items) |edge| {
            if (edge.from == cfg_node.index) {
                return_node = edge.to;
                break;
            }
        }
        const ret_node = return_node orelse return .{ .inlined = false };

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
        const callee_entry_point = ProgramPoint.initPre(callee_cfg.entry);
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

        return .{ .inlined = true };
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
        const return_point = ProgramPoint.initPre(call_site.return_node);
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
        _ = self;
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
            if (ir_node.operand2_node) |cmp_info| {
                // Interpret operand2_node as encoded comparison info:
                // High 32 bits of the value represent the comparison constant
                // This is a simplified encoding for now
                return Constraint.intCompare(var_id, .eq, @as(i64, cmp_info));
            }
            // If we only have a variable and no comparison info, assume null check
            return Constraint.nullCheck(var_id, true);
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
            .call => {
                // External or unresolvable calls: treat as unknown effects.
                // This means we conservatively assume the call could modify any state.
                // For now, we don't invalidate any specific variables since we don't
                // have precise aliasing information. Future enhancement: track which
                // variables could be modified by external calls.
                //
                // The call node itself doesn't change the abstract state significantly,
                // but the return value (if captured) would be unknown.
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

// ============== Constraint Tests ==============

test "Constraint creation and equality" {
    const c1 = Constraint.intCompare(1, .eq, 42);
    const c2 = Constraint.intCompare(1, .eq, 42);
    const c3 = Constraint.intCompare(1, .eq, 100);
    const c4 = Constraint.intCompare(2, .eq, 42);

    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));
    try std.testing.expect(!c1.eql(c4));

    const null_check1 = Constraint.nullCheck(1, true);
    const null_check2 = Constraint.nullCheck(1, true);
    const null_check3 = Constraint.nullCheck(1, false);

    try std.testing.expect(null_check1.eql(null_check2));
    try std.testing.expect(!null_check1.eql(null_check3));
    try std.testing.expect(!null_check1.eql(c1));
}

test "Constraint negation" {
    const eq_constraint = Constraint.intCompare(1, .eq, 5);
    const neq = eq_constraint.negate();
    switch (neq) {
        .int_compare => |ic| {
            try std.testing.expectEqual(@as(u32, 1), ic.var_id);
            try std.testing.expectEqual(CompareOp.ne, ic.op);
            try std.testing.expectEqual(@as(i64, 5), ic.value);
        },
        else => try std.testing.expect(false),
    }

    const lt_constraint = Constraint.intCompare(1, .lt, 10);
    const ge = lt_constraint.negate();
    switch (ge) {
        .int_compare => |ic| {
            try std.testing.expectEqual(CompareOp.ge, ic.op);
        },
        else => try std.testing.expect(false),
    }

    const null_check = Constraint.nullCheck(1, true);
    const not_null = null_check.negate();
    switch (not_null) {
        .null_check => |nc| {
            try std.testing.expectEqual(@as(u32, 1), nc.var_id);
            try std.testing.expect(!nc.is_null);
        },
        else => try std.testing.expect(false),
    }
}

test "ConstraintManager basic operations" {
    const allocator = std.testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try std.testing.expectEqual(@as(usize, 0), cm.size());

    try cm.addConstraint(Constraint.intCompare(1, .eq, 42));
    try std.testing.expectEqual(@as(usize, 1), cm.size());

    // Adding duplicate should not increase size
    try cm.addConstraint(Constraint.intCompare(1, .eq, 42));
    try std.testing.expectEqual(@as(usize, 1), cm.size());

    try cm.addConstraint(Constraint.nullCheck(2, false));
    try std.testing.expectEqual(@as(usize, 2), cm.size());
}

test "ConstraintManager cloning" {
    const allocator = std.testing.allocator;

    var cm1 = ConstraintManager.init(allocator);
    defer cm1.deinit();

    try cm1.addConstraint(Constraint.intCompare(1, .eq, 42));
    try cm1.addConstraint(Constraint.nullCheck(2, true));

    var cm2 = try cm1.clone();
    defer cm2.deinit();

    try std.testing.expect(cm1.eql(&cm2));
    try std.testing.expectEqual(@as(usize, 2), cm2.size());
}

test "ConstraintManager satisfiability with environment" {
    const allocator = std.testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();

    // Variable x = 5
    try env.set(1, .{ .concrete_int = 5 });

    // Constraint: x == 5 should be satisfiable
    try cm.addConstraint(Constraint.intCompare(1, .eq, 5));
    try std.testing.expect(cm.isSatisfiable(&env));

    // Adding x == 6 should make it unsatisfiable
    try cm.addConstraint(Constraint.intCompare(1, .eq, 6));
    try std.testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager null check satisfiability" {
    const allocator = std.testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();

    // Variable x is non-null
    try env.set(1, .non_null);

    // Constraint: x is null should be unsatisfiable
    try cm.addConstraint(Constraint.nullCheck(1, true));
    try std.testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager contradictory constraints" {
    const allocator = std.testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();

    // x == null AND x != null should be contradictory
    try cm.addConstraint(Constraint.nullCheck(1, true));
    try cm.addConstraint(Constraint.nullCheck(1, false));
    try std.testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager refineValue for int constraint" {
    // Test refining unknown value with equality constraint
    const unknown: AbstractValue = .unknown;
    const refined = ConstraintManager.refineValue(unknown, Constraint.intCompare(1, .eq, 42));
    try std.testing.expect(refined != null);
    try std.testing.expect(refined.?.eql(.{ .concrete_int = 42 }));

    // Test refining concrete value that satisfies constraint
    const concrete5: AbstractValue = .{ .concrete_int = 5 };
    const refined_eq = ConstraintManager.refineValue(concrete5, Constraint.intCompare(1, .eq, 5));
    try std.testing.expect(refined_eq != null);
    try std.testing.expect(refined_eq.?.eql(.{ .concrete_int = 5 }));

    // Test refining concrete value that doesn't satisfy constraint
    const refined_neq = ConstraintManager.refineValue(concrete5, Constraint.intCompare(1, .eq, 10));
    try std.testing.expect(refined_neq == null);

    // Test refining with less-than constraint
    const refined_lt = ConstraintManager.refineValue(unknown, Constraint.intCompare(1, .lt, 10));
    try std.testing.expect(refined_lt != null);
    switch (refined_lt.?) {
        .int_range => |r| {
            try std.testing.expect(r.max == 9);
        },
        else => try std.testing.expect(false),
    }
}

test "ConstraintManager refineValue for null constraint" {
    // Test refining unknown value with null constraint
    const unknown: AbstractValue = .unknown;
    const refined_null = ConstraintManager.refineValue(unknown, Constraint.nullCheck(1, true));
    try std.testing.expect(refined_null != null);
    try std.testing.expect(refined_null.?.isNull());

    // Test refining unknown value with non-null constraint
    const refined_non_null = ConstraintManager.refineValue(unknown, Constraint.nullCheck(1, false));
    try std.testing.expect(refined_non_null != null);
    try std.testing.expect(refined_non_null.?.isNonNull());

    // Test refining null value with non-null constraint (contradiction)
    const null_val: AbstractValue = .null_val;
    const refined_contradiction = ConstraintManager.refineValue(null_val, Constraint.nullCheck(1, false));
    try std.testing.expect(refined_contradiction == null);

    // Test refining non-null value with null constraint (contradiction)
    const non_null: AbstractValue = .non_null;
    const refined_contradiction2 = ConstraintManager.refineValue(non_null, Constraint.nullCheck(1, true));
    try std.testing.expect(refined_contradiction2 == null);
}

test "ProgramState with constraints" {
    const allocator = std.testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.constraintCount());

    // Add a variable with unknown value
    try state.setVar(1, .unknown);

    // Add constraint that refines the value
    try state.addConstraint(Constraint.intCompare(1, .eq, 42));
    try std.testing.expectEqual(@as(usize, 1), state.constraintCount());

    // The variable should now be refined to concrete 42
    const val = state.getVar(1);
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.eql(.{ .concrete_int = 42 }));

    try std.testing.expect(state.isSatisfiable());
}

test "ProgramState clone includes constraints" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    try state1.setVar(1, .unknown);
    try state1.addConstraint(Constraint.intCompare(1, .gt, 0));

    var state2 = try state1.clone(allocator);
    defer state2.deinit();

    try std.testing.expect(state1.eql(&state2));
    try std.testing.expectEqual(state1.constraintCount(), state2.constraintCount());
}

test "ProgramState satisfiability" {
    const allocator = std.testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try state.setVar(1, .{ .concrete_int = 5 });

    // Add constraint that is satisfiable
    try state.addConstraint(Constraint.intCompare(1, .lt, 10));
    try std.testing.expect(state.isSatisfiable());

    // Add constraint that makes it unsatisfiable
    try state.addConstraint(Constraint.intCompare(1, .gt, 10));
    try std.testing.expect(!state.isSatisfiable());
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
    const entry_point = ProgramPoint.initPre(entry);
    var initial_state = ProgramState.init(allocator);
    try initial_state.setVar(100, .{ .concrete_int = 5 });
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

test "areIntConstraintsContradictory" {
    // x == 5 AND x == 6 is contradictory
    try std.testing.expect(areIntConstraintsContradictory(.eq, 5, .eq, 6));

    // x == 5 AND x == 5 is not contradictory
    try std.testing.expect(!areIntConstraintsContradictory(.eq, 5, .eq, 5));

    // x == 5 AND x != 5 is contradictory
    try std.testing.expect(areIntConstraintsContradictory(.eq, 5, .ne, 5));

    // x < 5 AND x > 10 is contradictory
    try std.testing.expect(areIntConstraintsContradictory(.lt, 5, .gt, 10));

    // x < 10 AND x > 5 is not contradictory (overlapping range)
    try std.testing.expect(!areIntConstraintsContradictory(.lt, 10, .gt, 5));
}

test "isValueCompatibleWithIntConstraint" {
    // Concrete value tests
    try std.testing.expect(isValueCompatibleWithIntConstraint(.{ .concrete_int = 5 }, .eq, 5));
    try std.testing.expect(!isValueCompatibleWithIntConstraint(.{ .concrete_int = 5 }, .eq, 6));
    try std.testing.expect(isValueCompatibleWithIntConstraint(.{ .concrete_int = 5 }, .lt, 10));
    try std.testing.expect(!isValueCompatibleWithIntConstraint(.{ .concrete_int = 5 }, .lt, 5));

    // Range value tests
    const range = AbstractValue.IntRange.init(0, 10);
    try std.testing.expect(isValueCompatibleWithIntConstraint(.{ .int_range = range }, .eq, 5));
    try std.testing.expect(!isValueCompatibleWithIntConstraint(.{ .int_range = range }, .eq, 15));
    try std.testing.expect(isValueCompatibleWithIntConstraint(.{ .int_range = range }, .lt, 15));

    // Unknown is always compatible
    try std.testing.expect(isValueCompatibleWithIntConstraint(.unknown, .eq, 5));
}

test "isValueCompatibleWithNullCheck" {
    try std.testing.expect(isValueCompatibleWithNullCheck(.null_val, true));
    try std.testing.expect(!isValueCompatibleWithNullCheck(.null_val, false));
    try std.testing.expect(!isValueCompatibleWithNullCheck(.non_null, true));
    try std.testing.expect(isValueCompatibleWithNullCheck(.non_null, false));
    try std.testing.expect(isValueCompatibleWithNullCheck(.unknown, true));
    try std.testing.expect(isValueCompatibleWithNullCheck(.unknown, false));
}

test "ErrorState enum values" {
    const normal: ErrorState = .normal;
    const error_active: ErrorState = .error_active;
    const error_handled: ErrorState = .error_handled;

    try std.testing.expect(normal == .normal);
    try std.testing.expect(error_active == .error_active);
    try std.testing.expect(error_handled == .error_handled);
    try std.testing.expect(normal != error_active);
    try std.testing.expect(error_active != error_handled);
}

test "ProgramState error state operations" {
    const allocator = std.testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(ErrorState.normal, state.getErrorState());
    try std.testing.expect(state.isNormalPath());
    try std.testing.expect(!state.isErrorPath());

    state.setErrorState(.error_active);
    try std.testing.expectEqual(ErrorState.error_active, state.getErrorState());
    try std.testing.expect(state.isErrorPath());
    try std.testing.expect(!state.isNormalPath());

    state.setErrorState(.error_handled);
    try std.testing.expectEqual(ErrorState.error_handled, state.getErrorState());
    try std.testing.expect(!state.isErrorPath());
    try std.testing.expect(!state.isNormalPath());

    state.setErrorState(.normal);
    try std.testing.expect(state.isNormalPath());
}

test "ProgramState clone preserves error state" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    state1.setErrorState(.error_active);

    var state2 = try state1.clone(allocator);
    defer state2.deinit();

    try std.testing.expectEqual(state1.getErrorState(), state2.getErrorState());
    try std.testing.expect(state1.eql(&state2));
}

test "ProgramState equality includes error state" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try std.testing.expect(state1.eql(&state2));

    state2.setErrorState(.error_active);
    try std.testing.expect(!state1.eql(&state2));

    state1.setErrorState(.error_active);
    try std.testing.expect(state1.eql(&state2));
}

test "ProgramState hash includes error state" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    const hash1_initial = state1.computeHash();
    const hash2_initial = state2.computeHash();
    try std.testing.expectEqual(hash1_initial, hash2_initial);

    state2.setErrorState(.error_active);
    const hash2_after = state2.computeHash();
    try std.testing.expect(hash1_initial != hash2_after);
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

// ============== Interprocedural Inlining Tests ==============

test "ProgramState inline depth operations" {
    const allocator = std.testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(u32, 0), state.getInlineDepth());
    try std.testing.expect(!state.isInlined());

    state.incrementInlineDepth();
    try std.testing.expectEqual(@as(u32, 1), state.getInlineDepth());
    try std.testing.expect(state.isInlined());

    state.incrementInlineDepth();
    try std.testing.expectEqual(@as(u32, 2), state.getInlineDepth());

    state.decrementInlineDepth();
    try std.testing.expectEqual(@as(u32, 1), state.getInlineDepth());

    state.decrementInlineDepth();
    try std.testing.expectEqual(@as(u32, 0), state.getInlineDepth());
    try std.testing.expect(!state.isInlined());

    // Decrementing at 0 should stay at 0
    state.decrementInlineDepth();
    try std.testing.expectEqual(@as(u32, 0), state.getInlineDepth());
}

test "ProgramState call stack operations" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.peekCallSite() == null);
    try std.testing.expect(state.popCallSite() == null);

    const call_site1 = CallSite{
        .call_node = 5,
        .caller_cfg = &cfg,
        .return_node = 6,
    };

    try state.pushCallSite(call_site1);
    try std.testing.expect(state.peekCallSite() != null);
    try std.testing.expectEqual(@as(u32, 5), state.peekCallSite().?.call_node);

    const call_site2 = CallSite{
        .call_node = 10,
        .caller_cfg = &cfg,
        .return_node = 11,
    };

    try state.pushCallSite(call_site2);
    try std.testing.expectEqual(@as(u32, 10), state.peekCallSite().?.call_node);

    // Pop should return the most recent call site
    const popped = state.popCallSite();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u32, 10), popped.?.call_node);

    // Now the first call site should be on top
    try std.testing.expectEqual(@as(u32, 5), state.peekCallSite().?.call_node);
}

test "ProgramState clone preserves inline depth and call stack" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    state1.incrementInlineDepth();
    state1.incrementInlineDepth();
    try state1.pushCallSite(.{
        .call_node = 5,
        .caller_cfg = &cfg,
        .return_node = 6,
    });

    var state2 = try state1.clone(allocator);
    defer state2.deinit();

    try std.testing.expectEqual(state1.getInlineDepth(), state2.getInlineDepth());
    try std.testing.expect(state1.eql(&state2));
    try std.testing.expectEqual(@as(u32, 5), state2.peekCallSite().?.call_node);
}

test "ProgramState equality includes inline depth" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try std.testing.expect(state1.eql(&state2));

    state2.incrementInlineDepth();
    try std.testing.expect(!state1.eql(&state2));

    state1.incrementInlineDepth();
    try std.testing.expect(state1.eql(&state2));
}

test "ProgramState hash includes inline depth" {
    const allocator = std.testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    const hash1_initial = state1.computeHash();
    const hash2_initial = state2.computeHash();
    try std.testing.expectEqual(hash1_initial, hash2_initial);

    state2.incrementInlineDepth();
    const hash2_after = state2.computeHash();
    try std.testing.expect(hash1_initial != hash2_after);
}

test "AnalysisEngine max inline depth configuration" {
    const allocator = std.testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try std.testing.expectEqual(DEFAULT_MAX_INLINE_DEPTH, engine.max_inline_depth);

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
    var fn_node: ?u32 = null;
    for (tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            fn_node = @intCast(i);
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
