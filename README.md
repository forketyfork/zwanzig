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

- dupe-import
- todo
- file-as-struct
- unused-decl
- unused-parameter
- unreachable-code
- empty-defer
- empty-errdefer
- shadowed-variable
- sentinel-alloc
- identifier-style

Checkers (Checker interface):

- unreachable-code-engine
- optional-unwrap
- empty-catch-engine
- swallowed-error
- store-violations-engine

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

- Rules and checker details: [docs/RULES.md](docs/RULES.md)
- Implementation notes: [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- CFG/analysis visualization: [docs/VISUALIZATION.md](docs/VISUALIZATION.md)
- Release process: [docs/RELEASE.md](docs/RELEASE.md)
- Sample config: [docs/zwanzig.sample.json](docs/zwanzig.sample.json)

## License

MIT
