# zwanzig

[![Build status](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/zwanzig/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)

A static analyzer and linter for Zig code.

## Features

- Adding new rules takes one file and one line of registration code
- Lazy parsing and caching keep analysis fast
- Diagnostics include severity, precise locations, and rule IDs

## Implemented Rules

### dupe-import

Flags duplicate `@import` statements. These often signal copy-paste mistakes or forgotten refactoring.

**Bad:**
```zig
const std = @import("std");
const mem = @import("std");  // Duplicate import of "std"
```

**Good:**
```zig
const std = @import("std");
const mem = std.mem;  // Use the already imported std
```

### todo

Finds `// TODO` comments so you can track unfinished work.

**Example:**
```zig
fn processData(data: []const u8) void {
    // TODO: implement error handling
    _ = data;
}
```

This produces a hint pointing to the TODO with its message.

### file-as-struct

Enforces naming conventions based on whether a file acts as a struct (has top-level fields):

- Files with top-level fields should have a capitalized file name (e.g., `MyType.zig`)
- Files without top-level fields should have a lowercase file name (e.g., `utils.zig`)

**Bad (struct-like file with lowercase name):**
```zig
// mytype.zig - should be MyType.zig
count: usize,
name: []const u8,

pub fn init() @This() {
    return .{ .count = 0, .name = "" };
}
```

**Good (struct-like file with capitalized name):**
```zig
// MyType.zig
count: usize,
name: []const u8,

pub fn init() @This() {
    return .{ .count = 0, .name = "" };
}
```

**Bad (module file with capitalized name):**
```zig
// Utils.zig - should be utils.zig
const std = @import("std");

pub fn helper() void {
    std.debug.print("Hello\n", .{});
}
```

**Good (module file with lowercase name):**
```zig
// utils.zig
const std = @import("std");

pub fn helper() void {
    std.debug.print("Hello\n", .{});
}
```

### unused-decl

Detects unused container-level `const`, `var`, and `fn` declarations that aren't exported.

The check is conservative:
- Exported (`pub`) declarations are ignored (they may be used externally)
- Underscore-prefixed names (e.g., `_unused`) are ignored (explicit opt-out)
- Special names like `main` and `panic` are ignored (entry points)

**Bad:**
```zig
const unused_value = 42;  // Never used

fn unused_helper() void {}  // Never called

pub fn main() void {
    // ...
}
```

**Good:**
```zig
const config = 42;

fn helper() void {}

pub fn main() void {
    _ = config;
    helper();
}
```

### unreachable-code

Detects code that can never execute using control-flow graph analysis.

**Bad:**
```zig
fn foo() void {
    return;
    const x = 42;  // Unreachable - after unconditional return
}

fn bar(x: i32) void {
    if (x > 0) {
        return;
    } else {
        return;
    }
    const y = 10;  // Unreachable - both branches return
}
```

**Good:**
```zig
fn foo() void {
    const x = 42;
    return;
}

fn bar(x: i32) void {
    const y = 10;
    if (x > 0) {
        return;
    }
}
```

### empty-defer

Flags empty `defer {}` blocks that serve no purpose.

**Bad:**
```zig
fn foo() void {
    defer {}  // Empty defer - does nothing
}
```

**Good:**
```zig
fn foo() !void {
    var file = try std.fs.cwd().openFile("test.txt", .{});
    defer file.close();
}
```

### empty-errdefer

Flags empty `errdefer {}` blocks that don't clean up anything.

**Bad:**
```zig
fn foo() !void {
    errdefer {}  // Empty errdefer - does nothing
}
```

**Good:**
```zig
fn foo() !void {
    var allocator = std.heap.page_allocator;
    var buffer = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buffer);
    // ...
}
```

### shadowed-variable

Detects variable shadowing across scopes (including payloads) to avoid accidental name reuse.

**Bad:**
```zig
fn foo(x: i32) void {
    const x = 5; // Shadows parameter
    _ = x;
}
```

**Good:**
```zig
fn foo(x: i32) void {
    const value = 5;
    _ = x;
    _ = value;
}
```

### identifier-style

Enforces Zig naming conventions:

- Types: PascalCase
- Functions: camelCase
- Variables/constants/parameters/payloads: snake_case

**Bad:**
```zig
const MaxValue = 10;

fn DoThing(BadParameter: ?i32) void {
    if (BadParameter) |Value| {
        _ = Value;
    }
}
```

**Good:**
```zig
const max_value = 10;

fn doThing(good_param: ?i32) void {
    if (good_param) |value| {
        _ = value;
    }
}
```

## Engine-based Checkers

These checkers use control-flow graph analysis for deeper inspection.

### empty-catch-engine

Detects empty `catch {}` blocks that silently swallow errors.

**Bad:**
```zig
const file = std.fs.cwd().openFile("test.txt", .{}) catch {};
```

**Good:**
```zig
const file = std.fs.cwd().openFile("test.txt", .{}) catch |err| {
    std.debug.print("Failed to open file: {}\n", .{err});
    return err;
};
```

### swallowed-error

Detects catch blocks that ignore errors without rethrowing or logging. An error is "swallowed" when the handler:

- Has a non-empty body (not just `catch {}`)
- Doesn't rethrow the error
- Doesn't call any functions (potential logging)
- Simply continues execution

**Bad:**
```zig
fn bar() i32 {
    var y: i32 = 0;
    const x = foo() catch |_| {
        y = 1;  // Swallowed - just assigns, no logging or rethrow
    };
    _ = x;
    return y;
}
```

**Good:**
```zig
fn bar() !i32 {
    const x = foo() catch |err| {
        return err;  // Rethrows error
    };
    return x;
}

fn baz() i32 {
    const x = foo() catch |err| {
        std.debug.print("Error: {}\n", .{err});  // Logs error
        return 0;
    };
    return x;
}
```

## Building

```bash
zig build
```

## Usage

Run on the current directory (discovers `.zig` files recursively):

```bash
zwanzig
```

Show the version:

```bash
zwanzig --version
```

Or specify files and directories:

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

## Using as a dependency

Add zwanzig to your project:

```bash
zig fetch --save https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.2.1.tar.gz
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

### File Discovery

Without arguments, zwanzig scans the current directory for `.zig` files. These directories are skipped:

- `zig-cache/`
- `zig-out/`
- `.zigmod/`
- `.gyro/`

### Rule Selection

All rules run by default. Control which rules run with `--do` / `--skip` flags or a config file.

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

Note: `--do` and `--skip` are mutually exclusive and cannot be used together.

### Configuration File

Create `.zwanzig.json` for persistent settings. It's loaded automatically from the current directory, or specify a path with `--config`.

**Example `.zwanzig.json`:**

```json
{
  "enabled_rules": ["empty-catch-engine", "dupe-import", "todo"]
}
```

Or to disable specific rules:

```json
{
  "disabled_rules": ["todo", "unused-decl"]
}
```

**Configuration precedence:**

1. CLI flags (`--do` and `--skip`) always override config file settings
2. If no CLI flags are provided, config file settings are used
3. If no config file exists and no CLI flags are provided, all rules run

**Using a custom config file:**

```bash
zwanzig --config path/to/custom.json src/
```

**Config file format:**

- `enabled_rules`: Array of rule names to run (allowlist mode)
- `disabled_rules`: Array of rule names to skip (blocklist mode)
- These fields are mutually exclusive - only one can be present

### Inline Suppression

Suppress diagnostics directly in your code using special comments:

**Suppress all rules on the next line:**

```zig
// zwanzig-disable-next-line
const x = problematic_code();  // No diagnostics reported for this line
```

**Suppress specific rules on the next line:**

```zig
// zwanzig-disable-next-line: empty-catch, todo
try foo() catch {};  // Only empty-catch and todo suppressed
```

**Suppress rules for a region of the file:**

```zig
// zwanzig-disable: unused-decl
const unused1 = 1;  // Suppressed
const unused2 = 2;  // Suppressed
// zwanzig-enable: unused-decl
const unused3 = 3;  // Reported again
```

**Suppress all rules for a region:**

```zig
// zwanzig-disable
// Everything here is suppressed
// zwanzig-enable
```

**Suppression comment format:**

| Comment | Effect |
|---------|--------|
| `// zwanzig-disable-next-line` | Suppress all rules on the next line |
| `// zwanzig-disable-next-line: rule1, rule2` | Suppress specific rules on the next line |
| `// zwanzig-disable` | Suppress all rules until end of file or `enable` |
| `// zwanzig-disable: rule1, rule2` | Suppress specific rules until end of file or `enable` |
| `// zwanzig-enable` | Re-enable all rules |
| `// zwanzig-enable: rule1, rule2` | Re-enable specific rules |

### Target Configuration

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

### Incremental Caching

Speed up repeated runs with `--cache`:

```bash
zwanzig --cache src/
```

Cache lives in `.zwanzig-cache/`. It's keyed by file content hash and target, so it invalidates automatically when either changes.

**Tip:** Add `.zwanzig-cache/` to `.gitignore`.

### Output Formats

Use `--format` to choose the output style.

**Text (default):**

```bash
zwanzig --format text src/
# or simply
zwanzig src/
```

Output example:
```
Found 2 issue(s):
src/main.zig:10:5: error: [empty-catch] Empty catch block detected
src/utils.zig:23:1: warning: [unused-decl] Unused declaration: helper
```

**JSON:**

```bash
zwanzig --format json src/
```

Example:
```json
{
  "diagnostics": [
    {
      "file": "src/main.zig",
      "rule": "empty-catch",
      "severity": "error",
      "message": "Empty catch block detected",
      "location": {
        "start": {"line": 10, "column": 5},
        "end": {"line": 10, "column": 20}
      }
    },
    {
      "file": "src/utils.zig",
      "rule": "unused-decl",
      "severity": "warning",
      "message": "Unused declaration: helper",
      "location": {
        "start": {"line": 23, "column": 1},
        "end": {"line": 23, "column": 25}
      }
    }
  ],
  "total": 2
}
```

JSON works well with CI pipelines and editor integrations.

**SARIF:**

```bash
zwanzig --format sarif src/
```

[SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html) format, supported by GitHub code scanning, VS Code's SARIF extension, and SonarQube.

### GitHub Actions Integration

Publish zwanzig results to GitHub's code scanning to see issues directly in pull requests.

**1. Add the required permission to your workflow:**

```yaml
permissions:
  contents: read
  security-events: write  # Required for uploading SARIF
```

**2. Add steps to run zwanzig and upload results:**

```yaml
- name: Run zwanzig analysis
  run: |
    zwanzig --format sarif src/ > results.sarif || true

- name: Upload SARIF results
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

The `|| true` ensures the workflow continues even if zwanzig finds issues, so results are always uploaded.

**3. (Optional) Run on every push, even if other steps fail:**

```yaml
- name: Run zwanzig analysis
  if: always()
  run: |
    zwanzig --format sarif src/ > results.sarif || true

- name: Upload SARIF results
  if: always()
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

After setup, you'll find results in:
- **Security** tab > **Code scanning alerts**
- **Pull requests** > **Checks** > **Code scanning results**
- Inline annotations on changed files

## Testing

Run the test suite:

```bash
zig build test
```

## Examples

See the `examples/` directory for sample code demonstrating both violations and proper error handling patterns.

## Architecture

The main components:

- `source.zig` - Lazy AST/token parsing with caching
- `diagnostic.zig` - Diagnostic model with severity and locations
- `analyzer.zig` - File reading and rule/checker execution
- `rule.zig` - Rule interface for AST-based checks
- `checker.zig` - Checker interface for CFG/dataflow analysis
- `rules/` - Individual rule implementations
- `checkers/` - Engine-based checker implementations
- `cfg.zig` - Control-flow graph builder
- `engine.zig` - Symbolic execution engine
- `file_discovery.zig` - Recursive file discovery
- `main.zig` - CLI and rule registration

### Parsing Cache

Parsing is lazy and cached. Each file is parsed at most once, regardless of how many rules inspect it.

### Diagnostics

Each diagnostic includes severity (`hint`, `warning`, `err`), precise location, and the rule that found it:

```
file.zig:5:10: warning: [empty-catch-engine] Empty catch block
```

## Adding New Rules

1. Create `src/rules/my_rule.zig`
2. Implement the `Rule` interface
3. Register in `src/main.zig`

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

For detailed implementation guidance, see [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## License

MIT
