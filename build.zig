const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const log_level = b.option(std.log.Level, "log-level", "Set log level") orelse .info;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", options);

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "zwanzig",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the analyzer");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);

    // Create unit tests (tests embedded in source files)
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Create fixture tests
    const fixture_test_module = b.createModule(.{
        .root_source_file = b.path("test/fixture_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fixture_tests = b.addTest(.{
        .root_module = fixture_test_module,
    });

    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    const fixture_test_step = b.step("test-fixtures", "Run fixture-based tests");
    fixture_test_step.dependOn(&run_fixture_tests.step);

    // Also run fixture tests as part of the main test step
    test_step.dependOn(&run_fixture_tests.step);

    // Check fixtures compile (validates that all fixtures are valid Zig code)
    const check_fixtures_step = b.step("check-fixtures", "Verify all test fixtures compile");
    addFixtureChecks(b, check_fixtures_step, target, optimize);
}

fn addFixtureChecks(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const fixture_dirs = [_][]const u8{
        "test/fixtures/empty_catch",
        "test/fixtures/dupe_import",
        "test/fixtures/todo_comment",
        "test/fixtures/empty_errdefer",
        "test/fixtures/empty_defer",
        "test/fixtures/unreachable_code",
        "test/fixtures/file_as_struct",
        "test/fixtures/unused_decl",
    };

    for (fixture_dirs) |dir_path| {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

            const full_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            const check = b.addObject(.{
                .name = entry.name,
                .root_source_file = b.path(full_path),
                .target = target,
                .optimize = optimize,
            });

            step.dependOn(&check.step);
        }
    }
}
