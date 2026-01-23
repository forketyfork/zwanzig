# Implementation notes

## Goals

Zwanzig is a Zig static analyzer that aims to be:

1. Extensible without touching core code
2. Useful out of the box with at least one working rule
3. Well-tested and documented

## Architecture

### analyzer.zig

Handles file I/O, rule registration, and result collection. The analyzer reads files once, creates a `Source` object, and passes it to each registered rule.

### rule.zig

Defines two types:

```zig
pub const Rule = struct {
    name: []const u8,
    checkFn: *const fn (source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) anyerror!void,
};
```

Function pointers let rules be defined anywhere and registered at startup. No inheritance, no vtables.

### main.zig

Parses CLI args, registers rules, runs analysis, prints results. Exit code 1 if violations found.

### Rules

**dupe_import.zig** - Flags duplicate `@import` statements. Scans tokens for import patterns and tracks what's been seen.

**todo_comment.zig** - Finds `// TODO` comments. Reports them as hints so you can track unfinished work.

**file_as_struct.zig** - Enforces naming conventions. Files with top-level fields (struct-like) should be capitalized (`MyType.zig`). Files without fields (modules) should be lowercase (`utils.zig`).

## Error state tracking

For control-flow-based checks, the engine tracks error state:

- **normal** - Regular execution
- **error_active** - An error was produced but not handled
- **error_handled** - Inside a catch block

This lets checkers detect patterns like swallowed errors or unreachable code after returns.

## Caching

The `--cache` flag enables disk-based caching in `.zwanzig-cache/`. Cache keys combine file content hash and target configuration. If either changes, the cache entry is invalidated.

Current limitation: the cache stores markers only, not full analysis results. A future version could cache typed IR and function summaries.

## Output formats

- **text** (default) - One line per diagnostic, human-readable
- **json** - Structured output for CI integration
- **sarif** - SARIF 2.1.0 for GitHub code scanning and other tools

## Testing

Unit tests live alongside implementation in `test` blocks. Integration tests use the files in `examples/`.

```bash
zig build test                              # Unit tests
zig build run -- examples/bad_example.zig   # Integration test
```

## Adding rules

1. Create `src/rules/my_rule.zig`
2. Implement the `Rule` interface
3. Add `try analyzer.registerRule(&MyRule.rule);` in main.zig

No changes to analyzer.zig or rule.zig needed.

## Known limitations

- Rules scan text, not AST (may false-positive in strings/comments)
- No cross-file analysis
- Cache doesn't track file dependencies

## Future directions

- Full AST-aware rules
- Parallel file analysis
- Configuration file for enabling/disabling rules
- IDE integration (LSP)
