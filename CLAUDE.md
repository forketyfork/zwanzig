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

## Development Environment

Uses Nix flakes for reproducible dev environment (Zig 0.15.2). Enter with:
```bash
nix develop
```

## Architecture

### Data Flow
1. `main.zig` parses CLI args and registers rules with `Analyzer`
2. `Analyzer` reads files, creates `Source` objects, runs enabled rules
3. Rules receive `Source` and append `Violation`s to a shared list
4. Analyzer reports results and exits with code 1 if violations found

### Key Types
- **`Source`** (`src/source.zig`): Lazy-parsed source with cached AST. Call `ast()` or `tokens()` to parse on demand; subsequent calls return cached result.
- **`Rule`** (`src/rule.zig`): Interface with `name` and `checkFn`. Rules implement `check(source, allocator, violations)`.
- **`Analyzer`** (`src/analyzer.zig`): Orchestrates file reading, rule execution, result collection.
- **`Violation`**: Diagnostic with file path, line/column, rule name, message.

### Adding a New Rule

1. Create `src/rules/my_rule.zig`:
```zig
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;

pub const MyRule = struct {
    pub const rule: Rule = .{
        .name = "my-rule",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, violations: *std.ArrayList(Violation)) RuleError!void {
        const ast = try src.ast();  // Lazy parse, cached
        // Analysis logic...
    }
};
```

2. Register in `src/main.zig`:
```zig
try analyzer.registerRule(&MyRule.rule);
```

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
