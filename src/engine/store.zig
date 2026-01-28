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
    double_close,
    close_without_open,
    use_after_free,
    use_after_close,
    resource_leak,
};

const DeferredAction = enum {
    free,
    close,
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
    aliases: std.AutoHashMap(VarId, VarId),
    deferred: std.AutoHashMap(VarId, DeferredAction),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .resources = std.AutoHashMap(VarId, ResourceState).init(allocator),
            .violations = .empty,
            .aliases = std.AutoHashMap(VarId, VarId).init(allocator),
            .deferred = std.AutoHashMap(VarId, DeferredAction).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        self.resources.deinit();
        self.violations.deinit(self.allocator);
        self.aliases.deinit();
        self.deferred.deinit();
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

        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            try new_store.aliases.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            try new_store.deferred.put(entry.key_ptr.*, entry.value_ptr.*);
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
        for (self.violations.items) |lhs| {
            var found = false;
            for (other.violations.items) |rhs| {
                if (lhs.eql(rhs)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        if (self.aliases.count() != other.aliases.count()) return false;
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            if (other.aliases.get(entry.key_ptr.*)) |other_target| {
                if (entry.value_ptr.* != other_target) return false;
            } else {
                return false;
            }
        }

        if (self.deferred.count() != other.deferred.count()) return false;
        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            if (other.deferred.get(entry.key_ptr.*)) |other_action| {
                if (entry.value_ptr.* != other_action) return false;
            } else {
                return false;
            }
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

        var violations_hash: u64 = 0;
        for (self.violations.items) |violation| {
            violations_hash ^= violation.hash();
        }

        var aliases_hash: u64 = 0;
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            const value = ids.varIndex(entry.value_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&value));
            aliases_hash ^= hasher.final();
        }

        var deferred_hash: u64 = 0;
        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&entry.value_ptr.*));
            deferred_hash ^= hasher.final();
        }

        var hasher = std.hash.Wyhash.init(0);
        const resources_count = self.resources.count();
        const violations_len = self.violations.items.len;
        hasher.update(std.mem.asBytes(&resources_hash));
        hasher.update(std.mem.asBytes(&violations_hash));
        hasher.update(std.mem.asBytes(&aliases_hash));
        hasher.update(std.mem.asBytes(&deferred_hash));
        hasher.update(std.mem.asBytes(&resources_count));
        hasher.update(std.mem.asBytes(&violations_len));
        const aliases_count = self.aliases.count();
        const deferred_count = self.deferred.count();
        hasher.update(std.mem.asBytes(&aliases_count));
        hasher.update(std.mem.asBytes(&deferred_count));

        return hasher.final();
    }

    pub fn getState(self: *const Store, region: VarId) ?ResourceState {
        const root = self.canonical(region);
        return self.resources.get(root);
    }

    pub fn markAllocated(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        try self.resources.put(region, .allocated);
    }

    pub fn markOpened(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        try self.resources.put(region, .open);
    }

    pub fn markNonAllocated(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        try self.resources.put(region, .non_allocated);
    }

    pub fn resetRegion(self: *Store, region: VarId) void {
        if (self.aliases.get(region)) |_| {
            _ = self.aliases.remove(region);
            return;
        }
        const root = self.canonical(region);
        var has_alias = false;
        var new_root: VarId = root;
        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == root) {
                if (!has_alias) {
                    has_alias = true;
                    new_root = entry.key_ptr.*;
                } else if (ids.varIndex(entry.key_ptr.*) < ids.varIndex(new_root)) {
                    new_root = entry.key_ptr.*;
                }
            }
        }

        if (!has_alias) {
            _ = self.resources.remove(root);
            _ = self.deferred.remove(root);
            return;
        }

        if (self.resources.get(root)) |state| {
            _ = self.resources.remove(root);
            _ = self.resources.remove(new_root);
            self.resources.put(new_root, state) catch {
                _ = self.resources.remove(new_root);
            };
        } else {
            _ = self.resources.remove(new_root);
        }

        if (self.deferred.get(root)) |action| {
            _ = self.deferred.remove(root);
            _ = self.deferred.remove(new_root);
            self.deferred.put(new_root, action) catch {
                _ = self.deferred.remove(new_root);
            };
        } else {
            _ = self.deferred.remove(new_root);
        }

        var update_iter = self.aliases.iterator();
        while (update_iter.next()) |entry| {
            if (entry.value_ptr.* == root) {
                entry.value_ptr.* = new_root;
            }
        }
        _ = self.aliases.remove(new_root);
    }

    pub fn escapeRegion(self: *Store, region: VarId) void {
        const root = self.canonical(region);
        _ = self.resources.remove(root);
        _ = self.deferred.remove(root);
        _ = self.aliases.remove(region);
    }

    pub fn escapeByName(self: *Store, tree: *const std.zig.Ast, name: []const u8) std.mem.Allocator.Error!void {
        var to_remove: std.ArrayList(VarId) = .empty;
        defer to_remove.deinit(self.allocator);

        const token_tags = tree.tokens.items(.tag);
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            const token = ids.varIndex(entry.key_ptr.*);
            if (token >= token_tags.len or token_tags[token] != .identifier) continue;
            if (std.mem.eql(u8, tree.tokenSlice(token), name)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            _ = self.resources.remove(key);
            _ = self.deferred.remove(key);
            _ = self.aliases.remove(key);
        }
    }

    pub fn markFreed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |action| {
            if (action == .free) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            switch (state) {
                .freed => try self.recordViolation(root, .double_free, call_token),
                .non_allocated => try self.recordViolation(root, .free_without_alloc, call_token),
                .open, .closed => try self.recordViolation(root, .free_without_alloc, call_token),
                .allocated => {},
                else => {},
            }
            try self.resources.put(root, .freed);
        } else {
            try self.resources.put(root, .freed);
        }
        _ = self.deferred.remove(root);
    }

    pub fn markClosed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |action| {
            if (action == .close) {
                try self.recordViolation(root, .double_close, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            switch (state) {
                .closed => try self.recordViolation(root, .double_close, call_token),
                .open => {},
                .non_allocated, .allocated, .freed => try self.recordViolation(root, .close_without_open, call_token),
                else => {},
            }
            try self.resources.put(root, .closed);
        } else {
            try self.resources.put(root, .closed);
        }
        _ = self.deferred.remove(root);
    }

    pub fn markUsed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.resources.get(root)) |state| {
            switch (state) {
                .freed => try self.recordViolation(root, .use_after_free, call_token),
                .closed => try self.recordViolation(root, .use_after_close, call_token),
                else => {},
            }
        }
    }

    pub fn markDeferredFree(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |action| {
            if (action == .free) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            if (state == .non_allocated) {
                try self.recordViolation(root, .free_without_alloc, call_token);
            }
        }
        try self.deferred.put(root, .free);
    }

    pub fn markDeferredClose(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |action| {
            if (action == .close) {
                try self.recordViolation(root, .double_close, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            if (state != .open) {
                try self.recordViolation(root, .close_without_open, call_token);
            }
        }
        try self.deferred.put(root, .close);
    }

    pub fn recordLeaks(self: *Store) !void {
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .allocated => {
                    if (self.deferred.get(entry.key_ptr.*)) |action| {
                        if (action == .free) continue;
                    }
                    try self.recordViolation(entry.key_ptr.*, .resource_leak, ids.varIndex(entry.key_ptr.*));
                },
                .open => {
                    if (self.deferred.get(entry.key_ptr.*)) |action| {
                        if (action == .close) continue;
                    }
                    try self.recordViolation(entry.key_ptr.*, .resource_leak, ids.varIndex(entry.key_ptr.*));
                },
                else => {},
            }
        }
    }

    pub fn violationCount(self: *const Store) usize {
        return self.violations.items.len;
    }

    pub fn getViolations(self: *const Store) []const StoreViolation {
        return self.violations.items;
    }

    fn recordViolation(self: *Store, region: VarId, kind: StoreViolationKind, call_token: ?u32) !void {
        const violation = StoreViolation{
            .region = region,
            .kind = kind,
            .call_token = call_token,
        };
        for (self.violations.items) |existing| {
            if (existing.eql(violation)) return;
        }
        try self.violations.append(self.allocator, violation);
    }

    fn canonical(self: *const Store, region: VarId) VarId {
        var current = region;
        var next_opt = self.aliases.get(current);
        while (next_opt) |next| : (next_opt = self.aliases.get(current)) {
            if (next == current) break;
            current = next;
        }
        return current;
    }

    pub fn aliasRegion(self: *Store, alias: VarId, target: VarId) !void {
        const root = self.canonical(target);
        try self.aliases.put(alias, root);
        _ = self.resources.remove(alias);
        _ = self.deferred.remove(alias);
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

    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.free_without_alloc, store.getViolations()[0].kind);
}

test "Store records close without open violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(14);

    try store.markNonAllocated(region);
    try store.markClosed(region, 1);

    try testing.expectEqual(ResourceState.closed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.close_without_open, store.getViolations()[0].kind);
}

test "Store records use after free violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(15);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markUsed(region, 2);

    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.use_after_free, store.getViolations()[0].kind);
}

test "Store preserves alias state when resetting root" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const root = ids.varId(21);
    const alias_a = ids.varId(22);
    const alias_b = ids.varId(23);

    try store.markAllocated(root);
    try store.aliasRegion(alias_a, root);
    try store.aliasRegion(alias_b, root);

    store.resetRegion(root);

    try testing.expectEqual(ResourceState.allocated, store.getState(alias_a).?);
    try testing.expectEqual(ResourceState.allocated, store.getState(alias_b).?);
    try testing.expect(store.getState(root) == null);
}

test "Store records leaks for allocated resources" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(16);

    try store.markAllocated(region);
    try store.recordLeaks();

    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.resource_leak, store.getViolations()[0].kind);
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
