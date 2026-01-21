const std = @import("std");
const Rule = @import("rule.zig").Rule;
const Diagnostic = @import("rule.zig").Diagnostic;
const Source = @import("source.zig").Source;
const RuleFilter = @import("rule_filter.zig").RuleFilter;
const checker_mod = @import("checker.zig");
const Checker = checker_mod.Checker;
const CheckerManagerWithRules = checker_mod.CheckerManagerWithRules;
const ZirBridge = @import("zir_bridge.zig").ZirBridge;
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    checker_manager: CheckerManagerWithRules,
    diagnostics: std.ArrayList(Diagnostic),
    rule_filter: RuleFilter,
    zir_bridge: ?ZirBridge = null,
    use_typed_ir: bool = false,
    build_metadata: ?BuildMetadata = null,

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
        for (self.diagnostics.items) |diag| {
            self.allocator.free(@constCast(diag.message));
        }
        self.diagnostics.deinit(self.allocator);
        if (self.zir_bridge) |*bridge| {
            bridge.deinit();
        }
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
    }

    /// Enable typed IR analysis using ZirBridge.
    pub fn enableTypedIr(self: *Analyzer) void {
        self.use_typed_ir = true;
        if (self.zir_bridge == null) {
            self.zir_bridge = ZirBridge.init(self.allocator);
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

    pub fn setBuildMetadata(self: *Analyzer, metadata: BuildMetadata) !void {
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
        self.build_metadata = try metadata.clone(self.allocator);
    }

    pub fn getBuildMetadata(self: *const Analyzer) ?*const BuildMetadata {
        if (self.build_metadata) |*meta| {
            return meta;
        }
        return null;
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

    pub fn analyzeFile(self: *Analyzer, file_path: []const u8) !void {
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

        if (self.use_typed_ir) {
            try self.loadTypedIr(&source);
        }

        try self.runChecksOnSource(&source);
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
        const context = checker_mod.CheckerContext{
            .build_metadata = self.getBuildMetadata(),
        };

        // Run native checkers
        for (self.checker_manager.checkers.items) |chkr| {
            if (self.isRuleEnabled(chkr.name)) {
                try chkr.checkAst(source, self.allocator, &self.diagnostics, context);
            }
        }

        // Run adapted rules
        for (self.checker_manager.adapted_rules.items) |rule| {
            if (self.isRuleEnabled(rule.name)) {
                try rule.check(source, self.allocator, &self.diagnostics);
            }
        }
    }

    pub fn printResults(self: *Analyzer) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();

        if (self.diagnostics.items.len == 0) {
            try stdout.writeAll("No issues found.\n");
            return;
        }

        try stdout.print("Found {d} issue(s):\n", .{self.diagnostics.items.len});
        for (self.diagnostics.items) |diag| {
            try diag.format(stdout);
        }
    }

    pub fn hasDiagnostics(self: *Analyzer) bool {
        return self.diagnostics.items.len > 0;
    }

    /// Get the total number of registered checkers and rules.
    pub fn totalCheckerCount(self: *const Analyzer) usize {
        return self.checker_manager.totalCount();
    }
};
