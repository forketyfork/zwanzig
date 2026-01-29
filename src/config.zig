const std = @import("std");
const RuleFilter = @import("rule_filter.zig").RuleFilter;

pub const Config = struct {
    rule_filter: RuleFilter,
    max_worklist_steps: ?usize = null,
    max_states_per_point: ?u32 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        switch (self.rule_filter) {
            .allowlist => |list| {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            },
            .blocklist => |list| {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            },
            .none => {},
        }
    }
};

pub const ConfigError = error{
    FileNotFound,
    InvalidJson,
    InvalidConfigFormat,
    OutOfMemory,
    MutuallyExclusiveFields,
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) ConfigError!Config {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ConfigError.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return switch (err) {
            error.OutOfMemory => ConfigError.OutOfMemory,
            else => ConfigError.InvalidJson,
        };
    };
    defer allocator.free(content);

    return parseConfig(allocator, content);
}

pub fn parseConfig(allocator: std.mem.Allocator, content: []const u8) ConfigError!Config {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => ConfigError.OutOfMemory,
            else => ConfigError.InvalidJson,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return ConfigError.InvalidConfigFormat;
    }

    const obj = root.object;

    const enabled_rules = obj.get("enabled_rules");
    const disabled_rules = obj.get("disabled_rules");
    const max_worklist_steps_value = obj.get("max_worklist_steps");
    const max_states_per_point_value = obj.get("max_states_per_point");

    if (enabled_rules != null and disabled_rules != null) {
        return ConfigError.MutuallyExclusiveFields;
    }

    var max_worklist_steps: ?usize = null;
    if (max_worklist_steps_value) |value| {
        if (value != .integer) {
            return ConfigError.InvalidConfigFormat;
        }
        if (value.integer <= 0) {
            return ConfigError.InvalidConfigFormat;
        }
        max_worklist_steps = std.math.cast(usize, value.integer) orelse return ConfigError.InvalidConfigFormat;
    }

    var max_states_per_point: ?u32 = null;
    if (max_states_per_point_value) |value| {
        if (value != .integer) {
            return ConfigError.InvalidConfigFormat;
        }
        if (value.integer <= 0) {
            return ConfigError.InvalidConfigFormat;
        }
        max_states_per_point = std.math.cast(u32, value.integer) orelse return ConfigError.InvalidConfigFormat;
    }

    if (enabled_rules) |rules_value| {
        if (rules_value != .array) {
            return ConfigError.InvalidConfigFormat;
        }
        const rules_array = rules_value.array;

        var rule_names = try allocator.alloc([]const u8, rules_array.items.len);

        for (rules_array.items, 0..) |item, i| {
            if (item != .string) {
                for (rule_names[0..i]) |name| {
                    allocator.free(name);
                }
                allocator.free(rule_names);
                return ConfigError.InvalidConfigFormat;
            }
            rule_names[i] = try allocator.dupe(u8, item.string);
        }

        return Config{
            .rule_filter = .{ .allowlist = rule_names },
            .max_worklist_steps = max_worklist_steps,
            .max_states_per_point = max_states_per_point,
        };
    }

    if (disabled_rules) |rules_value| {
        if (rules_value != .array) {
            return ConfigError.InvalidConfigFormat;
        }
        const rules_array = rules_value.array;

        var rule_names = try allocator.alloc([]const u8, rules_array.items.len);

        for (rules_array.items, 0..) |item, i| {
            if (item != .string) {
                for (rule_names[0..i]) |name| {
                    allocator.free(name);
                }
                allocator.free(rule_names);
                return ConfigError.InvalidConfigFormat;
            }
            rule_names[i] = try allocator.dupe(u8, item.string);
        }

        return Config{
            .rule_filter = .{ .blocklist = rule_names },
            .max_worklist_steps = max_worklist_steps,
            .max_states_per_point = max_states_per_point,
        };
    }

    return Config{
        .rule_filter = .none,
        .max_worklist_steps = max_worklist_steps,
        .max_states_per_point = max_states_per_point,
    };
}

test "parseConfig: empty config" {
    const allocator = std.testing.allocator;
    const content = "{}";
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(RuleFilter.none, config.rule_filter);
}

test "parseConfig: enabled_rules" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch", "dupe-import"]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    switch (config.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("dupe-import", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseConfig: disabled_rules" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "disabled_rules": ["todo", "unused-decl"]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    switch (config.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("todo", list[0]);
            try std.testing.expectEqualStrings("unused-decl", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseConfig: mutual exclusion" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch"],
        \\  "disabled_rules": ["todo"]
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.MutuallyExclusiveFields, result);
}

test "parseConfig: invalid JSON" {
    const allocator = std.testing.allocator;
    const content = "{invalid json}";
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidJson, result);
}

test "parseConfig: not an object" {
    const allocator = std.testing.allocator;
    const content = "[]";
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "parseConfig: enabled_rules not an array" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": "empty-catch"
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "parseConfig: enabled_rules contains non-string" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch", 42]
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "loadConfig: file not found" {
    const allocator = std.testing.allocator;
    const result = loadConfig(allocator, "nonexistent.json");
    try std.testing.expectError(ConfigError.FileNotFound, result);
}
