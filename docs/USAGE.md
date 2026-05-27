# Usage

## Build

```bash
zig build
```

## Run the CLI

If `zwanzig` is on your PATH:

```bash
zwanzig
```

From the repository (without installing):

```bash
zig build run -- src/
```

Show the version:

```bash
zwanzig --version
```

### Files and directories

```bash
# Single file
zwanzig path/to/file.zig

# Multiple files
zwanzig file1.zig file2.zig file3.zig

# Directory (recursively scans for .zig files)
zwanzig src/

# Mix of files and directories
zwanzig src/ tests/ main.zig

# Using --file flag (can be repeated)
zwanzig --file src --file tests
```

### File discovery

Without arguments, zwanzig scans the current directory for `.zig` files. It skips:

- `zig-cache/`
- `zig-out/`
- `.zigmod/`
- `.gyro/`

## Using as a dependency

Add zwanzig to your project:

```bash
zig fetch --save https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.12.2.tar.gz
```

Then wire a lint step in your `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const zw = b.dependency("zwanzig", .{
    .target = target,
    .optimize = optimize,
});
const zw_exe = zw.artifact("zwanzig");

const run = b.addRunArtifact(zw_exe);
run.addArgs(&.{ "--format", "sarif", "src" });

const lint_step = b.step("lint", "Run zwanzig");
lint_step.dependOn(&run.step);
```

## Rule selection

With no config file and no `--do`/`--skip` flags, zwanzig runs all rules and checkers except `sentinel-alloc` (blocklisted by default). Config files or `--do`/`--skip` flags replace that default. Rule and checker names share the same namespace.

**Run only specific rules (allowlist):**

```bash
# Run only the empty-catch-engine checker
zwanzig --do empty-catch-engine file.zig

# Run multiple specific rules
zwanzig --do dupe-import --do unused-decl file.zig
```

**Skip specific rules (blocklist):**

```bash
# Run all rules except todo
zwanzig --skip todo file.zig

# Skip multiple rules
zwanzig --skip todo --skip unused-decl file.zig
```

`--do` and `--skip` are mutually exclusive.

The default `sentinel-alloc` blocklist only applies when you don't pass a config file or `--do`/`--skip`. To enable it, provide a config file (even one without rule filters) or define your own allowlist/blocklist.

For persistent settings, see [docs/CONFIG.md](CONFIG.md).

## Target configuration

Specify a target platform with `--target`:

```bash
# Analyze for Linux x86_64
zwanzig --target x86_64-linux-gnu src/

# Analyze for macOS ARM64
zwanzig --target aarch64-macos src/

# Analyze for WebAssembly
zwanzig --target wasm32-wasi src/

# Analyze for freestanding (embedded/kernel)
zwanzig --target aarch64-freestanding src/
```

Without `--target`, the native host configuration is used.

## Parallel analysis

Zwanzig analyzes files in parallel (one worker per CPU core by default). Control the worker count with `--threads`:

```bash
zwanzig --threads 4 src/
```

## Incremental caching

Speed up repeated runs with `--cache`:

```bash
zwanzig --cache src/
```

Cache lives in `.zwanzig-cache/`, keyed by file content hash, target platform, zwanzig version, type-info availability, and enabled rules. The cache invalidates automatically when any of these change.

The cache stores metadata (e.g., whether type info was loaded) and cached CFGs to speed up repeated runs, but it never skips analysis.

Add `.zwanzig-cache/` to `.gitignore`.

## Debug output

Enable debug logging at build time with `-Dlog-level`:

```bash
zig build run -Dlog-level=debug -- src/
```

Available log levels: `err`, `warn`, `info` (default), `debug`.

Debug output includes file discovery counts, rule counts, and analysis statistics.

## Output formats

See [docs/OUTPUT.md](OUTPUT.md) for text, JSON, and SARIF output examples.

## Inline suppressions

See [docs/SUPPRESSIONS.md](SUPPRESSIONS.md) for suppression comment formats.

## CI integration

See [docs/CI.md](CI.md) for GitHub Actions setup and SARIF upload.

## Examples

See the `examples/` directory for sample code demonstrating both violations and proper error handling patterns.

## Testing

Run the test suite:

```bash
zig build test
```
