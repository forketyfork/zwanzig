const std = @import("std");
const ids = @import("../ids.zig");
const AbstractValue = @import("value.zig").AbstractValue;
const Environment = @import("env.zig").Environment;
const VarId = ids.VarId;

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
        var_id: VarId,
        op: CompareOp,
        value: i64,
    },
    /// Variable compared to null: var == null or var != null
    null_check: struct {
        var_id: VarId,
        is_null: bool, // true = var is null, false = var is non-null
    },
    /// Variable compared to another variable: var1 <op> var2
    var_compare: struct {
        var1_id: VarId,
        op: CompareOp,
        var2_id: VarId,
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
                const var_id = ids.varIndex(ic.var_id);
                hasher.update(std.mem.asBytes(&var_id));
                hasher.update(std.mem.asBytes(&ic.op));
                hasher.update(std.mem.asBytes(&ic.value));
            },
            .null_check => |nc| {
                const var_id = ids.varIndex(nc.var_id);
                hasher.update(std.mem.asBytes(&var_id));
                hasher.update(std.mem.asBytes(&nc.is_null));
            },
            .var_compare => |vc| {
                const var1_id = ids.varIndex(vc.var1_id);
                const var2_id = ids.varIndex(vc.var2_id);
                hasher.update(std.mem.asBytes(&var1_id));
                hasher.update(std.mem.asBytes(&vc.op));
                hasher.update(std.mem.asBytes(&var2_id));
            },
        }
        return hasher.final();
    }

    /// Create an integer comparison constraint.
    pub fn intCompare(var_id: VarId, op: CompareOp, value: i64) Constraint {
        return .{ .int_compare = .{ .var_id = var_id, .op = op, .value = value } };
    }

    /// Create a null check constraint.
    pub fn nullCheck(var_id: VarId, is_null: bool) Constraint {
        return .{ .null_check = .{ .var_id = var_id, .is_null = is_null } };
    }

    /// Create a variable comparison constraint.
    pub fn varCompare(var1_id: VarId, op: CompareOp, var2_id: VarId) Constraint {
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
        errdefer new_cm.deinit();
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

test "Constraint creation and equality" {
    const testing = std.testing;

    const c1 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const c2 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const c3 = Constraint.intCompare(ids.varId(1), .ne, 42);

    try testing.expect(c1.eql(c2));
    try testing.expect(!c1.eql(c3));
}

test "Constraint negation" {
    const testing = std.testing;

    const c1 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const neg = c1.negate();
    try testing.expect(neg.eql(Constraint.intCompare(ids.varId(1), .ne, 42)));

    const c2 = Constraint.nullCheck(ids.varId(2), true);
    const neg2 = c2.negate();
    try testing.expect(neg2.eql(Constraint.nullCheck(ids.varId(2), false)));
}

test "ConstraintManager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try testing.expectEqual(@as(usize, 0), cm.size());

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.nullCheck(ids.varId(2), true));

    try testing.expectEqual(@as(usize, 2), cm.size());
}

test "ConstraintManager cloning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.nullCheck(ids.varId(2), true));

    var cm2 = try cm.clone();
    defer cm2.deinit();

    try testing.expect(cm.eql(&cm2));
}

test "ConstraintManager satisfiability with environment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .{ .concrete_int = 42 });

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));

    try testing.expect(cm.isSatisfiable(&env));

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 43));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager null check satisfiability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .null_val);

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.nullCheck(ids.varId(1), true));
    try testing.expect(cm.isSatisfiable(&env));

    try cm.addConstraint(Constraint.nullCheck(ids.varId(1), false));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager contradictory constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .{ .concrete_int = 42 });

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .ne, 42));

    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager refineValue for int constraint" {
    const testing = std.testing;

    const refined = ConstraintManager.refineValue(.unknown, Constraint.intCompare(ids.varId(1), .eq, 42));
    try testing.expect(refined != null);
    try testing.expect(refined.?.eql(.{ .concrete_int = 42 }));
}

test "ConstraintManager refineValue for null constraint" {
    const testing = std.testing;

    const refined = ConstraintManager.refineValue(.unknown, Constraint.nullCheck(ids.varId(1), true));
    try testing.expect(refined != null);
    try testing.expect(refined.?.eql(.null_val));
}

test "areIntConstraintsContradictory" {
    const testing = std.testing;

    try testing.expect(areIntConstraintsContradictory(.eq, 5, .eq, 6));
    try testing.expect(areIntConstraintsContradictory(.eq, 5, .ne, 5));
    try testing.expect(areIntConstraintsContradictory(.lt, 5, .ge, 5));
    try testing.expect(!areIntConstraintsContradictory(.lt, 5, .gt, 1));
}

test "isValueCompatibleWithIntConstraint" {
    const testing = std.testing;

    const val: AbstractValue = .{ .concrete_int = 10 };
    try testing.expect(isValueCompatibleWithIntConstraint(val, .eq, 10));
    try testing.expect(!isValueCompatibleWithIntConstraint(val, .eq, 11));
}

test "isValueCompatibleWithNullCheck" {
    const testing = std.testing;

    const null_val: AbstractValue = .null_val;
    try testing.expect(isValueCompatibleWithNullCheck(null_val, true));
    try testing.expect(!isValueCompatibleWithNullCheck(null_val, false));
}
