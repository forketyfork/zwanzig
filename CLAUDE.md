# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zwanzig is a static analyzer and linter for Zig code. It uses a modular rule-based architecture with lazy AST parsing and caching for performance.

## Build Commands

```bash
zig build              # Build the project
zig build test         # Run all tests
zig build run -- <files>  # Run analyzer on files
zig fmt src            # Format code
zig fmt --check src/   # Check formatting (lint)
```

With `just` (recommended):
```bash
just build    # Build
just test     # Run tests
just lint     # Format check + shellcheck
just ci       # Full CI: build + test + lint
```

## Requirements

For any code changes, run both tests and linting:
- `just test`
- `just lint`

`just lint` also runs zwanzig on its own code. All issues should be fixed before submitting changes. If this is complicated or not possible, ask the user.

## Development Environment

Uses Nix flakes for reproducible dev environment (Zig 0.15.2). Enter with:
```bash
nix develop
```

## Architecture

### Data Flow
1. `main.zig` parses CLI args and registers rules/checkers with `Analyzer`
2. `Analyzer` reads files, creates `Source` objects, runs enabled rules and checkers
3. Rules/checkers receive `Source` and append `Diagnostic`s to a shared list
4. Analyzer reports results and exits with code 1 if diagnostics found

### Key Types
- **`Source`** (`src/source.zig`): Lazy-parsed source with cached AST. Call `ast()` or `tokens()` to parse on demand; subsequent calls return cached result.
- **`Rule`** (`src/rule.zig`): Interface with `name` and `checkFn`. Rules implement `check(source, allocator, diagnostics)`.
- **`Checker`** (`src/checker.zig`): Engine-based interface with `checkAstFn`. Checkers use CFG and analysis engine for sophisticated analysis.
- **`Analyzer`** (`src/analyzer.zig`): Orchestrates file reading, rule/checker execution, result collection.
- **`Diagnostic`**: Issue report with file path, line/column, rule name, severity, and message.

### Adding a New Rule

1. Create `src/rules/my_rule.zig`:
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

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const ast = try src.ast();  // Lazy parse, cached
        // Analysis logic...
        _ = allocator;
        _ = ast;
    }
};
```

2. Register in `src/main.zig`:
```zig
try analyzer.registerRule(&MyRule.rule);
```

For engine-based checkers (CFG analysis), see `src/checkers/` directory.

### CLI Flags
- `--do <rule>`: Run only specified rules (allowlist, repeatable)
- `--skip <rule>`: Skip specified rules (blocklist, repeatable)
- `--do` and `--skip` are mutually exclusive

## Testing

Tests are embedded in source files using Zig's `test` blocks. Run individual file tests:
```bash
zig test src/source.zig
```

## Code Style

- Zig standard formatting via `zig fmt`
- Tests colocated with implementation in the same file
- Rules in `src/rules/` directory, one file per rule
