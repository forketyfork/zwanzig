const std = @import("std");
const analyzer_mod = @import("analyzer.zig");
const Analyzer = analyzer_mod.Analyzer;
const OutputFormat = analyzer_mod.Analyzer.OutputFormat;
const diagnostic_mod = @import("diagnostic.zig");
const Diagnostic = diagnostic_mod.Diagnostic;
const DupeImportRule = @import("rules/dupe_import.zig").DupeImportRule;
const TodoCommentRule = @import("rules/todo_comment.zig").TodoCommentRule;
const FileAsStructRule = @import("rules/file_as_struct.zig").FileAsStructRule;
const UnusedDeclRule = @import("rules/unused_decl.zig").UnusedDeclRule;
const UnreachableCodeRule = @import("rules/unreachable_code.zig").UnreachableCodeRule;
const EmptyDeferRule = @import("rules/empty_defer.zig").EmptyDeferRule;
const EmptyErrdeferRule = @import("rules/empty_errdefer.zig").EmptyErrdeferRule;
const ShadowedVariableRule = @import("rules/shadowed_variable.zig").ShadowedVariableRule;
const IdentifierStyleRule = @import("rules/identifier_style.zig").IdentifierStyleRule;
const SentinelAllocRule = @import("rules/sentinel_alloc.zig").SentinelAllocRule;
const UnusedParameterRule = @import("rules/unused_parameter.zig").UnusedParameterRule;
const OptionalUnwrapRule = @import("rules/optional_unwrap.zig").OptionalUnwrapRule;
const RuleFilter = @import("rule_filter.zig").RuleFilter;
const file_discovery = @import("file_discovery.zig");
const EmptyCatchEngineChecker = @import("checkers/empty_catch_engine.zig").EmptyCatchEngineChecker;
const SwallowedErrorChecker = @import("checkers/swallowed_error.zig").SwallowedErrorChecker;
const UnreachableCodeChecker = @import("checkers/unreachable_code_checker.zig").UnreachableCodeChecker;
const StoreViolationsEngineChecker = @import("checkers/store_violations_engine.zig").StoreViolationsEngineChecker;
const build_metadata = @import("build_metadata.zig");
const BuildMetadata = build_metadata.BuildMetadata;
const TargetConfig = build_metadata.TargetConfig;
const config = @import("config.zig");
const build_options = @import("build_options");
const log = std.log.scoped(.zwanzig);

pub const std_options = std.Options{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

test {
    _ = @import("ir.zig");
    _ = @import("cfg.zig");
    _ = @import("checker.zig");
    _ = @import("zir_bridge.zig");
    _ = @import("engine.zig");
    _ = @import("checkers/empty_catch_engine.zig");
    _ = @import("checkers/swallowed_error.zig");
    _ = @import("checkers/unreachable_code_checker.zig");
    _ = @import("checkers/store_violations_engine.zig");
    _ = @import("build_metadata.zig");
    _ = @import("config.zig");
    _ = @import("cache.zig");
}

fn outputFormatFromString(s: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "sarif")) return .sarif;
    return null;
}

pub const CliArgs = struct {
    paths: []const []const u8,
    rule_filter: RuleFilter,
    build_metadata: ?BuildMetadata,
    config_path: ?[]const u8,
    output_format: OutputFormat,
    use_cache: bool,
    max_worklist_steps: ?usize,
    max_states_per_point: ?u32,
    use_widening: ?bool,
    dump_cfg_dir: ?[]const u8,
    dump_exploded_graph_dir: ?[]const u8,
    dump_annotated_cfg_dir: ?[]const u8,
    dump_path_trace_dir: ?[]const u8,
    thread_count: usize,
};

pub const CliError = error{
    MutuallyExclusiveFlags,
    MissingFlagValue,
    OutOfMemory,
    InvalidTargetTriple,
    InvalidOutputFormat,
    InvalidNumericValue,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) CliError!CliArgs {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);

    var do_rules: std.ArrayList([]const u8) = .empty;
    errdefer do_rules.deinit(allocator);

    var skip_rules: std.ArrayList([]const u8) = .empty;
    errdefer skip_rules.deinit(allocator);

    var target_triple: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var output_format: OutputFormat = .text;
    var use_cache: bool = false;
    var max_worklist_steps: ?usize = null;
    var max_states_per_point: ?u32 = null;
    var use_widening: ?bool = null;
    var dump_cfg_dir: ?[]const u8 = null;
    var dump_exploded_graph_dir: ?[]const u8 = null;
    var dump_annotated_cfg_dir: ?[]const u8 = null;
    var dump_path_trace_dir: ?[]const u8 = null;
    // zwanzig-disable-next-line: swallowed-error
    var thread_count: usize = std.Thread.getCpuCount() catch 1;
    var build_meta: ?BuildMetadata = null;
    errdefer {
        if (build_meta) |*meta| {
            meta.deinit(allocator);
        }
    }

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
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            target_triple = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            output_format = outputFormatFromString(args[i]) orelse return CliError.InvalidOutputFormat;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            use_cache = true;
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            max_worklist_steps = parsed;
        } else if (std.mem.eql(u8, arg, "--max-states-per-point")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            max_states_per_point = parsed;
        } else if (std.mem.eql(u8, arg, "--use-widening")) {
            use_widening = true;
        } else if (std.mem.eql(u8, arg, "--dump-cfg")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_cfg_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-exploded-graph")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_exploded_graph_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-annotated-cfg")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_annotated_cfg_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-path-trace")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_path_trace_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            thread_count = parsed;
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

    if (target_triple) |triple| {
        const target_config = TargetConfig.fromTriple(allocator, triple) catch |err| {
            return if (err == error.InvalidTargetTriple) CliError.InvalidTargetTriple else CliError.OutOfMemory;
        };
        build_meta = BuildMetadata.init(target_config, null);
    } else {
        build_meta = BuildMetadata.fromNative();
    }

    return CliArgs{
        .paths = try paths.toOwnedSlice(allocator),
        .rule_filter = rule_filter,
        .build_metadata = build_meta,
        .config_path = config_path,
        .output_format = output_format,
        .use_cache = use_cache,
        .max_worklist_steps = max_worklist_steps,
        .max_states_per_point = max_states_per_point,
        .use_widening = use_widening,
        .dump_cfg_dir = dump_cfg_dir,
        .dump_exploded_graph_dir = dump_exploded_graph_dir,
        .dump_annotated_cfg_dir = dump_annotated_cfg_dir,
        .dump_path_trace_dir = dump_path_trace_dir,
        .thread_count = thread_count,
    };
}

const MergedConfig = struct {
    rule_filter: RuleFilter,
    max_worklist_steps: ?usize,
    max_states_per_point: ?u32,
    use_widening: ?bool,
    resource_models: []const config.ResourceModel = &.{},
};
fn defaultRuleFilter(allocator: std.mem.Allocator) !RuleFilter {
    var rule_names = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(rule_names);
    rule_names[0] = try allocator.dupe(u8, "sentinel-alloc");
    return .{ .blocklist = rule_names };
}

fn mergeConfig(allocator: std.mem.Allocator, cli_args: CliArgs) !MergedConfig {
    const config_path = cli_args.config_path orelse ".zwanzig.json";

    var loaded_config = config.loadConfig(allocator, config_path) catch |err| {
        if (err == config.ConfigError.FileNotFound and cli_args.config_path == null) {
            const rule_filter = switch (cli_args.rule_filter) {
                .none => try defaultRuleFilter(allocator),
                else => cli_args.rule_filter,
            };
            return .{
                .rule_filter = rule_filter,
                .max_worklist_steps = cli_args.max_worklist_steps,
                .max_states_per_point = cli_args.max_states_per_point,
                .use_widening = cli_args.use_widening orelse true,
            };
        }
        return err;
    };
    const max_worklist_steps = cli_args.max_worklist_steps orelse loaded_config.max_worklist_steps;
    const max_states_per_point = cli_args.max_states_per_point orelse loaded_config.max_states_per_point;
    const use_widening = cli_args.use_widening orelse loaded_config.use_widening orelse true;
    const resource_models = loaded_config.resource_models;

    switch (cli_args.rule_filter) {
        .none => {
            return .{
                .rule_filter = loaded_config.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
            };
        },
        .allowlist => {
            // Free only the rule_filter part, keep resource_models
            loaded_config.resource_models = &.{}; // Prevent deinit from freeing
            loaded_config.deinit(allocator);
            return .{
                .rule_filter = cli_args.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
            };
        },
        .blocklist => {
            // Free only the rule_filter part, keep resource_models
            loaded_config.resource_models = &.{}; // Prevent deinit from freeing
            loaded_config.deinit(allocator);
            return .{
                .rule_filter = cli_args.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
            };
        },
    }
}

const AnalysisResult = analyzer_mod.AnalysisResult;

const WorkerContext = struct {
    analyzer: *Analyzer,
    files: []const []const u8,
    results: []?AnalysisResult,
    errors: []?anyerror,
    allocator: std.mem.Allocator,
};

fn workerTask(file_index: usize, ctx: *WorkerContext) void {
    // Use a per-task arena allocator backed by the page allocator.
    // This eliminates lock contention on the shared GPA during parallel analysis,
    // as each worker thread has its own independent arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const file_path = ctx.files[file_index];
    const result = ctx.analyzer.analyzeFileResultWithScratchAllocator(file_path, arena.allocator());
    if (result) |r| {
        ctx.results[file_index] = r;
        ctx.errors[file_index] = null;
    } else |err| {
        ctx.results[file_index] = null;
        ctx.errors[file_index] = err;
    }
}

fn workerTaskWrapper(file_index: usize, ctx: *WorkerContext, wg: *std.Thread.WaitGroup) void {
    defer wg.finish();
    workerTask(file_index, ctx);
}

fn analyzeFilesParallel(analyzer: *Analyzer, files: []const []const u8, thread_count: usize, allocator: std.mem.Allocator) !void {
    if (files.len == 0) return;

    const results = try allocator.alloc(?AnalysisResult, files.len);
    defer allocator.free(results);
    @memset(results, null);

    const errors = try allocator.alloc(?anyerror, files.len);
    defer allocator.free(errors);
    @memset(errors, null);

    var ctx = WorkerContext{
        .analyzer = analyzer,
        .files = files,
        .results = results,
        .errors = errors,
        .allocator = allocator,
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @intCast(thread_count),
    });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    var spawn_error: ?anyerror = null;
    for (0..files.len) |i| {
        wg.start();
        pool.spawn(workerTaskWrapper, .{ i, &ctx, &wg }) catch |err| {
            wg.finish();
            spawn_error = err;
            break;
        };
    }

    pool.waitAndWork(&wg);

    if (spawn_error) |err| {
        return err;
    }

    var first_error: ?anyerror = null;
    for (0..files.len) |i| {
        if (errors[i]) |err| {
            if (first_error == null) {
                first_error = err;
            }
        } else if (results[i]) |*result| {
            try analyzer.mergeResult(result);
        }
    }

    // Sort diagnostics for deterministic output ordering
    std.mem.sort(Diagnostic, analyzer.diagnostics.items, {}, Diagnostic.lessThan);

    if (first_error) |err| {
        return err;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for --help or -h before parsing other arguments
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try printVersion();
            return;
        }
    }

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
            CliError.InvalidTargetTriple => {
                try stderr.writeAll("Error: Invalid target triple format\n");
            },
            CliError.InvalidOutputFormat => {
                try stderr.writeAll("Error: Invalid output format (use 'text', 'json', or 'sarif')\n");
            },
            CliError.InvalidNumericValue => {
                try stderr.writeAll("Error: Invalid numeric value for limit\n");
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

    const final_config = mergeConfig(allocator, cli_args) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            config.ConfigError.InvalidJson => {
                try stderr.writeAll("Error: Invalid JSON in config file\n");
            },
            config.ConfigError.InvalidConfigFormat => {
                try stderr.writeAll("Error: Invalid config file format\n");
            },
            config.ConfigError.MutuallyExclusiveFields => {
                try stderr.writeAll("Error: Config file has both enabled_rules and disabled_rules\n");
            },
            config.ConfigError.FileNotFound => {
                try stderr.writeAll("Error: Config file not found\n");
            },
            config.ConfigError.OutOfMemory => {
                try stderr.writeAll("Error: Out of memory\n");
            },
        }
        std.process.exit(1);
    };
    defer {
        switch (final_config.rule_filter) {
            .allowlist => |list| {
                const should_free = switch (cli_args.rule_filter) {
                    .allowlist => |cli_list| list.ptr != cli_list.ptr,
                    else => true,
                };
                if (should_free) {
                    for (list) |rule_name| {
                        allocator.free(rule_name);
                    }
                    allocator.free(list);
                }
            },
            .blocklist => |list| {
                const should_free = switch (cli_args.rule_filter) {
                    .blocklist => |cli_list| list.ptr != cli_list.ptr,
                    else => true,
                };
                if (should_free) {
                    for (list) |rule_name| {
                        allocator.free(rule_name);
                    }
                    allocator.free(list);
                }
            },
            .none => {},
        }
        // Free resource model strings
        for (final_config.resource_models) |model| {
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.return_type) |ty| allocator.free(ty);
            if (model.fqn) |name| allocator.free(name);
        }
        if (final_config.resource_models.len > 0) {
            allocator.free(final_config.resource_models);
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
    log.info("discovered {d} file(s)", .{files.len});

    if (files.len == 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("No .zig files found.\n");
        return;
    }

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    analyzer.setToolVersion(build_options.version);

    try analyzer.registerRule(&DupeImportRule.rule);
    try analyzer.registerRule(&TodoCommentRule.rule);
    try analyzer.registerRule(&FileAsStructRule.rule);
    try analyzer.registerRule(&UnusedDeclRule.rule);
    try analyzer.registerRule(&UnreachableCodeRule.rule);
    try analyzer.registerRule(&EmptyDeferRule.rule);
    try analyzer.registerRule(&EmptyErrdeferRule.rule);
    try analyzer.registerRule(&ShadowedVariableRule.rule);
    try analyzer.registerRule(&IdentifierStyleRule.rule);
    try analyzer.registerRule(&SentinelAllocRule.rule);
    try analyzer.registerRule(&UnusedParameterRule.rule);
    try analyzer.registerRule(&OptionalUnwrapRule.rule);

    // Engine-based checkers
    try analyzer.registerChecker(&EmptyCatchEngineChecker.checker);
    try analyzer.registerChecker(&SwallowedErrorChecker.checker);
    try analyzer.registerChecker(&UnreachableCodeChecker.checker);
    try analyzer.registerChecker(&StoreViolationsEngineChecker.checker);

    analyzer.setRuleFilter(final_config.rule_filter);
    if (final_config.max_worklist_steps) |steps| {
        analyzer.setMaxWorklistSteps(steps);
    }
    if (final_config.max_states_per_point) |max| {
        analyzer.setMaxStatesPerPoint(max);
    }
    if (final_config.use_widening) |use_w| {
        analyzer.setUseWidening(use_w);
    }
    // Pass resource models to the analyzer for config-driven detection
    if (final_config.resource_models.len > 0) {
        analyzer.setConfig(.{
            .rule_filter = .none, // Rule filter is handled separately
            .resource_models = final_config.resource_models,
        });
    }

    if (cli_args.build_metadata) |metadata| {
        try analyzer.setBuildMetadata(metadata);
    }

    if (cli_args.use_cache) {
        try analyzer.enableCache();
    }

    if (cli_args.dump_cfg_dir) |dir| {
        analyzer.setDumpCfgDir(dir);
    }
    if (cli_args.dump_exploded_graph_dir) |dir| {
        analyzer.setDumpExplodedGraphDir(dir);
    }
    if (cli_args.dump_annotated_cfg_dir) |dir| {
        analyzer.setDumpAnnotatedCfgDir(dir);
    }
    if (cli_args.dump_path_trace_dir) |dir| {
        analyzer.setDumpPathTraceDir(dir);
    }

    log.info("analyzing with {d} rule(s) using {d} thread(s)", .{ analyzer.totalCheckerCount(), cli_args.thread_count });
    try analyzeFilesParallel(&analyzer, files, cli_args.thread_count, allocator);
    log.info("analysis complete", .{});
    analyzer.logAnalysisStats();

    try analyzer.printResults(cli_args.output_format);

    if (analyzer.hasDiagnostics()) {
        std.process.exit(1);
    }
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("Usage: zwanzig [options] [path...]\n");
    try stdout.writeAll("\nA static analyzer for Zig code.\n");
    try stdout.writeAll("\nOptions:\n");
    try stdout.writeAll("  -h, --help        Show this help message and exit\n");
    try stdout.writeAll("  --version         Show version and exit\n");
    try stdout.writeAll("  --file <path>     Specify a file or directory to analyze (can be repeated)\n");
    try stdout.writeAll("  --do <rule>       Only run the specified rule (can be repeated)\n");
    try stdout.writeAll("  --skip <rule>     Skip the specified rule (can be repeated)\n");
    try stdout.writeAll("  --target <triple> Specify target triple (e.g., x86_64-linux-gnu)\n");
    try stdout.writeAll("  --config <path>   Path to config file (default: .zwanzig.json)\n");
    try stdout.writeAll("  --format <format> Output format: 'text', 'json', or 'sarif' (default: text)\n");
    try stdout.writeAll("  --max-steps <n>   Max worklist steps per engine run\n");
    try stdout.writeAll("  --max-states-per-point <n> Max unique states per CFG point\n");
    try stdout.writeAll("  --use-widening    Enable widening for convergence (default: on)\n");
    try stdout.writeAll("  --cache           Enable incremental caching\n");
    try stdout.writeAll("  --threads <n>     Number of threads for parallel analysis (default: CPU count)\n");
    try stdout.writeAll("  --dump-cfg <dir>  Dump CFG DOT files to directory for visualization\n");
    try stdout.writeAll("  --dump-exploded-graph <dir>  Dump exploded graph (all states) as DOT\n");
    try stdout.writeAll("  --dump-annotated-cfg <dir>   Dump CFG with state annotations as DOT\n");
    try stdout.writeAll("  --dump-path-trace <dir>      Dump path traces to violations as DOT\n");
    try stdout.writeAll("\n  Note: --do and --skip are mutually exclusive and override config file.\n");
    try stdout.writeAll("\nArguments:\n");
    try stdout.writeAll("  [path...]         Files or directories to analyze (default: current directory)\n");
    try stdout.writeAll("\nIgnored directories:\n");
    try stdout.writeAll("  zig-cache/, zig-out/, .zigmod/, .gyro/\n");
}

fn printVersion() !void {
    var buffer: [64]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "zwanzig {s}\n", .{build_options.version});
    try std.fs.File.stdout().writeAll(message);
}

fn freeCliArgs(allocator: std.mem.Allocator, cli_args: CliArgs) void {
    allocator.free(cli_args.paths);
    switch (cli_args.rule_filter) {
        .allowlist => |list| allocator.free(list),
        .blocklist => |list| allocator.free(list),
        .none => {},
    }
    if (cli_args.build_metadata) |*meta_const| {
        var meta = meta_const.*;
        meta.deinit(allocator);
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

test "parseArgs: --target flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "x86_64-linux-gnu", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);

    try std.testing.expect(result.build_metadata != null);
    const metadata = result.build_metadata.?;
    try std.testing.expectEqual(build_metadata.TargetArch.x86_64, metadata.target.arch);
    try std.testing.expectEqual(build_metadata.TargetOS.linux, metadata.target.os);
    try std.testing.expect(metadata.target.abi != null);
    try std.testing.expectEqualStrings("gnu", metadata.target.abi.?);
}

test "parseArgs: --target without ABI" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "aarch64-macos", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expect(result.build_metadata != null);
    const metadata = result.build_metadata.?;
    try std.testing.expectEqual(build_metadata.TargetArch.aarch64, metadata.target.arch);
    try std.testing.expectEqual(build_metadata.TargetOS.macos, metadata.target.os);
    try std.testing.expectEqual(@as(?[]const u8, null), metadata.target.abi);
}

test "parseArgs: --target without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: invalid target triple" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "invalid" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidTargetTriple, result);
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

test "parseArgs: --config flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--config", "custom.json", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);
    try std.testing.expect(result.config_path != null);
    try std.testing.expectEqualStrings("custom.json", result.config_path.?);
}

test "parseArgs: --config without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--config" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "mergeConfig: CLI overrides config allowlist" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_path_buf);

    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/.zwanzig.json", .{tmp_path});

    const config_content =
        \\{
        \\  "enabled_rules": ["empty-catch"]
        \\}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = ".zwanzig.json", .data = config_content });

    const cli_allowlist = [_][]const u8{"dupe-import"};
    const cli_args = CliArgs{
        .paths = &.{},
        .rule_filter = .{ .allowlist = &cli_allowlist },
        .build_metadata = null,
        .config_path = config_path,
        .output_format = .text,
        .use_cache = false,
        .max_worklist_steps = null,
        .max_states_per_point = null,
        .use_widening = null,
        .dump_cfg_dir = null,
        .dump_exploded_graph_dir = null,
        .dump_annotated_cfg_dir = null,
        .dump_path_trace_dir = null,
        .thread_count = 1,
    };

    const result = try mergeConfig(allocator, cli_args);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("dupe-import", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "mergeConfig: uses config when no CLI filter" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_path_buf);

    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/.zwanzig.json", .{tmp_path});

    const config_content =
        \\{
        \\  "disabled_rules": ["todo"]
        \\}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = ".zwanzig.json", .data = config_content });

    const cli_args = CliArgs{
        .paths = &.{},
        .rule_filter = .none,
        .build_metadata = null,
        .config_path = config_path,
        .output_format = .text,
        .use_cache = false,
        .max_worklist_steps = null,
        .max_states_per_point = null,
        .use_widening = null,
        .dump_cfg_dir = null,
        .dump_exploded_graph_dir = null,
        .dump_annotated_cfg_dir = null,
        .dump_path_trace_dir = null,
        .thread_count = 1,
    };

    const result = try mergeConfig(allocator, cli_args);
    defer switch (result.rule_filter) {
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
    };

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("todo", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "mergeConfig: no config file and no CLI filter" {
    const allocator = std.testing.allocator;

    const cli_args = CliArgs{
        .paths = &.{},
        .rule_filter = .none,
        .build_metadata = null,
        .config_path = null,
        .output_format = .text,
        .use_cache = false,
        .max_worklist_steps = null,
        .max_states_per_point = null,
        .use_widening = null,
        .dump_cfg_dir = null,
        .dump_exploded_graph_dir = null,
        .dump_annotated_cfg_dir = null,
        .dump_path_trace_dir = null,
        .thread_count = 1,
    };

    const result = try mergeConfig(allocator, cli_args);
    defer switch (result.rule_filter) {
        .allowlist => |list| {
            for (list) |name| {
                allocator.free(name);
            }
            allocator.free(list);
        },
        .blocklist => |list| {
            for (list) |name| {
                allocator.free(name);
            }
            allocator.free(list);
        },
        .none => {},
    };

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("sentinel-alloc", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: --format text" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--format", "text", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(OutputFormat.text, result.output_format);
}

test "parseArgs: --format json" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--format", "json", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(OutputFormat.json, result.output_format);
}

test "parseArgs: --format without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--format" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: invalid format" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--format", "xml" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidOutputFormat, result);
}

test "parseArgs: default format is text" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(OutputFormat.text, result.output_format);
}

test "parseArgs: --format sarif" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--format", "sarif", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(OutputFormat.sarif, result.output_format);
}

test "parseArgs: --cache flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--cache", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expect(result.use_cache);
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);
}

test "parseArgs: default no cache" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expect(!result.use_cache);
}

test "parseArgs: --threads flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--threads", "4", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.thread_count);
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);
}

test "parseArgs: --threads without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--threads" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --threads with invalid value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--threads", "abc" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidNumericValue, result);
}

test "parseArgs: --threads with zero value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--threads", "0" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidNumericValue, result);
}

test "parseArgs: --threads with negative value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--threads", "-1" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidNumericValue, result);
}

test "parseArgs: default thread count is CPU count" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    const expected_count = std.Thread.getCpuCount() catch 1;
    try std.testing.expectEqual(expected_count, result.thread_count);
}

test "parallel analysis produces deterministic output ordering" {
    // Use thread-safe allocator for parallel analysis test
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_a_content =
        \\const std = @import("std");
        \\const std2 = @import("std");
    ;
    const file_b_content =
        \\const foo = @import("foo");
        \\const foo2 = @import("foo");
    ;
    const file_c_content =
        \\const bar = @import("bar");
        \\const bar2 = @import("bar");
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "a.zig", .data = file_a_content });
    try tmp_dir.dir.writeFile(.{ .sub_path = "b.zig", .data = file_b_content });
    try tmp_dir.dir.writeFile(.{ .sub_path = "c.zig", .data = file_c_content });

    var path_buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf_b: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const path_a = try tmp_dir.dir.realpath("a.zig", &path_buf_a);
    const path_b = try tmp_dir.dir.realpath("b.zig", &path_buf_b);
    const path_c = try tmp_dir.dir.realpath("c.zig", &path_buf_c);

    const files = [_][]const u8{ path_a, path_b, path_c };

    // Run with 1 thread
    var analyzer1 = Analyzer.init(allocator);
    defer analyzer1.deinit();
    try analyzer1.registerRule(&DupeImportRule.rule);
    try analyzeFilesParallel(&analyzer1, &files, 1, allocator);

    // Run with multiple threads
    var analyzer2 = Analyzer.init(allocator);
    defer analyzer2.deinit();
    try analyzer2.registerRule(&DupeImportRule.rule);
    try analyzeFilesParallel(&analyzer2, &files, 4, allocator);

    // Both runs should produce the same number of diagnostics
    try std.testing.expectEqual(analyzer1.diagnostics.items.len, analyzer2.diagnostics.items.len);

    // Diagnostics should be in the same order (sorted by file path, line, column)
    for (analyzer1.diagnostics.items, analyzer2.diagnostics.items) |d1, d2| {
        try std.testing.expectEqualStrings(d1.file_path, d2.file_path);
        try std.testing.expectEqual(d1.range.start.line, d2.range.start.line);
        try std.testing.expectEqual(d1.range.start.column, d2.range.start.column);
        try std.testing.expectEqualStrings(d1.rule_id, d2.rule_id);
        try std.testing.expectEqualStrings(d1.message, d2.message);
    }
}
