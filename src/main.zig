const std = @import("std");
const build_options = @import("build_options");
const cli_run = @import("cli/run.zig");

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
    _ = @import("checkers/optional_unwrap_engine.zig");
    _ = @import("build_metadata.zig");
    _ = @import("config.zig");
    _ = @import("cache.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/config_merge.zig");
    _ = @import("cli/registry.zig");
    _ = @import("cli/run.zig");
}

pub fn main() !void {
    try cli_run.run();
}
