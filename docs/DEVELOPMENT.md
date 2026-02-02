# Development notes

## Architecture overview

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

For detailed implementation guidance, see docs/IMPLEMENTATION.md.
