const std = @import("std");
const analyzer_mod = @import("../analyzer.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const file_discovery = @import("../file_discovery.zig");
const build_options = @import("build_options");
const config = @import("../config.zig");
const args_mod = @import("args.zig");
const merge_mod = @import("config_merge.zig");
const registry = @import("registry.zig");

const Analyzer = analyzer_mod.Analyzer;
const AnalysisResult = analyzer_mod.AnalysisResult;
const CliArgs = args_mod.CliArgs;
const CliError = args_mod.CliError;
const MergedConfig = merge_mod.MergedConfig;
const log = std.log.scoped(.zwanzig);

const WorkerContext = struct {
    analyzer: *Analyzer,
    files: []const []const u8,
    results: []?AnalysisResult,
    errors: []?anyerror,
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

fn parseCliArgs(allocator: std.mem.Allocator, args: []const []const u8) CliArgs {
    // Check for --help or -h before parsing other arguments
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage() catch |err| {
                std.debug.print("Failed to print usage: {s}\n", .{@errorName(err)});
            };
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            printVersion() catch |err| {
                std.debug.print("Failed to print version: {s}\n", .{@errorName(err)});
            };
            std.process.exit(0);
        }
    }

    return args_mod.parseArgs(allocator, args) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            CliError.MutuallyExclusiveFlags => {
                stderr.writeAll("Error: --do and --skip are mutually exclusive\n") catch {};
            },
            CliError.MissingFlagValue => {
                stderr.writeAll("Error: Flag requires a value\n") catch {};
            },
            CliError.OutOfMemory => {
                stderr.writeAll("Error: Out of memory\n") catch {};
            },
            CliError.InvalidTargetTriple => {
                stderr.writeAll("Error: Invalid target triple format\n") catch {};
            },
            CliError.InvalidOutputFormat => {
                stderr.writeAll("Error: Invalid output format (use 'text', 'json', or 'sarif')\n") catch {};
            },
            CliError.InvalidNumericValue => {
                stderr.writeAll("Error: Invalid numeric value for limit\n") catch {};
            },
        }
        std.process.exit(1);
    };
}

fn loadMergedConfig(allocator: std.mem.Allocator, cli_args: CliArgs) MergedConfig {
    return merge_mod.mergeConfig(allocator, cli_args) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            config.ConfigError.InvalidJson => {
                stderr.writeAll("Error: Invalid JSON in config file\n") catch {};
            },
            config.ConfigError.InvalidConfigFormat => {
                stderr.writeAll("Error: Invalid config file format\n") catch {};
            },
            config.ConfigError.MutuallyExclusiveFields => {
                stderr.writeAll("Error: Config file has both enabled_rules and disabled_rules\n") catch {};
            },
            config.ConfigError.FileNotFound => {
                stderr.writeAll("Error: Config file not found\n") catch {};
            },
            config.ConfigError.OutOfMemory => {
                stderr.writeAll("Error: Out of memory\n") catch {};
            },
        }
        std.process.exit(1);
    };
}

fn discoverInputFiles(allocator: std.mem.Allocator, cli_args: CliArgs) []const []const u8 {
    return file_discovery.discoverFiles(allocator, cli_args.paths) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            file_discovery.FileDiscoveryError.FileNotFound => {
                stderr.writeAll("Error: File or directory not found\n") catch {};
            },
            file_discovery.FileDiscoveryError.AccessDenied => {
                stderr.writeAll("Error: Access denied\n") catch {};
            },
            else => {
                stderr.writeAll("Error: Failed to discover files\n") catch {};
            },
        }
        std.process.exit(1);
    };
}

fn configureAnalyzer(analyzer: *Analyzer, cli_args: CliArgs, final_config: MergedConfig, allocator: std.mem.Allocator) !void {
    analyzer.setToolVersion(build_options.version);
    try registry.registerDefaults(analyzer);

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
    const has_models = final_config.resource_models.len > 0 or final_config.escape_models.len > 0 or final_config.escape_max_depth != null;
    if (has_models) {
        analyzer.setConfig(.{
            .rule_filter = .none,
            .resource_models = final_config.resource_models,
            .escape_models = final_config.escape_models,
            .escape_max_depth = final_config.escape_max_depth,
        });
    }

    if (cli_args.build_metadata) |metadata_const| {
        var metadata = metadata_const;
        errdefer metadata.deinit(allocator);
        try analyzer.setBuildMetadata(metadata);
        metadata.deinit(allocator);
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
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli_args = parseCliArgs(allocator, args);
    defer {
        allocator.free(cli_args.paths);
        switch (cli_args.rule_filter) {
            .allowlist => |list| allocator.free(list),
            .blocklist => |list| allocator.free(list),
            .none => {},
        }
    }

    const final_config = loadMergedConfig(allocator, cli_args);
    defer merge_mod.freeMergedConfig(allocator, cli_args, final_config);

    const files = discoverInputFiles(allocator, cli_args);
    defer file_discovery.freeDiscoveredFiles(allocator, files);
    log.info("discovered {d} file(s)", .{files.len});

    if (files.len == 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("No .zig files found.\n");
        return;
    }

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try configureAnalyzer(&analyzer, cli_args, final_config, allocator);

    log.info("analyzing with {d} rule(s) using {d} thread(s)", .{ analyzer.totalCheckerCount(), cli_args.thread_count });
    try analyzeFilesParallel(&analyzer, files, cli_args.thread_count, allocator);
    log.info("analysis complete", .{});
    analyzer.logAnalysisStats();

    try analyzer.printResults(cli_args.output_format);

    if (analyzer.hasDiagnostics()) {
        std.process.exit(1);
    }
}
