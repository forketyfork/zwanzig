const std = @import("std");
const Analyzer = @import("analyzer.zig").Analyzer;
const Rule = @import("rule.zig").Rule;
const EmptyCatchRule = @import("rules/empty_catch.zig").EmptyCatchRule;
const DupeImportRule = @import("rules/dupe_import.zig").DupeImportRule;
const TodoCommentRule = @import("rules/todo_comment.zig").TodoCommentRule;
const FileAsStructRule = @import("rules/file_as_struct.zig").FileAsStructRule;
const UnusedDeclRule = @import("rules/unused_decl.zig").UnusedDeclRule;
const RuleFilter = @import("rule_filter.zig").RuleFilter;
const file_discovery = @import("file_discovery.zig");

test {
    _ = @import("ir.zig");
    _ = @import("cfg.zig");
    _ = @import("checker.zig");
    _ = @import("zir_bridge.zig");
    _ = @import("engine.zig");
}

pub const CliArgs = struct {
    paths: []const []const u8,
    rule_filter: RuleFilter,
};

pub const CliError = error{
    MutuallyExclusiveFlags,
    MissingFlagValue,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) CliError!CliArgs {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);

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
        } else if (std.mem.eql(u8, arg, "--file")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try paths.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            continue;
        } else {
            try paths.append(allocator, arg);
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
        .paths = try paths.toOwnedSlice(allocator),
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
            CliError.OutOfMemory => {
                try stderr.writeAll("Error: Out of memory\n");
            },
        }
        std.process.exit(1);
    };
    defer {
        allocator.free(cli_args.paths);
        switch (cli_args.rule_filter) {
            .allowlist => |list| allocator.free(list),
            .blocklist => |list| allocator.free(list),
            .none => {},
        }
    }

    const files = file_discovery.discoverFiles(allocator, cli_args.paths) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            file_discovery.FileDiscoveryError.FileNotFound => {
                try stderr.writeAll("Error: File or directory not found\n");
            },
            file_discovery.FileDiscoveryError.AccessDenied => {
                try stderr.writeAll("Error: Access denied\n");
            },
            else => {
                try stderr.writeAll("Error: Failed to discover files\n");
            },
        }
        std.process.exit(1);
    };
    defer file_discovery.freeDiscoveredFiles(allocator, files);

    if (files.len == 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("No .zig files found.\n");
        return;
    }

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try analyzer.registerRule(&EmptyCatchRule.rule);
    try analyzer.registerRule(&DupeImportRule.rule);
    try analyzer.registerRule(&TodoCommentRule.rule);
    try analyzer.registerRule(&FileAsStructRule.rule);
    try analyzer.registerRule(&UnusedDeclRule.rule);

    analyzer.setRuleFilter(cli_args.rule_filter);

    for (files) |file_path| {
        try analyzer.analyzeFile(file_path);
    }

    try analyzer.printResults();

    if (analyzer.hasDiagnostics()) {
        std.process.exit(1);
    }
}

fn printUsage() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("Usage: zwanzig [options] [path...]\n");
    try stderr.writeAll("\nA static analyzer for Zig code.\n");
    try stderr.writeAll("\nOptions:\n");
    try stderr.writeAll("  --file <path>  Specify a file or directory to analyze (can be repeated)\n");
    try stderr.writeAll("  --do <rule>    Only run the specified rule (can be repeated)\n");
    try stderr.writeAll("  --skip <rule>  Skip the specified rule (can be repeated)\n");
    try stderr.writeAll("\n  Note: --do and --skip are mutually exclusive.\n");
    try stderr.writeAll("\nArguments:\n");
    try stderr.writeAll("  [path...]      Files or directories to analyze (default: current directory)\n");
    try stderr.writeAll("\nIgnored directories:\n");
    try stderr.writeAll("  zig-cache/, zig-out/, .zigmod/, .gyro/\n");
}

fn freeCliArgs(allocator: std.mem.Allocator, cli_args: CliArgs) void {
    allocator.free(cli_args.paths);
    switch (cli_args.rule_filter) {
        .allowlist => |list| allocator.free(list),
        .blocklist => |list| allocator.free(list),
        .none => {},
    }
}

test "parseArgs: paths only" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("file1.zig", result.paths[0]);
    try std.testing.expectEqualStrings("file2.zig", result.paths[1]);
    try std.testing.expectEqual(RuleFilter.none, result.rule_filter);
}

test "parseArgs: --do flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "empty-catch", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);

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

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);

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

test "parseArgs: paths before and after flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "--do", "empty-catch", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("file1.zig", result.paths[0]);
    try std.testing.expectEqualStrings("file2.zig", result.paths[1]);
}

test "parseArgs: --file flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file", "src", "--file", "tests" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("src", result.paths[0]);
    try std.testing.expectEqualStrings("tests", result.paths[1]);
}

test "parseArgs: --file without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --file mixed with positional" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file", "src", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("src", result.paths[0]);
    try std.testing.expectEqualStrings("file.zig", result.paths[1]);
}

test "parseArgs: empty paths" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"zwanzig"};
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 0), result.paths.len);
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
