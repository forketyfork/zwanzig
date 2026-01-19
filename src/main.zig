const std = @import("std");
const Analyzer = @import("analyzer.zig").Analyzer;
const Rule = @import("rule.zig").Rule;
const EmptyCatchRule = @import("rules/empty_catch.zig").EmptyCatchRule;
const RuleFilter = @import("rule_filter.zig").RuleFilter;

pub const CliArgs = struct {
    files: []const []const u8,
    rule_filter: RuleFilter,
};

pub const CliError = error{
    MutuallyExclusiveFlags,
    MissingFlagValue,
    NoFilesProvided,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) CliError!CliArgs {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(allocator);

    var do_rules: std.ArrayList([]const u8) = .empty;
    errdefer do_rules.deinit(allocator);

    var skip_rules: std.ArrayList([]const u8) = .empty;
    errdefer skip_rules.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--do")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try do_rules.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try skip_rules.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            continue;
        } else {
            try files.append(allocator, arg);
        }
    }

    if (do_rules.items.len > 0 and skip_rules.items.len > 0) {
        return CliError.MutuallyExclusiveFlags;
    }

    const rule_filter: RuleFilter = if (do_rules.items.len > 0)
        .{ .allowlist = try do_rules.toOwnedSlice(allocator) }
    else if (skip_rules.items.len > 0)
        .{ .blocklist = try skip_rules.toOwnedSlice(allocator) }
    else
        .none;

    return CliArgs{
        .files = try files.toOwnedSlice(allocator),
        .rule_filter = rule_filter,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli_args = parseArgs(allocator, args) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            CliError.MutuallyExclusiveFlags => {
                try stderr.writeAll("Error: --do and --skip are mutually exclusive\n");
            },
            CliError.MissingFlagValue => {
                try stderr.writeAll("Error: Flag requires a value\n");
            },
            CliError.NoFilesProvided => {
                try stderr.writeAll("Error: No files provided\n");
            },
            CliError.OutOfMemory => {
                try stderr.writeAll("Error: Out of memory\n");
            },
        }
        std.process.exit(1);
    };
    defer {
        allocator.free(cli_args.files);
        switch (cli_args.rule_filter) {
            .allowlist => |list| allocator.free(list),
            .blocklist => |list| allocator.free(list),
            .none => {},
        }
    }

    if (cli_args.files.len == 0) {
        try printUsage();
        return;
    }

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try analyzer.registerRule(&EmptyCatchRule.rule);

    analyzer.setRuleFilter(cli_args.rule_filter);

    for (cli_args.files) |file_path| {
        try analyzer.analyzeFile(file_path);
    }

    try analyzer.printResults();

    if (analyzer.hasViolations()) {
        std.process.exit(1);
    }
}

fn printUsage() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("Usage: zwanzig [options] <file.zig> [file.zig...]\n");
    try stderr.writeAll("\nA static analyzer for Zig code.\n");
    try stderr.writeAll("\nOptions:\n");
    try stderr.writeAll("  --do <rule>    Only run the specified rule (can be repeated)\n");
    try stderr.writeAll("  --skip <rule>  Skip the specified rule (can be repeated)\n");
    try stderr.writeAll("\n  Note: --do and --skip are mutually exclusive.\n");
    try stderr.writeAll("\nArguments:\n");
    try stderr.writeAll("  <file.zig>     Zig source file(s) to analyze\n");
}

fn freeCliArgs(allocator: std.mem.Allocator, cli_args: CliArgs) void {
    allocator.free(cli_args.files);
    switch (cli_args.rule_filter) {
        .allowlist => |list| allocator.free(list),
        .blocklist => |list| allocator.free(list),
        .none => {},
    }
}

test "parseArgs: files only" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("file1.zig", result.files[0]);
    try std.testing.expectEqualStrings("file2.zig", result.files[1]);
    try std.testing.expectEqual(RuleFilter.none, result.rule_filter);
}

test "parseArgs: --do flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "empty-catch", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("file.zig", result.files[0]);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: multiple --do flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "empty-catch", "--do", "unused-var", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("unused-var", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: --skip flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "empty-catch", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.files.len);

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: multiple --skip flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "empty-catch", "--skip", "unused-var", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("unused-var", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: --do and --skip mutually exclusive" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "rule1", "--skip", "rule2", "file.zig" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MutuallyExclusiveFlags, result);
}

test "parseArgs: --do without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --skip without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --do with flag as value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "--skip", "rule" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --skip with flag as value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "--do", "rule" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: files before and after flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "--do", "empty-catch", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("file1.zig", result.files[0]);
    try std.testing.expectEqualStrings("file2.zig", result.files[1]);
}

test "Analyzer.isRuleEnabled: no filter" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(analyzer.isRuleEnabled("any-rule"));
}

test "Analyzer.isRuleEnabled: allowlist" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{ "empty-catch", "unused-var" };
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    try std.testing.expect(analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(analyzer.isRuleEnabled("unused-var"));
    try std.testing.expect(!analyzer.isRuleEnabled("other-rule"));
}

test "Analyzer.isRuleEnabled: blocklist" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const blocklist = [_][]const u8{ "empty-catch", "unused-var" };
    analyzer.setRuleFilter(.{ .blocklist = &blocklist });

    try std.testing.expect(!analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(!analyzer.isRuleEnabled("unused-var"));
    try std.testing.expect(analyzer.isRuleEnabled("other-rule"));
}
