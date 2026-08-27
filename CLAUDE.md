# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Overview

Zwanzig is a static analyzer and linter for Zig. It uses a modular rule-based architecture with lazy AST parsing and caching.

## Build Commands

```bash
zig build              # Build the project
zig build test         # Run all tests
zig build run -- <files>  # Run analyzer on files
zig fmt src            # Format code with the canonical Zig 0.15.2 shell
zig fmt --check src/   # Check canonical formatting
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

All code must be formatted with `zig fmt` from Zig 0.15.2, which is the
project's sole canonical formatter. The Zig 0.16.0 shell is used to validate
the alternate embedded frontend; its formatter output is not authoritative.

Any changes or additions to the existing rules/checkers must be documented.

## Changelog

After completing a user-visible change, add a short entry to the `## [Unreleased]` section of `CHANGELOG.md` under `### Added`, `### Changed`, `### Fixed`, or `### Removed` as appropriate. Keep the entry user-focused (what changed from the user's perspective, not implementation detail) and include the related issue and/or PR number, e.g. `(#42)` or `(PR #42)`. Skip the entry for purely internal changes (refactors, test-only changes, CI tweaks) that a user would not notice.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## Releases

When asked to release: create a PR for the version bump, wait for required checks to pass, then tag and publish the release from the merged commit.

## Development Environment

Uses Nix flakes for reproducible dev environments. The default shell uses Zig 0.15.2:

```bash
nix develop
```

Use the Zig 0.16.0 shell to validate the alternate embedded frontend:

```bash
nix develop .#zig016
```

## Infrastructure

This project uses GitHub both as a code host, CI and issue tracker. Use the managing-github skill for related operations.

## Architecture

### Data Flow
1. `cli/run.zig` parses CLI args (via `cli/args.zig`), merges config, and registers defaults via `cli/registry.zig`
2. `Analyzer` reads files, creates `Source` objects, runs enabled rules and checkers
3. Rules/checkers receive `Source` and append `Diagnostic`s to a shared list
4. Analyzer reports results and exits with code 1 if diagnostics found

### Key Types
- **`Source`** (`src/source.zig`): Lazy-parsed source with cached AST. Call `ast()` or `tokens()` to parse on demand; subsequent calls return cached result. Also provides type information via `hasTypeInfo()`, `findDeclType()`, etc.
- **`Rule`** (`src/rule.zig`): Interface with `name` and `checkFn`. Rules implement `check(source, allocator, diagnostics)`.
- **`Checker`** (`src/checker.zig`): Engine-based interface with `checkAstFn`. Checkers use CFG and analysis engine for sophisticated analysis. Checkers receive a `CheckerContext` with optional `TypeContext` for type-aware analysis.
- **`Analyzer`** (`src/analyzer.zig`): Orchestrates file reading, rule/checker execution, result collection.
- **`cli/`** (`src/cli/*.zig`): CLI parsing, config merge, registry, and run loop.
- **`formatters/`** (`src/formatters/*.zig`): Output formatters for text and SARIF.
- **`Diagnostic`**: Issue report with file path, line/column, rule name, severity, and message. Diagnostics own their message strings; `Analyzer.deinit()` frees them.
- **`TypeContext`** (`src/type_context.zig`): Unified interface for type queries wrapping the ZIR bridge. Use `getDeclType()`, `classifyIdentifier()`, `isDeclFunction()`, etc.
- **`ZirBridge`** (`src/zir/bridge.zig`): Generates ZIR from source and extracts typed information (`TypeInfo`, `DeclInfo`).
- **`AbstractValue`** (`src/engine/value.zig`): Lattice value for abstract interpretation. Supports `unknown`, `null_val`, `non_null`, `int_range`, `concrete_int`, and `concrete_bool`. The engine evaluates boolean and integer literals from const declarations.
- **`Constraint`** (`src/engine/constraints.zig`): Path constraints for symbolic execution. Includes `int_compare`, `null_check`, `bool_check`, and `var_compare` for path-sensitive analysis.

### Adding a New Rule

1. Create `src/rules/my_rule.zig` implementing the `Rule` interface
2. Register in `src/cli/registry.zig`: `try analyzer.registerRule(&MyRule.rule);`

See existing rules in `src/rules/` for patterns. For CFG-based checkers, see `src/checkers/`.

### CLI Flags
- `--file <path>`: Specify a file or directory to analyze (repeatable)
- `--do <rule>`: Run only specified rules (allowlist, repeatable)
- `--skip <rule>`: Skip specified rules (blocklist, repeatable)
- `--do` and `--skip` are mutually exclusive; rule and checker names share the same namespace
- `--target <triple>`: Specify target triple (e.g., `x86_64-linux-gnu`)
- `--config <path>`: Path to config file (default: `.zwanzig.json`)
- `--format <format>`: Output format (`text`, `json`, `sarif`)
- `--max-steps <n>`: Max worklist steps per engine run
- `--max-states-per-point <n>`: Max unique states per CFG point
- `--use-widening`: Enable widening for convergence (default: on; disable via config)
- `--cache`: Enable incremental caching
- `--threads <n>`: Number of threads for parallel analysis (default: CPU count)
- `--dump-cfg <dir>`: Dump CFG DOT files for visualization
- `--dump-exploded-graph <dir>`: Dump exploded graph showing all (CFG node, state) pairs
- `--dump-annotated-cfg <dir>`: Dump CFG with state annotations overlaid
- `--dump-path-trace <dir>`: Dump path traces to violations

See [docs/VISUALIZATION.md](docs/VISUALIZATION.md) for detailed visualization documentation.

Default rule filtering: if no config file is present and no `--do`/`--skip` flags are used, `sentinel-alloc` is blocklisted.

## Debugging

### Debug Logging

Set log level at build time or use `-Dlog-level=debug` for verbose output showing rule execution and analysis stats.

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

- Zig standard formatting via Zig 0.15.2's `zig fmt` (the canonical formatter)
- Tests colocated with implementation in the same file
- Rules in `src/rules/` directory, one file per rule
- **ArrayList initialization**: In Zig 0.15.2, use `.empty` to initialize ArrayLists (e.g., `var list: std.ArrayList(T) = .empty;`). The allocator is passed to methods like `append(allocator, item)` and `deinit(allocator)`. Do NOT use the old `.init(allocator)` pattern.

## Temporary Files

When creating temporary Zig files for testing or experimentation, use the `.tmp/` directory in this project instead of `/tmp`. Run with relative paths:
```bash
zig run .tmp/test_file.zig
```
