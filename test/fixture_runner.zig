const std = @import("std");
const src = @import("src");
const Source = src.Source;
const Diagnostic = src.Diagnostic;
const Severity = src.Severity;
const Rule = src.Rule;
const checker_mod = src.checker;
const Checker = checker_mod.Checker;
const CheckerContext = checker_mod.CheckerContext;
const TypeContext = checker_mod.TypeContext;
const config_mod = src.config;

/// Expected diagnostic parsed from fixture comments.
/// All fields are optional - only specified fields will be checked.
pub const ExpectedDiagnostic = struct {
    line: ?usize = null,
    col: ?usize = null,
    rule: ?[]const u8 = null,
    severity: ?Severity = null,
    message: ?[]const u8 = null,

    pub fn matches(self: ExpectedDiagnostic, actual: Diagnostic) bool {
        if (self.line) |expected_line| {
            if (actual.range.start.line != expected_line) return false;
        }
        if (self.col) |expected_col| {
            if (actual.range.start.column != expected_col) return false;
        }
        if (self.rule) |expected_rule| {
            if (!std.mem.eql(u8, actual.rule_id, expected_rule)) return false;
        }
        if (self.severity) |expected_severity| {
            if (actual.severity != expected_severity) return false;
        }
        if (self.message) |expected_message| {
            // Check if message contains the expected substring
            if (std.mem.indexOf(u8, actual.message, expected_message) == null) return false;
        }
        return true;
    }
};

/// Result of parsing fixture expectations
pub const FixtureExpectations = struct {
    expects_none: bool,
    diagnostics: []ExpectedDiagnostic,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FixtureExpectations) void {
        self.allocator.free(self.diagnostics);
    }
};

/// Parse EXPECT comments from fixture content.
/// Format: // EXPECT: line=N col=M rule=name severity=level message=text
/// Or: // EXPECT: none (for no violations expected)
pub fn parseExpectations(allocator: std.mem.Allocator, content: []const u8) !FixtureExpectations {
    var expectations: std.ArrayList(ExpectedDiagnostic) = .empty;
    defer expectations.deinit(allocator);

    var expects_none = false;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "// EXPECT:")) {
            const rest = std.mem.trim(u8, trimmed["// EXPECT:".len..], " \t");

            if (std.mem.eql(u8, rest, "none")) {
                expects_none = true;
                continue;
            }

            const expected = parseExpectLine(rest);
            try expectations.append(allocator, expected);
        }
    }

    return FixtureExpectations{
        .expects_none = expects_none,
        .diagnostics = try expectations.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseExpectLine(line: []const u8) ExpectedDiagnostic {
    var expected = ExpectedDiagnostic{};

    var parts = std.mem.splitScalar(u8, line, ' ');
    while (parts.next()) |part| {
        if (part.len == 0) continue;

        if (std.mem.startsWith(u8, part, "line=")) {
            expected.line = std.fmt.parseInt(usize, part["line=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, part, "col=")) {
            expected.col = std.fmt.parseInt(usize, part["col=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, part, "rule=")) {
            expected.rule = part["rule=".len..];
        } else if (std.mem.startsWith(u8, part, "severity=")) {
            const sev_str = part["severity=".len..];
            expected.severity = if (std.mem.eql(u8, sev_str, "hint"))
                Severity.hint
            else if (std.mem.eql(u8, sev_str, "warning"))
                Severity.warning
            else if (std.mem.eql(u8, sev_str, "error"))
                Severity.err
            else
                null;
        } else if (std.mem.startsWith(u8, part, "message=")) {
            expected.message = part["message=".len..];
        }
    }

    return expected;
}

/// Run a rule against a fixture file and verify expectations.
pub fn runFixture(
    allocator: std.mem.Allocator,
    rule: *const Rule,
    fixture_path: []const u8,
    fixture_content: [:0]const u8,
) !void {
    var expectations = try parseExpectations(allocator, fixture_content);
    defer expectations.deinit();

    var source = Source.init(allocator, fixture_path, fixture_content);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try rule.check(&source, allocator, &diagnostics);

    // Verify expectations
    if (expectations.expects_none) {
        if (diagnostics.items.len != 0) {
            std.debug.print("\nFixture: {s}\n", .{fixture_path});
            std.debug.print("Expected no diagnostics, but got {d}:\n", .{diagnostics.items.len});
            for (diagnostics.items) |diag| {
                std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.file_path,
                    diag.range.start.line,
                    diag.range.start.column,
                    diag.rule_id,
                    diag.message,
                });
            }
            return error.UnexpectedDiagnostics;
        }
        return;
    }

    // Check that we got the expected number of diagnostics
    if (diagnostics.items.len != expectations.diagnostics.len) {
        std.debug.print("\nFixture: {s}\n", .{fixture_path});
        std.debug.print("Expected {d} diagnostics, but got {d}:\n", .{ expectations.diagnostics.len, diagnostics.items.len });
        for (diagnostics.items) |diag| {
            std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                diag.file_path,
                diag.range.start.line,
                diag.range.start.column,
                diag.rule_id,
                diag.message,
            });
        }
        return error.DiagnosticCountMismatch;
    }

    // Check that each expected diagnostic has a unique match (one-to-one correspondence)
    var matched = try allocator.alloc(bool, diagnostics.items.len);
    defer allocator.free(matched);
    @memset(matched, false);

    for (expectations.diagnostics, 0..) |expected, i| {
        var found = false;
        for (diagnostics.items, 0..) |actual, j| {
            if (!matched[j] and expected.matches(actual)) {
                matched[j] = true;
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\nFixture: {s}\n", .{fixture_path});
            std.debug.print("Expected diagnostic #{d} not found:\n", .{i + 1});
            if (expected.line) |l| std.debug.print("  line={d}\n", .{l});
            if (expected.col) |c| std.debug.print("  col={d}\n", .{c});
            if (expected.rule) |r| std.debug.print("  rule={s}\n", .{r});
            if (expected.severity) |s| std.debug.print("  severity={s}\n", .{s.toString()});
            if (expected.message) |m| std.debug.print("  message={s}\n", .{m});
            std.debug.print("\nActual diagnostics:\n", .{});
            for (diagnostics.items) |diag| {
                std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.file_path,
                    diag.range.start.line,
                    diag.range.start.column,
                    diag.rule_id,
                    diag.message,
                });
            }
            return error.ExpectedDiagnosticNotFound;
        }
    }
}

fn parseInlineConfig(allocator: std.mem.Allocator, content: []const u8) !?config_mod.Config {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var found = false;
    var config_text: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "// CONFIG:")) {
            if (found) return error.InvalidConfigFormat;
            const rest = std.mem.trim(u8, trimmed["// CONFIG:".len..], " \t");
            config_text = rest;
            found = true;
        }
    }

    if (config_text) |text| {
        return try config_mod.parseConfig(allocator, text);
    }
    return null;
}

/// Run a checker against a fixture file and verify expectations.
pub fn runCheckerFixture(
    allocator: std.mem.Allocator,
    checker: *const Checker,
    fixture_path: []const u8,
    fixture_content: [:0]const u8,
) !void {
    var expectations = try parseExpectations(allocator, fixture_content);
    defer expectations.deinit();

    var config_opt = try parseInlineConfig(allocator, fixture_content);
    defer if (config_opt) |*cfg| cfg.deinit(allocator);

    var source = Source.init(allocator, fixture_path, fixture_content);
    defer source.deinit();
    var type_ctx = TypeContext.init(allocator, &source);
    defer type_ctx.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    const context = CheckerContext{
        .build_metadata = null,
        .type_context = &type_ctx,
        .config = if (config_opt) |*cfg| cfg else null,
    };
    try checker.checkAst(&source, allocator, &diagnostics, context);

    if (expectations.expects_none) {
        if (diagnostics.items.len != 0) {
            std.debug.print("\nFixture: {s}\n", .{fixture_path});
            std.debug.print("Expected no diagnostics, but got {d}:\n", .{diagnostics.items.len});
            for (diagnostics.items) |diag| {
                std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.file_path,
                    diag.range.start.line,
                    diag.range.start.column,
                    diag.rule_id,
                    diag.message,
                });
            }
            return error.UnexpectedDiagnostics;
        }
        return;
    }

    if (diagnostics.items.len != expectations.diagnostics.len) {
        std.debug.print("\nFixture: {s}\n", .{fixture_path});
        std.debug.print("Expected {d} diagnostics, but got {d}:\n", .{ expectations.diagnostics.len, diagnostics.items.len });
        for (diagnostics.items) |diag| {
            std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                diag.file_path,
                diag.range.start.line,
                diag.range.start.column,
                diag.rule_id,
                diag.message,
            });
        }
        return error.DiagnosticCountMismatch;
    }

    var matched = try allocator.alloc(bool, diagnostics.items.len);
    defer allocator.free(matched);
    @memset(matched, false);

    for (expectations.diagnostics, 0..) |expected, i| {
        var found = false;
        for (diagnostics.items, 0..) |actual, j| {
            if (!matched[j] and expected.matches(actual)) {
                matched[j] = true;
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\nFixture: {s}\n", .{fixture_path});
            std.debug.print("Expected diagnostic #{d} not found:\n", .{i + 1});
            if (expected.line) |l| std.debug.print("  line={d}\n", .{l});
            if (expected.col) |c| std.debug.print("  col={d}\n", .{c});
            if (expected.rule) |r| std.debug.print("  rule={s}\n", .{r});
            if (expected.severity) |s| std.debug.print("  severity={s}\n", .{s.toString()});
            if (expected.message) |m| std.debug.print("  message={s}\n", .{m});
            std.debug.print("\nActual diagnostics:\n", .{});
            for (diagnostics.items) |diag| {
                std.debug.print("  - {s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.file_path,
                    diag.range.start.line,
                    diag.range.start.column,
                    diag.rule_id,
                    diag.message,
                });
            }
            return error.ExpectedDiagnosticNotFound;
        }
    }
}

/// Run all fixtures in a directory against a checker.
pub fn runCheckerFixturesInDir(
    allocator: std.mem.Allocator,
    checker: *const Checker,
    dir_path: []const u8,
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open fixture directory: {s}: {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const fixture_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(fixture_path);

        const file = try dir.openFile(entry.name, .{});
        defer file.close();

        const content = try file.readToEndAllocOptions(allocator, 1024 * 1024, null, .of(u8), 0);
        defer allocator.free(content);

        try runCheckerFixture(allocator, checker, fixture_path, content);
    }
}

/// Run all fixtures in a directory against a rule.
pub fn runFixturesInDir(
    allocator: std.mem.Allocator,
    rule: *const Rule,
    dir_path: []const u8,
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open fixture directory: {s}: {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const fixture_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(fixture_path);

        const file = try dir.openFile(entry.name, .{});
        defer file.close();

        const content = try file.readToEndAllocOptions(allocator, 1024 * 1024, null, .of(u8), 0);
        defer allocator.free(content);

        try runFixture(allocator, rule, fixture_path, content);
    }
}

// Tests for the fixture runner itself
test "parseExpectations - single expectation" {
    const allocator = std.testing.allocator;
    const content =
        \\// EXPECT: line=1 col=22 rule=empty-catch severity=warning
        \\const x = try_func() catch {};
    ;

    var expectations = try parseExpectations(allocator, content);
    defer expectations.deinit();

    try std.testing.expect(!expectations.expects_none);
    try std.testing.expectEqual(@as(usize, 1), expectations.diagnostics.len);
    try std.testing.expectEqual(@as(?usize, 1), expectations.diagnostics[0].line);
    try std.testing.expectEqual(@as(?usize, 22), expectations.diagnostics[0].col);
    try std.testing.expectEqualStrings("empty-catch", expectations.diagnostics[0].rule.?);
    try std.testing.expectEqual(Severity.warning, expectations.diagnostics[0].severity.?);
}

test "parseExpectations - none" {
    const allocator = std.testing.allocator;
    const content =
        \\// EXPECT: none
        \\const x = try_func() catch { doSomething(); };
    ;

    var expectations = try parseExpectations(allocator, content);
    defer expectations.deinit();

    try std.testing.expect(expectations.expects_none);
    try std.testing.expectEqual(@as(usize, 0), expectations.diagnostics.len);
}

test "parseExpectations - multiple expectations" {
    const allocator = std.testing.allocator;
    const content =
        \\// EXPECT: line=1 rule=empty-catch
        \\// EXPECT: line=3 rule=empty-catch
        \\const x = try_func() catch {};
        \\const y = other() catch { ok(); };
        \\const z = third() catch {};
    ;

    var expectations = try parseExpectations(allocator, content);
    defer expectations.deinit();

    try std.testing.expect(!expectations.expects_none);
    try std.testing.expectEqual(@as(usize, 2), expectations.diagnostics.len);
    try std.testing.expectEqual(@as(?usize, 1), expectations.diagnostics[0].line);
    try std.testing.expectEqual(@as(?usize, 3), expectations.diagnostics[1].line);
}

test "ExpectedDiagnostic.matches - partial match" {
    const expected = ExpectedDiagnostic{
        .line = 5,
        .rule = "test-rule",
    };

    const diag = Diagnostic{
        .file_path = "test.zig",
        .rule_id = "test-rule",
        .severity = .warning,
        .message = "Some message",
        .range = .{
            .start = .{ .line = 5, .column = 10 },
            .end = .{ .line = 5, .column = 15 },
        },
    };

    try std.testing.expect(expected.matches(diag));
}

test "ExpectedDiagnostic.matches - message substring" {
    const expected = ExpectedDiagnostic{
        .message = "unused",
    };

    const diag = Diagnostic{
        .file_path = "test.zig",
        .rule_id = "test-rule",
        .severity = .warning,
        .message = "Declaration 'foo' is unused",
        .range = .{
            .start = .{ .line = 1, .column = 1 },
            .end = .{ .line = 1, .column = 1 },
        },
    };

    try std.testing.expect(expected.matches(diag));
}
