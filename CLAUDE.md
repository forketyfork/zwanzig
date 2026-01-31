# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Overview

Zwanzig is a static analyzer and linter for Zig. It uses a modular rule-based architecture with lazy AST parsing and caching.

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

## Skills

- use zig-best-practices skill for writing or reviewing Zig code
- use zig-compiler-skill for any work related to the Zig compiler or its internals

## Requirements

For any code changes, run both tests and linting:
- `just test`
- `just lint`

`just lint` also runs zwanzig on its own code. All issues should be fixed before submitting changes. If this is complicated or not possible, ask the user.

All new rules/checkers must have test fixtures.

All code must be formatted with `zig fmt`.

Any changes or additions to the existing rules/checkers must be documented.

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
- **`Source`** (`src/source.zig`): Lazy-parsed source with cached AST. Call `ast()` or `tokens()` to parse on demand; subsequent calls return cached result. Also provides type information via `hasTypeInfo()`, `findDeclType()`, etc.
- **`Rule`** (`src/rule.zig`): Interface with `name` and `checkFn`. Rules implement `check(source, allocator, diagnostics)`.
- **`Checker`** (`src/checker.zig`): Engine-based interface with `checkAstFn`. Checkers use CFG and analysis engine for sophisticated analysis. Checkers receive a `CheckerContext` with optional `TypeContext` for type-aware analysis.
- **`Analyzer`** (`src/analyzer.zig`): Orchestrates file reading, rule/checker execution, result collection.
- **`Diagnostic`**: Issue report with file path, line/column, rule name, severity, and message. Diagnostics own their message strings; `Analyzer.deinit()` frees them.
- **`TypeContext`** (`src/type_context.zig`): Unified interface for type queries wrapping the ZIR bridge. Use `getDeclType()`, `classifyIdentifier()`, `isDeclFunction()`, etc.
- **`ZirBridge`** (`src/zir_bridge.zig`): Generates ZIR from source and extracts typed information (`TypeInfo`, `DeclInfo`).

### Adding a New Rule

1. Create `src/rules/my_rule.zig` implementing the `Rule` interface
2. Register in `src/main.zig`: `try analyzer.registerRule(&MyRule.rule);`

See existing rules in `src/rules/` for patterns. For CFG-based checkers, see `src/checkers/`.

### CLI Flags
- `--do <rule>`: Run only specified rules (allowlist, repeatable)
- `--skip <rule>`: Skip specified rules (blocklist, repeatable)
- `--do` and `--skip` are mutually exclusive
- `--dump-cfg <dir>`: Dump CFG DOT files for visualization (see Debugging section)

## Debugging

### CFG Visualization

Engine-based checkers use Control Flow Graphs (CFGs) for analysis. To visualize CFGs:

```bash
# Dump CFG DOT files to a directory
zig build run -- --dump-cfg ./cfg_output src/myfile.zig

# Convert DOT to PNG with Graphviz
dot -Tpng ./cfg_output/myfile_functionName.dot -o cfg.png

# Or use online viewers: https://edotor.net or https://viz-js.com
```

DOT output features:
- Entry nodes (`fn_entry`) in green, exit nodes (`fn_exit`) in red
- Branch/loop headers shown as diamonds
- Edge colors indicate control flow type:
  - Green: `branch_true`, `try_success`, `catch_success`
  - Red: `branch_false`, `try_error`, `catch_error`, `errdefer_edge`
  - Blue dashed: `loop_back`
  - Orange: `loop_exit`
  - Purple dashed: `defer_edge`

The `Cfg` struct also provides `dumpDot(allocator)` for quick stderr output during development.

### Debug Logging

Set log level at build time or use `-Dlog_level=debug` for verbose output showing rule execution and analysis stats.

## Testing

Tests are embedded in source files using Zig's `test` blocks. Run individual file tests:
```bash
zig test src/source.zig
```

To run a single fixture (useful when `just test` stops at the first failure):
```bash
zig build run -- test/fixtures/store_violations_engine/fixture_name.zig
```

## Code Style

- Zig standard formatting via `zig fmt`
- Tests colocated with implementation in the same file
- Rules in `src/rules/` directory, one file per rule
- **ArrayList initialization**: In Zig 0.15, use `.empty` to initialize ArrayLists (e.g., `var list: std.ArrayList(T) = .empty;`). The allocator is passed to methods like `append(allocator, item)` and `deinit(allocator)`. Do NOT use the old `.init(allocator)` pattern.

## Temporary Files

When creating temporary Zig files for testing or experimentation, use the `.tmp/` directory in this project instead of `/tmp`. Run with relative paths:
```bash
zig run .tmp/test_file.zig
```
