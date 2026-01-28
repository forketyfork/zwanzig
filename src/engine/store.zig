const std = @import("std");
const ids = @import("../ids.zig");

const VarId = ids.VarId;

pub const ResourceState = enum {
    unknown,
    allocated,
    freed,
    non_allocated,
    open,
    closed,
};

pub const StoreViolationKind = enum {
    double_free,
    free_without_alloc,
};

pub const StoreViolation = struct {
    region: VarId,
    kind: StoreViolationKind,
    call_token: ?u32,

    pub fn eql(self: StoreViolation, other: StoreViolation) bool {
        return self.region == other.region and self.kind == other.kind and self.call_token == other.call_token;
    }

    pub fn hash(self: StoreViolation) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const region_index = ids.varIndex(self.region);
        hasher.update(std.mem.asBytes(&region_index));
        hasher.update(std.mem.asBytes(&self.kind));
        const has_token: u8 = if (self.call_token) |_| 1 else 0;
        hasher.update(std.mem.asBytes(&has_token));
        if (self.call_token) |token| {
            hasher.update(std.mem.asBytes(&token));
        }
        return hasher.final();
    }
};

pub const Store = struct {
    resources: std.AutoHashMap(VarId, ResourceState),
    violations: std.ArrayList(StoreViolation),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .resources = std.AutoHashMap(VarId, ResourceState).init(allocator),
            .violations = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        self.resources.deinit();
        self.violations.deinit(self.allocator);
    }

    pub fn clone(self: *const Store, allocator: std.mem.Allocator) !Store {
        var new_store = Store.init(allocator);
        errdefer new_store.deinit();

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            try new_store.resources.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        for (self.violations.items) |violation| {
            try new_store.violations.append(allocator, violation);
        }

        return new_store;
    }

    pub fn eql(self: *const Store, other: *const Store) bool {
        if (self.resources.count() != other.resources.count()) return false;
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            if (other.resources.get(entry.key_ptr.*)) |other_state| {
                if (entry.value_ptr.* != other_state) return false;
            } else {
                return false;
            }
        }

        if (self.violations.items.len != other.violations.items.len) return false;
        for (self.violations.items, other.violations.items) |lhs, rhs| {
            if (!lhs.eql(rhs)) return false;
        }

        return true;
    }

    pub fn computeHash(self: *const Store) u64 {
        var resources_hash: u64 = 0;

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&entry.value_ptr.*));
            resources_hash ^= hasher.final();
        }

        var hasher = std.hash.Wyhash.init(0);
        const resources_count = self.resources.count();
        const violations_len = self.violations.items.len;
        hasher.update(std.mem.asBytes(&resources_hash));
        hasher.update(std.mem.asBytes(&resources_count));
        hasher.update(std.mem.asBytes(&violations_len));
        for (self.violations.items) |violation| {
            const violation_hash = violation.hash();
            hasher.update(std.mem.asBytes(&violation_hash));
        }

        return hasher.final();
    }

    pub fn getState(self: *const Store, region: VarId) ?ResourceState {
        return self.resources.get(region);
    }

    pub fn markAllocated(self: *Store, region: VarId) !void {
        try self.resources.put(region, .allocated);
    }

    pub fn markNonAllocated(self: *Store, region: VarId) !void {
        try self.resources.put(region, .non_allocated);
    }

    pub fn markFreed(self: *Store, region: VarId, call_token: ?u32) !void {
        if (self.resources.get(region)) |state| {
            switch (state) {
                .freed => {
                    try self.recordViolation(region, .double_free, call_token);
                },
                .non_allocated => {
                    try self.recordViolation(region, .free_without_alloc, call_token);
                },
                .allocated => {
                    try self.resources.put(region, .freed);
                },
                else => {},
            }
            return;
        }
    }

    pub fn violationCount(self: *const Store) usize {
        return self.violations.items.len;
    }

    pub fn getViolations(self: *const Store) []const StoreViolation {
        return self.violations.items;
    }

    fn recordViolation(self: *Store, region: VarId, kind: StoreViolationKind, call_token: ?u32) !void {
        try self.violations.append(self.allocator, .{
            .region = region,
            .kind = kind,
            .call_token = call_token,
        });
    }
};

test "Store tracks allocation/free transitions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(10);

    try store.markAllocated(region);
    try testing.expectEqual(ResourceState.allocated, store.getState(region).?);

    try store.markFreed(region, 1);
    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 0), store.violationCount());
}

test "Store records double free violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(11);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markFreed(region, 2);

    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.double_free, store.getViolations()[0].kind);
}

test "Store records free without alloc violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(13);

    try store.markNonAllocated(region);
    try store.markFreed(region, 1);

    try testing.expectEqual(ResourceState.non_allocated, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.free_without_alloc, store.getViolations()[0].kind);
}

test "Store hash accounts for repeated violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(12);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markFreed(region, 2);
    const hash_after_double = store.computeHash();

    try store.markFreed(region, 3);
    const hash_after_triple = store.computeHash();

    try testing.expect(hash_after_double != hash_after_triple);
}
