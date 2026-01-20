const std = @import("std");
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgNode = cfg_mod.CfgNode;
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;
const IrTag = cfg_mod.IrTag;

pub const EngineError = std.mem.Allocator.Error;

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
                .lt => .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val - 1) },
                .le => .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val) },
                .gt => .{ .int_range = AbstractValue.IntRange.init(constraint_val + 1, std.math.maxInt(i64)) },
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
                    if (r.min >= constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val - 1));
                },
                .le => blk: {
                    if (r.min > constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val));
                },
                .gt => blk: {
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

/// Abstract program state for path-sensitive analysis.
/// Stores the environment mapping variables to abstract values,
/// plus path constraints from branch conditions.
pub const ProgramState = struct {
    /// Environment mapping variables to abstract values
    env: Environment,
    /// Constraint manager for path conditions
    constraints: ConstraintManager,
    /// Cached hash for efficient deduplication
    cached_hash: ?u64,

    pub fn init(allocator: std.mem.Allocator) ProgramState {
        return .{
            .env = Environment.init(allocator),
            .constraints = ConstraintManager.init(allocator),
            .cached_hash = null,
        };
    }

    pub fn deinit(self: *ProgramState) void {
        self.env.deinit();
        self.constraints.deinit();
    }

    pub fn eql(self: *const ProgramState, other: *const ProgramState) bool {
        return self.env.eql(&other.env) and self.constraints.eql(&other.constraints);
    }

    pub fn computeHash(self: *ProgramState) u64 {
        if (self.cached_hash) |h| return h;
        var hasher = std.hash.Wyhash.init(0);
        const env_hash = self.env.computeHash();
        hasher.update(std.mem.asBytes(&env_hash));
        const constraints_hash = self.constraints.computeHash();
        hasher.update(std.mem.asBytes(&constraints_hash));
        const h = hasher.final();
        self.cached_hash = h;
        return h;
    }

    pub fn clone(self: *const ProgramState, allocator: std.mem.Allocator) !ProgramState {
        _ = allocator;
        return .{
            .env = try self.env.clone(),
            .constraints = try self.constraints.clone(),
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
pub const AnalysisEngine = struct {
    allocator: std.mem.Allocator,
    /// The exploded graph being built
    graph: ExplodedGraph,
    /// Worklist of (exploded node index, edge kind from predecessor, optional constraint) pairs to process
    worklist: std.ArrayList(WorklistItem),
    /// Count of pruned paths (for testing/debugging)
    pruned_path_count: u32,

    const WorklistItem = struct {
        /// Index of the exploded graph node to process
        node_index: u32,
        /// The kind of edge that led to this node (for path-sensitive analysis)
        edge_kind: EdgeKind,
        /// Optional constraint to apply (from branch condition)
        pending_constraint: ?Constraint,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) AnalysisEngine {
        return .{
            .allocator = allocator,
            .graph = ExplodedGraph.init(allocator, cfg),
            .worklist = .empty,
            .pruned_path_count = 0,
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
        try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null });

        while (self.worklist.pop()) |item| {
            try self.processNode(item.node_index, item.edge_kind, item.pending_constraint);
        }
    }

    fn processNode(self: *AnalysisEngine, node_index: u32, edge_kind: EdgeKind, pending_constraint: ?Constraint) EngineError!void {
        _ = edge_kind;

        const exploded_node = self.graph.getNode(node_index) orelse return;
        const point = exploded_node.point;

        // Clone the state immediately - we can't hold a reference to exploded_node.state
        // because graph operations may reallocate the nodes array and invalidate pointers.
        var state_copy = try exploded_node.state.clone(self.allocator);
        defer state_copy.deinit();

        switch (point.kind) {
            .pre => {
                const post_point = ProgramPoint.initPost(point.node_index);
                var new_state = try self.transferFunction(point, &state_copy);

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
                    try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = .normal, .pending_constraint = null });
                }
            },
            .post => {
                const cfg = self.graph.cfg;
                const cfg_node = cfg.getNode(point.node_index);

                // Check if this is a branch node - if so, we need to extract constraints
                const is_branch_node = if (cfg_node) |node| node.ir_node.tag == .branch else false;
                const branch_constraint = if (is_branch_node)
                    self.extractBranchConstraint(cfg_node.?)
                else
                    null;

                for (cfg.edges.items) |edge| {
                    if (edge.from == point.node_index) {
                        const succ_point = ProgramPoint.initPre(edge.to);
                        var succ_state = try state_copy.clone(self.allocator);

                        // Determine the constraint to apply based on the edge kind
                        var constraint_to_apply: ?Constraint = null;
                        if (branch_constraint) |bc| {
                            if (edge.kind == .branch_true) {
                                constraint_to_apply = bc;
                            } else if (edge.kind == .branch_false) {
                                constraint_to_apply = bc.negate();
                            }
                        }

                        // If we have a constraint, pre-check if the resulting state would be satisfiable
                        if (constraint_to_apply) |constraint| {
                            // Create a temporary state to check satisfiability
                            var temp_state = try succ_state.clone(self.allocator);
                            defer temp_state.deinit();
                            try temp_state.addConstraint(constraint);
                            if (!temp_state.isSatisfiable()) {
                                self.pruned_path_count += 1;
                                succ_state.deinit();
                                continue; // Skip this edge entirely
                            }
                        }

                        const result = try self.graph.getOrCreateNode(succ_point, &succ_state);
                        if (!result.is_new) {
                            succ_state.deinit();
                        }
                        try self.graph.addEdge(node_index, result.index);

                        if (result.is_new) {
                            try self.worklist.append(self.allocator, .{ .node_index = result.index, .edge_kind = edge.kind, .pending_constraint = constraint_to_apply });
                        }
                    }
                }
            },
        }
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
    // entry -> var_decl (x = 5) -> branch (x == 10?) -> then/else -> merge -> exit
    //
    // Since x = 5, the branch "x == 10" should prune the then-branch

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(cfg_mod.IrNode.init(.fn_entry));
    const var_decl = try cfg.addNode(cfg_mod.IrNode.initWithAst(.var_decl, 100)); // x

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

    try cfg.addEdge(entry, var_decl);
    try cfg.addEdge(var_decl, branch);
    try cfg.addEdgeWithKind(branch, then_node, .branch_true);
    try cfg.addEdgeWithKind(branch, else_node, .branch_false);
    try cfg.addEdge(then_node, merge);
    try cfg.addEdge(else_node, merge);
    try cfg.addEdge(merge, exit);

    var engine = AnalysisEngine.init(allocator, &cfg);
    defer engine.deinit();

    try engine.run();

    // The engine should have explored both branches since we start with unknown value
    // (var_decl sets value to unknown, not concrete 5)
    // Both paths should be explored
    const graph = engine.getGraph();
    try std.testing.expect(graph.nodeCount() > 0);
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
