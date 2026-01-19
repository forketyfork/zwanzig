const std = @import("std");
const Analyzer = @import("analyzer.zig").Analyzer;
const Rule = @import("rule.zig").Rule;
const EmptyCatchRule = @import("rules/empty_catch.zig").EmptyCatchRule;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    // Initialize analyzer
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    // Register rules
    try analyzer.registerRule(&EmptyCatchRule.rule);

    // Analyze files
    for (args[1..]) |file_path| {
        try analyzer.analyzeFile(file_path);
    }

    // Print results
    try analyzer.printResults();

    // Exit with error code if violations found
    if (analyzer.hasViolations()) {
        std.process.exit(1);
    }
}

fn printUsage() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("Usage: zwanzig <file.zig> [file.zig...]\n");
    try stderr.writeAll("\nA static analyzer for Zig code.\n");
    try stderr.writeAll("\nOptions:\n");
    try stderr.writeAll("  <file.zig>  Zig source file(s) to analyze\n");
}

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
