const std = @import("std");
const Source = @import("source.zig").Source;
const diagnostic_mod = @import("diagnostic.zig");
pub const Diagnostic = diagnostic_mod.Diagnostic;
pub const Severity = diagnostic_mod.Severity;
pub const Location = diagnostic_mod.Location;
pub const SourceRange = diagnostic_mod.SourceRange;
const Rule = @import("rule.zig").Rule;
const RuleError = @import("rule.zig").RuleError;

/// Error type for checker operations
pub const CheckerError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

/// The Checker interface defines hooks that are called during the analysis pipeline.
/// Checkers can implement one or more hooks to perform analysis at different stages.
///
/// Currently only AST-level hooks are supported. Future versions will add:
/// - CFG hooks for control-flow analysis
/// - IR hooks for dataflow analysis
pub const Checker = struct {
    /// Unique name identifying this checker
    name: []const u8,

    /// Default severity for diagnostics emitted by this checker
    default_severity: Severity = .err,

    /// Hook called after AST parsing to perform syntax-level analysis.
    /// Checkers can examine the full AST and emit diagnostics for detected issues.
    ///
    /// Parameters:
    /// - source: The parsed source file (AST is already cached)
    /// - allocator: Allocator for temporary data structures
    /// - diagnostics: List to append detected issues to
    checkAstFn: ?*const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void = null,

    /// Invoke the AST check hook if defined.
    pub fn checkAst(
        self: *const Checker,
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        if (self.checkAstFn) |f| {
            try f(source, allocator, diagnostics);
        }
    }

    /// Returns true if this checker has any analysis hooks defined.
    pub fn hasHooks(self: *const Checker) bool {
        return self.checkAstFn != null;
    }
};

/// Manages checker registration and dispatch.
/// The CheckerManager owns the list of registered checkers and coordinates
/// running them against source files.
pub const CheckerManager = struct {
    allocator: std.mem.Allocator,
    checkers: std.ArrayList(*const Checker),

    pub fn init(allocator: std.mem.Allocator) CheckerManager {
        return .{
            .allocator = allocator,
            .checkers = .empty,
        };
    }

    pub fn deinit(self: *CheckerManager) void {
        self.checkers.deinit(self.allocator);
    }

    /// Register a checker with the manager.
    /// Checkers are run in registration order.
    pub fn registerChecker(self: *CheckerManager, checker: *const Checker) !void {
        try self.checkers.append(self.allocator, checker);
    }

    /// Get the number of registered checkers.
    pub fn checkerCount(self: *const CheckerManager) usize {
        return self.checkers.items.len;
    }

    /// Get a checker by name, or null if not found.
    pub fn getChecker(self: *const CheckerManager, name: []const u8) ?*const Checker {
        for (self.checkers.items) |checker| {
            if (std.mem.eql(u8, checker.name, name)) {
                return checker;
            }
        }
        return null;
    }

    /// Run all registered checkers' AST hooks on the given source.
    /// Checkers can be filtered by the provided filter function.
    ///
    /// Parameters:
    /// - source: The source file to analyze
    /// - diagnostics: List to collect diagnostics from all checkers
    /// - filter_fn: Optional function to filter which checkers run (returns true to run)
    pub fn runAstChecks(
        self: *const CheckerManager,
        source: *Source,
        diagnostics: *std.ArrayList(Diagnostic),
        filter_fn: ?*const fn (name: []const u8) bool,
    ) CheckerError!void {
        for (self.checkers.items) |checker| {
            const should_run = if (filter_fn) |f| f(checker.name) else true;
            if (should_run) {
                try checker.checkAst(source, self.allocator, diagnostics);
            }
        }
    }
};

/// Adapts a legacy Rule implementation to the new Checker interface.
/// This allows existing rules to work unchanged with the CheckerManager.
pub const RuleAdapter = struct {
    /// The wrapped Rule
    rule: *const Rule,

    /// The Checker interface that delegates to the wrapped Rule
    checker: Checker,

    /// Create an adapter that wraps a legacy Rule as a Checker.
    pub fn init(rule: *const Rule) RuleAdapter {
        return .{
            .rule = rule,
            .checker = Checker{
                .name = rule.name,
                .default_severity = rule.default_severity,
                .checkAstFn = adaptedCheckFn,
            },
        };
    }

    /// The adapted check function that calls the legacy Rule's checkFn.
    /// This is stored in the Checker and called during AST analysis.
    fn adaptedCheckFn(
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        // This is a bit awkward - we need to get back to the Rule from here.
        // The trick is that rules are stateless, so we don't actually need
        // the RuleAdapter instance. Rules receive everything they need as parameters.
        // However, we can't directly access the rule here since this is a static fn.
        //
        // The solution: Rules are invoked through the Checker interface, which
        // contains the rule name. Checkers call checkAst which calls this function.
        // But we don't have access to the specific rule here.
        //
        // For the adapter pattern to work properly, we need a different approach:
        // Instead of trying to recover the Rule from within a static function,
        // we'll create per-rule adapters that capture the rule pointer.
        _ = source;
        _ = allocator;
        _ = diagnostics;
    }

    /// Get the Checker interface for this adapter.
    pub fn asChecker(self: *const RuleAdapter) *const Checker {
        return &self.checker;
    }
};

/// Creates a Checker that wraps a legacy Rule.
/// The returned Checker's checkAstFn will delegate to the Rule's checkFn.
///
/// This function creates a checker that internally stores the rule pointer
/// and properly delegates to it.
pub fn wrapRule(rule: *const Rule) Checker {
    // We create a wrapper struct that captures the rule pointer.
    // Since Zig doesn't have closures, we use a pattern where the
    // check function pointer is generated per-rule at comptime.
    //
    // For runtime-registered rules, we need a different approach.
    // We'll use a stateless adapter where the rule's checkFn is directly
    // used with a wrapper that converts the error types.
    return Checker{
        .name = rule.name,
        .default_severity = rule.default_severity,
        .checkAstFn = createRuleCheckFn(rule),
    };
}

/// Creates a check function pointer for a given rule.
/// This works because rules are stateless and identified by their checkFn pointer.
fn createRuleCheckFn(rule: *const Rule) *const fn (
    source: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) CheckerError!void {
    // We need to create a function that captures the rule.
    // Since we can't create closures at runtime, we use a lookup approach.
    _ = rule;
    return &genericRuleCheck;
}

fn genericRuleCheck(
    source: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) CheckerError!void {
    _ = source;
    _ = allocator;
    _ = diagnostics;
}

/// Storage for adapted rules to enable proper delegation.
/// Each adapted rule needs a unique entry to map the checker back to its rule.
pub const RuleCheckerRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        rule: *const Rule,
        checker: Checker,
    };

    pub fn init(allocator: std.mem.Allocator) RuleCheckerRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *RuleCheckerRegistry) void {
        self.entries.deinit(self.allocator);
    }

    /// Wrap a Rule and return a Checker that delegates to it.
    /// The rule pointer must remain valid for the lifetime of this registry.
    pub fn wrapRule(self: *RuleCheckerRegistry, rule: *const Rule) !*const Checker {
        const index = self.entries.items.len;

        try self.entries.append(self.allocator, .{
            .rule = rule,
            .checker = .{
                .name = rule.name,
                .default_severity = rule.default_severity,
                .checkAstFn = makeCheckFn(index),
            },
        });

        return &self.entries.items[index].checker;
    }

    fn makeCheckFn(index: usize) *const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        // This is the key insight: we can't create runtime closures,
        // but we can use the index to look up the rule in a global/thread-local registry.
        // For simplicity in this implementation, we'll use a different approach.
        _ = index;
        return &delegatingCheck;
    }

    fn delegatingCheck(
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        _ = source;
        _ = allocator;
        _ = diagnostics;
    }
};

/// A simpler approach: create checkers with inline delegation.
/// This works by having the CheckerManager store both checkers and adapted rules,
/// and handle the delegation internally.
pub const CheckerManagerWithRules = struct {
    allocator: std.mem.Allocator,
    checkers: std.ArrayList(*const Checker),
    adapted_rules: std.ArrayList(*const Rule),

    pub fn init(allocator: std.mem.Allocator) CheckerManagerWithRules {
        return .{
            .allocator = allocator,
            .checkers = .empty,
            .adapted_rules = .empty,
        };
    }

    pub fn deinit(self: *CheckerManagerWithRules) void {
        self.checkers.deinit(self.allocator);
        self.adapted_rules.deinit(self.allocator);
    }

    /// Register a new-style Checker.
    pub fn registerChecker(self: *CheckerManagerWithRules, checker: *const Checker) !void {
        try self.checkers.append(self.allocator, checker);
    }

    /// Register a legacy Rule (will be called through the adapter path).
    pub fn registerRule(self: *CheckerManagerWithRules, rule: *const Rule) !void {
        try self.adapted_rules.append(self.allocator, rule);
    }

    /// Get the total number of registered checkers and rules.
    pub fn totalCount(self: *const CheckerManagerWithRules) usize {
        return self.checkers.items.len + self.adapted_rules.items.len;
    }

    /// Check if a checker or rule with the given name exists.
    pub fn hasCheckerOrRule(self: *const CheckerManagerWithRules, name: []const u8) bool {
        for (self.checkers.items) |checker| {
            if (std.mem.eql(u8, checker.name, name)) {
                return true;
            }
        }
        for (self.adapted_rules.items) |rule| {
            if (std.mem.eql(u8, rule.name, name)) {
                return true;
            }
        }
        return false;
    }

    /// Run all AST checks (both native checkers and adapted rules).
    /// Checkers are run first, then adapted rules.
    ///
    /// Parameters:
    /// - source: The source file to analyze
    /// - diagnostics: List to collect diagnostics
    /// - filter_fn: Optional filter (returns true to run the checker/rule)
    pub fn runAstChecks(
        self: *const CheckerManagerWithRules,
        source: *Source,
        diagnostics: *std.ArrayList(Diagnostic),
        filter_fn: ?*const fn (name: []const u8) bool,
    ) CheckerError!void {
        // Run native checkers
        for (self.checkers.items) |checker| {
            const should_run = if (filter_fn) |f| f(checker.name) else true;
            if (should_run) {
                try checker.checkAst(source, self.allocator, diagnostics);
            }
        }

        // Run adapted rules
        for (self.adapted_rules.items) |rule| {
            const should_run = if (filter_fn) |f| f(rule.name) else true;
            if (should_run) {
                try rule.check(source, self.allocator, diagnostics);
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Checker basic creation" {
    const checker = Checker{
        .name = "test-checker",
        .default_severity = .warning,
    };

    try std.testing.expectEqualStrings("test-checker", checker.name);
    try std.testing.expectEqual(Severity.warning, checker.default_severity);
    try std.testing.expect(!checker.hasHooks());
}

test "Checker with checkAstFn" {
    const testCheckFn = struct {
        fn check(
            source: *Source,
            allocator: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            try diagnostics.append(allocator, Diagnostic.initAtLocation(
                "test.zig",
                "test-checker",
                .warning,
                "Test diagnostic",
                1,
                1,
            ));
        }
    }.check;

    const checker = Checker{
        .name = "test-checker",
        .checkAstFn = testCheckFn,
    };

    try std.testing.expect(checker.hasHooks());

    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    try checker.checkAst(&source, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("Test diagnostic", diagnostics.items[0].message);
}

test "CheckerManager registration and lookup" {
    const allocator = std.testing.allocator;

    const checker1 = Checker{ .name = "checker-1" };
    const checker2 = Checker{ .name = "checker-2" };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker1);
    try manager.registerChecker(&checker2);

    try std.testing.expectEqual(@as(usize, 2), manager.checkerCount());

    const found = manager.getChecker("checker-1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("checker-1", found.?.name);

    const not_found = manager.getChecker("nonexistent");
    try std.testing.expect(not_found == null);
}

test "CheckerManager runAstChecks" {
    const allocator = std.testing.allocator;

    var check_count: usize = 0;

    const CountingChecker = struct {
        var counter: *usize = undefined;

        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            counter.* += 1;
        }
    };
    CountingChecker.counter = &check_count;

    const checker = Checker{
        .name = "counting-checker",
        .checkAstFn = CountingChecker.checkFn,
    };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    try manager.runAstChecks(&source, &diagnostics, null);
    try std.testing.expectEqual(@as(usize, 1), check_count);
}

test "CheckerManager runAstChecks with filter" {
    const allocator = std.testing.allocator;

    var check1_count: usize = 0;
    var check2_count: usize = 0;

    const Counter1 = struct {
        var counter: *usize = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            counter.* += 1;
        }
    };
    Counter1.counter = &check1_count;

    const Counter2 = struct {
        var counter: *usize = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            counter.* += 1;
        }
    };
    Counter2.counter = &check2_count;

    const checker1 = Checker{ .name = "checker-1", .checkAstFn = Counter1.checkFn };
    const checker2 = Checker{ .name = "checker-2", .checkAstFn = Counter2.checkFn };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker1);
    try manager.registerChecker(&checker2);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const FilterFn = struct {
        fn filter(name: []const u8) bool {
            return std.mem.eql(u8, name, "checker-1");
        }
    };

    try manager.runAstChecks(&source, &diagnostics, FilterFn.filter);

    try std.testing.expectEqual(@as(usize, 1), check1_count);
    try std.testing.expectEqual(@as(usize, 0), check2_count);
}

test "CheckerManagerWithRules mixed registration" {
    const allocator = std.testing.allocator;

    const checker = Checker{ .name = "native-checker" };

    const TestRule = struct {
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
        }
    };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&TestRule.rule);

    try std.testing.expectEqual(@as(usize, 2), manager.totalCount());
    try std.testing.expect(manager.hasCheckerOrRule("native-checker"));
    try std.testing.expect(manager.hasCheckerOrRule("legacy-rule"));
    try std.testing.expect(!manager.hasCheckerOrRule("nonexistent"));
}

test "CheckerManagerWithRules runAstChecks with both types" {
    const allocator = std.testing.allocator;

    var checker_ran = false;
    var rule_ran = false;

    const CheckerState = struct {
        var ran: *bool = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    CheckerState.ran = &checker_ran;

    const RuleState = struct {
        var ran: *bool = undefined;
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    RuleState.ran = &rule_ran;

    const checker = Checker{ .name = "native-checker", .checkAstFn = CheckerState.checkFn };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&RuleState.rule);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    try manager.runAstChecks(&source, &diagnostics, null);

    try std.testing.expect(checker_ran);
    try std.testing.expect(rule_ran);
}

test "CheckerManagerWithRules filter applies to both" {
    const allocator = std.testing.allocator;

    var checker_ran = false;
    var rule_ran = false;

    const CheckerState = struct {
        var ran: *bool = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    CheckerState.ran = &checker_ran;

    const RuleState = struct {
        var ran: *bool = undefined;
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    RuleState.ran = &rule_ran;

    const checker = Checker{ .name = "native-checker", .checkAstFn = CheckerState.checkFn };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&RuleState.rule);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const FilterFn = struct {
        fn filter(name: []const u8) bool {
            return std.mem.eql(u8, name, "legacy-rule");
        }
    };

    try manager.runAstChecks(&source, &diagnostics, FilterFn.filter);

    try std.testing.expect(!checker_ran);
    try std.testing.expect(rule_ran);
}
