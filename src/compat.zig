//! Compile-time gate for supported Zig toolchains.
//!
//! Zwanzig embeds the std.zig frontend (parser, AstGen, Zir) of the compiler
//! that builds it, and depends on unstable compiler-internal APIs. Only the
//! exact versions listed here are tested; anything else - including dev
//! builds and untested patch releases - must fail loudly at compile time.

const std = @import("std");
const builtin = @import("builtin");

pub const supported_zig_versions = [_]std.SemanticVersion{
    .{ .major = 0, .minor = 15, .patch = 2 },
};

comptime {
    var supported = false;
    for (supported_zig_versions) |v| {
        if (builtin.zig_version.order(v) == .eq) supported = true;
    }
    if (!supported) {
        @compileError("zwanzig does not support Zig " ++ builtin.zig_version_string ++
            "; supported versions: 0.15.2 (see docs/ZIG_0_16_MIGRATION_PLAN.md)");
    }
}
