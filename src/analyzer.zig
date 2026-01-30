const std = @import("std");
const Rule = @import("rule.zig").Rule;
const Diagnostic = @import("rule.zig").Diagnostic;
const Source = @import("source.zig").Source;
const RuleFilter = @import("rule_filter.zig").RuleFilter;
const checker_mod = @import("checker.zig");
const Checker = checker_mod.Checker;
const CheckerManagerWithRules = checker_mod.CheckerManagerWithRules;
const TypeContext = checker_mod.TypeContext;
const Config = checker_mod.Config;
const ZirBridge = @import("zir_bridge.zig").ZirBridge;
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheKey = cache_mod.CacheKey;
const cached_artifacts_mod = @import("cached_artifacts.zig");
const CachedArtifacts = cached_artifacts_mod.CachedArtifacts;
const log = std.log.scoped(.analyzer);
const diagnostic_mod = @import("diagnostic.zig");
const suppression = @import("suppression.zig");

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    checker_manager: CheckerManagerWithRules,
    diagnostics: std.ArrayList(Diagnostic),
    rule_filter: RuleFilter,
    tool_version: []const u8 = "unknown",
    zir_bridge: ?ZirBridge = null,
    use_typed_ir: bool = false,
    build_metadata: ?BuildMetadata = null,
    cache: ?Cache = null,
    use_cache: bool = false,
    analysis_stats: checker_mod.AnalysisStats = .{},
    max_worklist_steps: ?usize = null,
    max_states_per_point: ?u32 = null,
    use_widening: ?bool = null,
    config: ?Config = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .checker_manager = CheckerManagerWithRules.init(allocator),
            .diagnostics = .empty,
            .rule_filter = .none,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.checker_manager.deinit();
        for (self.diagnostics.items) |*diag| {
            diag.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        if (self.zir_bridge) |*bridge| {
            bridge.deinit();
        }
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
        if (self.cache) |*c| {
            c.deinit();
        }
    }

    /// Enable typed IR analysis using ZirBridge.
    pub fn enableTypedIr(self: *Analyzer) void {
        self.use_typed_ir = true;
        if (self.zir_bridge == null) {
            self.zir_bridge = ZirBridge.init(self.allocator);
        }
    }

    /// Enable incremental caching.
    pub fn enableCache(self: *Analyzer) !void {
        self.use_cache = true;
        if (self.cache == null) {
            self.cache = try Cache.init(self.allocator);
        }
    }

    /// Get the ZirBridge if typed IR is enabled and loaded.
    pub fn getZirBridge(self: *Analyzer) ?*ZirBridge {
        if (self.zir_bridge) |*bridge| {
            return bridge;
        }
        return null;
    }

    /// Register a legacy Rule with the analyzer.
    /// The rule will be wrapped and run through the CheckerManager.
    pub fn registerRule(self: *Analyzer, rule: *const Rule) !void {
        try self.checker_manager.registerRule(rule);
    }

    /// Register a new-style Checker with the analyzer.
    pub fn registerChecker(self: *Analyzer, chkr: *const Checker) !void {
        try self.checker_manager.registerChecker(chkr);
    }

    pub fn setRuleFilter(self: *Analyzer, filter: RuleFilter) void {
        self.rule_filter = filter;
    }

    pub fn setToolVersion(self: *Analyzer, version: []const u8) void {
        self.tool_version = version;
    }

    pub fn setBuildMetadata(self: *Analyzer, metadata: BuildMetadata) !void {
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
        self.build_metadata = try metadata.clone(self.allocator);
    }

    pub fn setMaxWorklistSteps(self: *Analyzer, steps: usize) void {
        self.max_worklist_steps = steps;
    }

    pub fn setMaxStatesPerPoint(self: *Analyzer, max: u32) void {
        self.max_states_per_point = max;
    }

    pub fn setUseWidening(self: *Analyzer, use_w: bool) void {
        self.use_widening = use_w;
    }

    /// Set the config for resource models and other settings.
    pub fn setConfig(self: *Analyzer, cfg: Config) void {
        self.config = cfg;
    }

    /// Get the config if set.
    pub fn getConfig(self: *const Analyzer) ?*const Config {
        if (self.config) |*cfg| {
            return cfg;
        }
        return null;
    }

    pub fn getBuildMetadata(self: *const Analyzer) ?*const BuildMetadata {
        if (self.build_metadata) |*meta| {
            return meta;
        }
        return null;
    }

    pub fn logAnalysisStats(self: *const Analyzer) void {
        if (self.analysis_stats.widened_nodes > 0 or self.analysis_stats.widening_converged > 0) {
            log.info("widening: {d} node(s) widened, {d} converged across {d} engine run(s)", .{
                self.analysis_stats.widened_nodes,
                self.analysis_stats.widening_converged,
                self.analysis_stats.total_runs,
            });
        }
        if (self.analysis_stats.runs_with_drops == 0) return;
        log.warn("dropped {d} state(s) due to per-point limit across {d} engine run(s) (total runs {d})", .{
            self.analysis_stats.dropped_states,
            self.analysis_stats.runs_with_drops,
            self.analysis_stats.total_runs,
        });
    }

    pub fn isRuleEnabled(self: *const Analyzer, rule_name: []const u8) bool {
        switch (self.rule_filter) {
            .none => return true,
            .allowlist => |list| {
                for (list) |allowed| {
                    if (std.mem.eql(u8, rule_name, allowed)) {
                        return true;
                    }
                }
                return false;
            },
            .blocklist => |list| {
                for (list) |blocked| {
                    if (std.mem.eql(u8, rule_name, blocked)) {
                        return false;
                    }
                }
                return true;
            },
        }
    }

    fn ruleNameLess(a: []const u8, b: []const u8) bool {
        const min_len = if (a.len < b.len) a.len else b.len;
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            if (a[i] < b[i]) return true;
            if (a[i] > b[i]) return false;
        }
        return a.len < b.len;
    }

    fn sortRuleNames(names: [][]const u8) void {
        var i: usize = 0;
        while (i < names.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < names.len) : (j += 1) {
                if (ruleNameLess(names[j], names[i])) {
                    const tmp = names[i];
                    names[i] = names[j];
                    names[j] = tmp;
                }
            }
        }
    }

    pub fn analyzeFile(self: *Analyzer, file_path: []const u8) !void {
        log.debug("analyze: start {s}", .{file_path});
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const max_size = 10 * 1024 * 1024;
        const content = try file.readToEndAllocOptions(
            self.allocator,
            max_size,
            null,
            std.mem.Alignment.of(u8),
            0,
        );
        defer self.allocator.free(content);

        var source = Source.init(self.allocator, file_path, content);
        defer source.deinit();

        var cached_artifacts: ?CachedArtifacts = null;
        defer if (cached_artifacts) |*ca| ca.deinit();

        var cache_key: ?CacheKey = null;
        var enabled_rules_buf: std.ArrayList([]const u8) = .empty;
        defer enabled_rules_buf.deinit(self.allocator);

        if (self.use_cache) {
            for (self.checker_manager.checkers.items) |chkr| {
                if (self.isRuleEnabled(chkr.name)) {
                    try enabled_rules_buf.append(self.allocator, chkr.name);
                }
            }
            for (self.checker_manager.adapted_rules.items) |rule| {
                if (self.isRuleEnabled(rule.name)) {
                    try enabled_rules_buf.append(self.allocator, rule.name);
                }
            }

            sortRuleNames(enabled_rules_buf.items);
            cache_key = CacheKey.init(
                content,
                self.getBuildMetadata(),
                self.tool_version,
                enabled_rules_buf.items,
            );
            if (self.cache) |*c| {
                if (try c.get(cache_key.?)) |cached_data| {
                    defer self.allocator.free(cached_data);
                    log.debug("analyze: cache hit {s}, loading artifacts", .{file_path});

                    cached_artifacts = CachedArtifacts.deserialize(self.allocator, cached_data) catch |err| blk: {
                        log.debug("analyze: failed to deserialize cached artifacts: {}", .{err});
                        break :blk null;
                    };
                }
            }
        }

        if (self.use_typed_ir) {
            log.debug("analyze: load typed ir {s}", .{file_path});
            try self.loadTypedIr(&source);
        }

        const diag_start_index = self.diagnostics.items.len;

        try self.runChecksOnSource(&source);

        try self.filterSuppressedDiagnostics(content, diag_start_index);

        if (self.use_cache and cache_key != null) {
            if (self.cache) |*c| {
                var artifacts = CachedArtifacts.init(self.allocator);
                defer artifacts.deinit();

                artifacts.had_type_info = self.use_typed_ir;

                const serialized = artifacts.serialize(self.allocator) catch |err| {
                    log.debug("analyze: failed to serialize artifacts: {}", .{err});
                    return;
                };
                defer self.allocator.free(serialized);

                c.put(cache_key.?, serialized) catch |err| {
                    log.debug("analyze: failed to cache artifacts: {}", .{err});
                };
            }
        }

        log.debug("analyze: done {s}", .{file_path});
    }

    /// Load typed IR for a source file using ZirBridge.
    fn loadTypedIr(self: *Analyzer, source: *Source) !void {
        if (self.zir_bridge) |*bridge| {
            bridge.loadFromSource(source) catch |err| {
                switch (err) {
                    error.ParseError, error.AstGenFailed => {},
                    else => return err,
                }
            };
        }
    }

    /// Internal method to run checks on a source with the analyzer's filter.
    fn runChecksOnSource(self: *Analyzer, source: *Source) !void {
        // Create type context if typed IR is enabled
        var type_ctx: ?TypeContext = null;
        if (self.use_typed_ir) {
            type_ctx = TypeContext.init(self.allocator, source);
            log.debug("type context: created for {s}, available={}", .{
                source.getFilePath(),
                if (type_ctx) |*tc| tc.isAvailable() else false,
            });
        }
        defer if (type_ctx) |*tc| tc.deinit();

        const context = checker_mod.CheckerContext{
            .build_metadata = self.getBuildMetadata(),
            .type_context = if (type_ctx) |*tc| tc else null,
            .analysis_stats = &self.analysis_stats,
            .analysis_limits = .{
                .max_worklist_steps = self.max_worklist_steps,
                .max_states_per_point = self.max_states_per_point,
                .use_widening = self.use_widening,
            },
            .config = self.getConfig(),
        };

        // Run native checkers
        for (self.checker_manager.checkers.items) |chkr| {
            if (self.isRuleEnabled(chkr.name)) {
                log.debug("checker: start {s} ({s})", .{ source.getFilePath(), chkr.name });
                try chkr.checkAst(source, self.allocator, &self.diagnostics, context);
                log.debug("checker: done {s} ({s})", .{ source.getFilePath(), chkr.name });
            }
        }

        // Run adapted rules
        for (self.checker_manager.adapted_rules.items) |rule| {
            if (self.isRuleEnabled(rule.name)) {
                log.debug("rule: start {s} ({s})", .{ source.getFilePath(), rule.name });
                try rule.check(source, self.allocator, &self.diagnostics);
                log.debug("rule: done {s} ({s})", .{ source.getFilePath(), rule.name });
            }
        }
    }

    fn filterSuppressedDiagnostics(
        self: *Analyzer,
        content: [:0]const u8,
        start_index: usize,
    ) !void {
        var sup_map = try suppression.parseSuppressions(self.allocator, content);
        defer sup_map.deinit();

        var write_index = start_index;
        for (self.diagnostics.items[start_index..]) |*diag| {
            if (!sup_map.isSuppressed(diag.range.start.line, diag.rule_id)) {
                self.diagnostics.items[write_index] = diag.*;
                write_index += 1;
            } else {
                diag.deinit(self.allocator);
            }
        }
        self.diagnostics.shrinkRetainingCapacity(write_index);
    }

    pub const OutputFormat = enum {
        text,
        json,
        sarif,
    };

    pub fn printResults(self: *Analyzer, format: OutputFormat) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();

        switch (format) {
            .json => try self.printJsonResults(stdout),
            .text => try self.printTextResults(stdout),
            .sarif => try self.printSarifResults(stdout),
        }
    }

    fn printTextResults(self: *Analyzer, writer: anytype) !void {
        if (self.diagnostics.items.len == 0) {
            try writer.writeAll("No issues found.\n");
            return;
        }

        try writer.print("Found {d} issue(s):\n", .{self.diagnostics.items.len});
        var file_cache = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var value_iter = file_cache.valueIterator();
            while (value_iter.next()) |value| {
                self.allocator.free(value.*);
            }
            file_cache.deinit();
        }

        for (self.diagnostics.items) |diag| {
            try diag.format(writer);

            const content = file_cache.get(diag.file_path) orelse blk: {
                const file = if (std.fs.path.isAbsolute(diag.file_path))
                    std.fs.openFileAbsolute(diag.file_path, .{})
                else
                    std.fs.cwd().openFile(diag.file_path, .{});
                const opened_file = file catch break :blk null;
                defer opened_file.close();

                const max_size = 10 * 1024 * 1024;
                const loaded = opened_file.readToEndAllocOptions(
                    self.allocator,
                    max_size,
                    null,
                    std.mem.Alignment.of(u8),
                    0,
                ) catch break :blk null;
                file_cache.put(diag.file_path, loaded) catch {
                    self.allocator.free(loaded);
                    break :blk null;
                };
                break :blk loaded;
            };

            if (content) |file_content| {
                if (lineSliceFor(file_content, diag.range.start.line)) |line| {
                    try writer.print("  {s}\n", .{line});

                    const line_len = line.len;
                    var start_col = diag.range.start.column;
                    if (start_col == 0) {
                        start_col = 1;
                    }
                    if (line_len > 0 and start_col > line_len) {
                        start_col = line_len;
                    }

                    var end_col: usize = start_col;
                    if (diag.range.end.line == diag.range.start.line) {
                        end_col = diag.range.end.column;
                    }
                    if (end_col < start_col) {
                        end_col = start_col;
                    }
                    if (line_len > 0 and end_col > line_len) {
                        end_col = line_len;
                    }

                    const caret_len = if (line_len == 0) 1 else @max(end_col - start_col + 1, 1);
                    try writer.writeAll("  ");
                    var space_index: usize = 1;
                    while (space_index < start_col) : (space_index += 1) {
                        try writer.writeByte(' ');
                    }
                    var caret_index: usize = 0;
                    while (caret_index < caret_len) : (caret_index += 1) {
                        try writer.writeByte('^');
                    }
                    try writer.writeByte('\n');
                }
            }
        }
    }

    fn lineSliceFor(content: []const u8, line_number: usize) ?[]const u8 {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var current_line: usize = 1;
        while (line_iter.next()) |line| : (current_line += 1) {
            if (current_line == line_number) {
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    return line[0 .. line.len - 1];
                }
                return line;
            }
        }
        return null;
    }

    fn printJsonResults(self: *Analyzer, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.print("  \"diagnostics\": [\n", .{});

        for (self.diagnostics.items, 0..) |diag, i| {
            try diag.writeJson(writer);
            if (i < self.diagnostics.items.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("  ],\n");
        try writer.print("  \"total\": {d}\n", .{self.diagnostics.items.len});
        try writer.writeAll("}\n");
    }

    fn writeJsonString(writer: anytype, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    fn printSarifResults(self: *Analyzer, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"version\": \"2.1.0\",\n");
        try writer.writeAll("  \"$schema\": \"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json\",\n");
        try writer.writeAll("  \"runs\": [\n");
        try writer.writeAll("    {\n");
        try writer.writeAll("      \"tool\": {\n");
        try writer.writeAll("        \"driver\": {\n");
        try writer.writeAll("          \"name\": \"Zwanzig\",\n");
        try writer.writeAll("          \"informationUri\": \"https://github.com/forketyfork/zwanzig\",\n");
        try writer.writeAll("          \"version\": ");
        try writeJsonString(writer, self.tool_version);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"rules\": [\n");

        var first = true;
        for (self.checker_manager.checkers.items) |checker| {
            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.writeAll("            {\n");
            try writer.writeAll("              \"id\": ");
            try writeJsonString(writer, checker.name);
            try writer.writeAll(",\n");
            try writer.writeAll("              \"shortDescription\": {\n");
            try writer.writeAll("                \"text\": ");
            try writeJsonString(writer, checker.name);
            try writer.writeAll("\n");
            try writer.writeAll("              },\n");
            try writer.writeAll("              \"defaultConfiguration\": {\n");
            try writer.writeAll("                \"level\": ");
            try writeJsonString(writer, checker.default_severity.toSarifLevel());
            try writer.writeAll("\n");
            try writer.writeAll("              }\n");
            try writer.writeAll("            }");
        }

        for (self.checker_manager.adapted_rules.items) |rule| {
            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.writeAll("            {\n");
            try writer.writeAll("              \"id\": ");
            try writeJsonString(writer, rule.name);
            try writer.writeAll(",\n");
            try writer.writeAll("              \"shortDescription\": {\n");
            try writer.writeAll("                \"text\": ");
            try writeJsonString(writer, rule.name);
            try writer.writeAll("\n");
            try writer.writeAll("              }\n");
            try writer.writeAll("            }");
        }

        try writer.writeAll("\n");
        try writer.writeAll("          ]\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("      },\n");
        try writer.writeAll("      \"results\": [\n");

        for (self.diagnostics.items, 0..) |diag, i| {
            try diag.writeSarif(writer);
            if (i < self.diagnostics.items.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("      ]\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }

    pub fn hasDiagnostics(self: *Analyzer) bool {
        return self.diagnostics.items.len > 0;
    }

    /// Get the total number of registered checkers and rules.
    pub fn totalCheckerCount(self: *const Analyzer) usize {
        return self.checker_manager.totalCount();
    }
};

test "Analyzer JSON output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag1 = try Diagnostic.init(
        allocator,
        "test1.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    const diag2 = try Diagnostic.init(
        allocator,
        "test2.zig",
        "other-rule",
        .warning,
        "Test warning",
        SourceRange.init(Location.init(2, 3), Location.init(2, 8)),
    );

    try analyzer.diagnostics.append(allocator, diag1);
    try analyzer.diagnostics.append(allocator, diag2);

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try analyzer.printJsonResults(stream.writer());

    const output = stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"diagnostics\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"total\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test-rule") != null);
    try testing.expect(std.mem.indexOf(u8, output, "other-rule") != null);
}

test "Analyzer text output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag = try Diagnostic.init(
        allocator,
        "test.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    try analyzer.diagnostics.append(allocator, diag);

    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try analyzer.printTextResults(stream.writer());

    const output = stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Found 1 issue(s):") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test.zig:1:1") != null);
}

test "Analyzer SARIF output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag1 = try Diagnostic.init(
        allocator,
        "test1.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    const diag2 = try Diagnostic.init(
        allocator,
        "test2.zig",
        "other-rule",
        .warning,
        "Test warning",
        SourceRange.init(Location.init(2, 3), Location.init(2, 8)),
    );

    try analyzer.diagnostics.append(allocator, diag1);
    try analyzer.diagnostics.append(allocator, diag2);

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try analyzer.printSarifResults(stream.writer());

    const output = stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"version\": \"2.1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"$schema\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"runs\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"tool\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"driver\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"name\": \"Zwanzig\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"rules\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"results\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test-rule") != null);
    try testing.expect(std.mem.indexOf(u8, output, "other-rule") != null);
}

test "Analyzer cache enabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache_dir = try std.fs.cwd().makeOpenPath("test-analyzer-cache", .{});
    defer {
        cache_dir.close();
        std.fs.cwd().deleteTree("test-analyzer-cache") catch |err| {
            log.warn("failed to clean up test directory: {}", .{err});
        };
    }

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try analyzer.enableCache();
    try testing.expect(analyzer.use_cache);
    try testing.expect(analyzer.cache != null);
}

test "Analyzer cache hit still produces diagnostics" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const DupeImportRule = @import("rules/dupe_import.zig").DupeImportRule;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // File with duplicate imports to trigger a diagnostic
    const test_file_content =
        \\const std = @import("std");
        \\const std2 = @import("std");
    ;
    const test_file = try tmp_dir.dir.createFile("test.zig", .{});
    try test_file.writeAll(test_file_content);
    test_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.zig", &path_buf);

    var first_run_diag_count: usize = 0;

    // First run - populates cache
    {
        var analyzer1 = Analyzer.init(allocator);
        defer analyzer1.deinit();
        try analyzer1.enableCache();
        try analyzer1.registerRule(&DupeImportRule.rule);

        try analyzer1.analyzeFile(test_file_path);
        first_run_diag_count = analyzer1.diagnostics.items.len;
        try testing.expect(first_run_diag_count > 0);
    }

    // Second run - should hit cache but still produce same diagnostics
    {
        var analyzer2 = Analyzer.init(allocator);
        defer analyzer2.deinit();
        try analyzer2.enableCache();
        try analyzer2.registerRule(&DupeImportRule.rule);

        try analyzer2.analyzeFile(test_file_path);
        try testing.expectEqual(first_run_diag_count, analyzer2.diagnostics.items.len);
    }
}
