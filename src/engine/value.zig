const std = @import("std");

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
