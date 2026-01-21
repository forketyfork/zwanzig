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
        for (self.diagnostics.items) |diag| {
            try diag.format(writer);
        }
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
        try writer.writeAll("          \"version\": \"0.1.0\",\n");
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

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const msg1 = try allocator.dupe(u8, "Test error");
    const msg2 = try allocator.dupe(u8, "Test warning");

    const diag1 = Diagnostic.init(
        "test1.zig",
        "test-rule",
        .err,
        msg1,
        @import("diagnostic.zig").SourceRange.init(
            @import("diagnostic.zig").Location.init(1, 1),
            @import("diagnostic.zig").Location.init(1, 5),
        ),
    );

    const diag2 = Diagnostic.init(
        "test2.zig",
        "other-rule",
        .warning,
        msg2,
        @import("diagnostic.zig").SourceRange.init(
            @import("diagnostic.zig").Location.init(2, 3),
            @import("diagnostic.zig").Location.init(2, 8),
        ),
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

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const msg = try allocator.dupe(u8, "Test error");

    const diag = Diagnostic.init(
        "test.zig",
        "test-rule",
        .err,
        msg,
        @import("diagnostic.zig").SourceRange.init(
            @import("diagnostic.zig").Location.init(1, 1),
            @import("diagnostic.zig").Location.init(1, 5),
        ),
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

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const msg1 = try allocator.dupe(u8, "Test error");
    const msg2 = try allocator.dupe(u8, "Test warning");

    const diag1 = Diagnostic.init(
        "test1.zig",
        "test-rule",
        .err,
        msg1,
        @import("diagnostic.zig").SourceRange.init(
            @import("diagnostic.zig").Location.init(1, 1),
            @import("diagnostic.zig").Location.init(1, 5),
        ),
    );

    const diag2 = Diagnostic.init(
        "test2.zig",
        "other-rule",
        .warning,
        msg2,
        @import("diagnostic.zig").SourceRange.init(
            @import("diagnostic.zig").Location.init(2, 3),
            @import("diagnostic.zig").Location.init(2, 8),
        ),
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
