# zwanzig

[![Build status](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)

Zwanzig is a static analyzer and linter for Zig code, combining fast AST/token rules with engine-backed checkers.

## Quick usage

### Local

```bash
zig build
zig build run -- src/
```

### GitHub Actions (SARIF)

```yaml
permissions:
  contents: read
  security-events: write

- name: Run zwanzig analysis
  run: |
    zig build run -- --format sarif src/ > results.sarif || true

- name: Upload SARIF results
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

## Current features

- Simple rule/checker registration with shared `--do`/`--skip` filtering
- Lazy parsing and cached AST/tokens per file
- Type-aware analysis when ZIR information is available
- CFG-based, path-sensitive checkers for deeper issues
- Parallel analysis across files

## Supported rules

Rules (Rule interface):

- dupe-import: duplicate `@import` statements
- todo: `// TODO` comments
- file-as-struct: file naming based on struct-like top-level fields
- unused-decl: unused container-level declarations
- unused-parameter: unused function parameters
- unreachable-code: code after unconditional terminators or fully terminating branches
- empty-defer: empty `defer {}` blocks
- empty-errdefer: empty `errdefer {}` blocks
- shadowed-variable: name reuse across scopes
- sentinel-alloc: sentinel-terminated allocations losing sentinel type
- identifier-style: naming conventions for types/functions/values

Checkers (Checker interface):

- unreachable-code-engine: constant-condition unreachable code
- optional-unwrap: forced optional unwraps with `.?`
- empty-catch-engine: empty `catch {}` blocks
- swallowed-error: catch blocks that ignore errors without rethrowing or logging
- store-violations-engine: allocator/resource misuse (double-free, leaks, use-after-free/close)

## Limitations and in development

Limitations:

- ZIR/type info requires valid, parseable Zig code
- Full type resolution needs complete build context; standalone analysis has limited type inference
- Nested-scope type info is still limited to module-level declarations
- Interprocedural analysis is limited to simple direct calls in a single file; cross-file calls are treated as external
- Incremental cache stores metadata only; CFG caching is planned but not yet wired in

In development (planned improvements):

- Richer abstract domains (symbolic values, arithmetic propagation, slice length tracking)
- Cross-file analysis and module discovery
- Constraint solver upgrades for more precise pruning
- Expanded checker suite (more resource and bounds safety checks)

## Docs

- Usage and CLI: [docs/USAGE.md](docs/USAGE.md)
- Configuration: [docs/CONFIG.md](docs/CONFIG.md)
- Output formats: [docs/OUTPUT.md](docs/OUTPUT.md)
- CI integration: [docs/CI.md](docs/CI.md)
- Inline suppressions: [docs/SUPPRESSIONS.md](docs/SUPPRESSIONS.md)
- Development notes: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- Rules and checker details: [docs/RULES.md](docs/RULES.md)
- Implementation notes: [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- CFG/analysis visualization: [docs/VISUALIZATION.md](docs/VISUALIZATION.md)
- Release process: [docs/RELEASE.md](docs/RELEASE.md)
- Sample config: [docs/zwanzig.sample.json](docs/zwanzig.sample.json)

## License

MIT
