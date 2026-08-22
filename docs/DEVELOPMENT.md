# Development notes

## Zig toolchains

The default development shell uses Zig 0.15.2:

```bash
nix develop
```

The migration shell uses Zig 0.16.0:

```bash
nix develop .#zig016
```

Run `just test` and `just lint` in both shells when changing code that touches the embedded frontend or its compatibility adapters.

## macOS SDK workaround

On macOS 26.x hosts the active `MacOSX.sdk/usr/lib/libSystem.tbd` only advertises `arm64e-macos`, so Zig 0.15.2 cannot link the build runner and emits a long list of undefined libSystem symbols (`__availability_version_check`, `_realpath$DARWIN_EXTSN`, etc.). Upstream tracker: <https://codeberg.org/ziglang/zig/issues/31756>.

`flake.nix`'s Darwin `shellHook` sources `scripts/setup-macos-sdk-workaround.sh`, which detects the broken stub and, when needed, materializes a fake `DEVELOPER_DIR` under `.tmp/macos-sdk-workaround` that points at `MacOSX15.4.sdk` (the most recent SDK that still lists `arm64-macos`). A narrow `xcrun --sdk macosx --show-sdk-path` shim is prepended to `PATH` so Zig's internal SDK lookup picks up the same path. The hook is a no-op when the active SDK already advertises `arm64-macos`, when `MacOSX15.4.sdk` is missing, or on non-Darwin systems.

Remove the script and the corresponding `flake.nix` lines once Zwanzig moves off Zig 0.15.2 or upstream resolves the arm64e-only stub regression.

## Architecture

Main components:

- `cli/` - CLI parsing, config merge, default registry, and run loop
- `main.zig` - CLI entrypoint that delegates to `cli/run.zig`
- `analyzer.zig` - File reading, rule/checker execution, and result collection
- `formatters/` - Output formatters (console, SARIF)
- `source.zig` - Lazy AST/token parsing with caching
- `diagnostic.zig` - Diagnostic model with severity and locations
- `rule.zig` - Rule interface for AST-based checks
- `checker.zig` - Checker interface for AST/CFG-based analysis
- `rules/` - Individual rule implementations
- `checkers/` - Checker implementations (AST and engine-backed)
- `cfg.zig` / `cfg/` - CFG facade and modular CFG builder/graph/dot code
- `engine.zig` / `engine/` - Engine facade and modular analysis/state/value code
- `zir_bridge.zig` / `zir/` / `types/` - ZIR bridge and type info plumbing
- `file_discovery.zig` - Recursive file discovery
- `lib.zig` - Public library exports for embedding

## Parsing cache

Parsing is lazy and cached. Each file is parsed at most once, regardless of how many rules inspect it.

## Diagnostics

Each diagnostic includes severity (`hint`, `warning`, `err`), precise location, and the rule that found it:

```
file.zig:5:10: warning: [empty-catch-engine] Empty catch block
```

## Adding new rules

1. Create `src/rules/my_rule.zig`
2. Implement the `Rule` interface
3. Register in `src/cli/registry.zig` (for the CLI)

Example:

```zig
const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Source = @import("../source.zig").Source;

pub const MyRule = struct {
    pub const rule: Rule = .{
        .name = "my-rule",
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const ast = try src.ast();
        // Analyze the AST and append to diagnostics...
        _ = allocator;
        _ = ast;
    }
};
```

For CFG-based checkers, see `src/checkers/` for examples.

For more detail, see docs/IMPLEMENTATION.md.
