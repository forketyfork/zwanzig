# zwanzig

[![Build status](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)

Zwanzig is a static analyzer and linter for Zig code, combining fast AST/token rules with CFG-driven analysis built on ZIR output.

## Installation and usage

### Release binary

Download the archive for your platform from the [latest release](https://github.com/forketyfork/zwanzig/releases/latest):

| Platform | Archive |
| --- | --- |
| Linux x86_64 | `zwanzig-vX.Y.Z-linux-x86_64.tar.gz` |
| macOS ARM64 | `zwanzig-vX.Y.Z-macos-aarch64.tar.gz` |
| Windows x86_64 | `zwanzig-vX.Y.Z-windows-x86_64.zip` |

Extract the archive and either add its directory to `PATH` or invoke the executable directly:

```bash
./zwanzig src/
```

On Windows, run `.\zwanzig.exe src\` instead.

### Zig build dependency

Pin Zwanzig as a dependency in your Zig project. This command adds the dependency URL and content hash to `build.zig.zon`:

```bash
zig fetch --save=zwanzig https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.14.0.tar.gz
```

Add a lint step to `build.zig`:

```zig
const zwanzig = b.dependency("zwanzig", .{
    .target = b.graph.host,
    .optimize = .ReleaseFast,
});
const run_zwanzig = b.addRunArtifact(zwanzig.artifact("zwanzig"));
run_zwanzig.addArgs(&.{"src"});

const lint_step = b.step("lint", "Run Zwanzig");
lint_step.dependOn(&run_zwanzig.step);
```

`b.graph.host` builds Zwanzig for the machine running the build, including when your project targets another platform. `ReleaseFast` avoids the substantial overhead of running the analyzer in Debug mode.

Run the new step with:

```bash
zig build lint
```

### GitHub Actions (SARIF)

Download a pinned release binary before running Zwanzig. The Linux runner is x86_64, so it uses the Linux x86_64 archive:

```yaml
name: Zwanzig

on:
  push:
  pull_request:

permissions:
  contents: read
  security-events: write

env:
  ZWANZIG_VERSION: v0.14.0

jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Install Zwanzig
        run: |
          archive="zwanzig-${ZWANZIG_VERSION}-linux-x86_64.tar.gz"
          curl --fail --location --silent --show-error \
            "https://github.com/forketyfork/zwanzig/releases/download/${ZWANZIG_VERSION}/${archive}" \
            --output "${RUNNER_TEMP}/${archive}"
          mkdir -p "${RUNNER_TEMP}/zwanzig"
          tar -xzf "${RUNNER_TEMP}/${archive}" -C "${RUNNER_TEMP}/zwanzig"
          echo "${RUNNER_TEMP}/zwanzig" >> "${GITHUB_PATH}"

      - name: Run Zwanzig analysis
        run: zwanzig --format sarif src/ > results.sarif || true

      - name: Upload SARIF results
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: results.sarif
```

Pinning the version keeps CI reproducible. Update `ZWANZIG_VERSION` when you want to adopt a newer release. The `|| true` lets the SARIF upload run when Zwanzig reports diagnostics.

## Features

- Rule/checker registration with shared `--do`/`--skip` filtering
- Lazy parsing with cached AST/tokens per file
- Type-aware analysis via ZIR
- CFG-based, path-sensitive checkers
- Graphviz DOT dumps for CFGs, exploded graphs, and path traces
- Parallel analysis across files

## Rules

AST/token rules:

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
- deinit-lifecycle: risky cleanup/reinit lifecycle patterns around `defer`/`errdefer`

Engine-backed checkers:

- unreachable-code-engine: constant-condition unreachable code
- optional-unwrap: forced optional unwraps with `.?`
- empty-catch-engine: empty `catch {}` blocks
- swallowed-error: catch blocks that ignore errors without rethrowing or logging
- store-violations-engine: allocator/resource misuse (double-free, leaks, use-after-free/close)
- stack-escape-engine: stack-backed values escaping via return or async/thread capture
- divide-by-zero-engine: path-sensitive divide/modulo-by-zero detection
- slice-bounds-engine: array/slice out-of-bounds access detection

## Limitations

- ZIR/type info requires valid, parseable Zig code
- Full type resolution needs complete build context; standalone analysis has limited type inference
- Nested-scope type info is still limited to module-level declarations
- Interprocedural analysis is limited to simple direct calls in a single file; cross-file calls are treated as external
- Incremental cache stores metadata only; CFG caching is planned but not yet wired in

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
