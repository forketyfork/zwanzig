const std = @import("std");
const ids = @import("../ids.zig");
const AbstractValue = @import("value.zig").AbstractValue;
pub const VarId = ids.VarId;

/// Environment: mapping from variables to abstract values.
/// Represents the known values of variables at a program point.
pub const Environment = struct {
    /// Map from variable ID to abstract value
    bindings: std.AutoHashMap(VarId, AbstractValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .bindings = std.AutoHashMap(VarId, AbstractValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
    }

    pub fn clone(self: *const Environment) !Environment {
        var new_env = Environment.init(self.allocator);
        errdefer new_env.deinit();
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            try new_env.bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_env;
    }

    pub fn get(self: *const Environment, var_id: VarId) ?AbstractValue {
        return self.bindings.get(var_id);
    }

    pub fn set(self: *Environment, var_id: VarId, value: AbstractValue) !void {
        try self.bindings.put(var_id, value);
    }

    pub fn remove(self: *Environment, var_id: VarId) void {
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
            const key = ids.varIndex(entry.key_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            const val_hash = entry.value_ptr.*.hash();
            hasher.update(std.mem.asBytes(&val_hash));
            combined_hash ^= hasher.final();
        }

        return combined_hash;
    }
};

test "Environment operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try testing.expectEqual(@as(usize, 0), env.size());
    try testing.expect(env.get(ids.varId(1)) == null);

    try env.set(ids.varId(1), .{ .concrete_int = 42 });
    try testing.expectEqual(@as(usize, 1), env.size());

    const val = env.get(ids.varId(1));
    try testing.expect(val != null);
    try testing.expect(val.?.eql(.{ .concrete_int = 42 }));

    try env.set(ids.varId(2), .non_null);
    try testing.expectEqual(@as(usize, 2), env.size());

    env.remove(ids.varId(1));
    try testing.expectEqual(@as(usize, 1), env.size());
    try testing.expect(env.get(ids.varId(1)) == null);
}

test "Environment equality and cloning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env1 = Environment.init(allocator);
    defer env1.deinit();

    try env1.set(ids.varId(1), .{ .concrete_int = 10 });
    try env1.set(ids.varId(2), .non_null);

    var env2 = try env1.clone();
    defer env2.deinit();

    try testing.expect(env1.eql(&env2));

    try env2.set(ids.varId(1), .{ .concrete_int = 20 });
    try testing.expect(!env1.eql(&env2));
}
