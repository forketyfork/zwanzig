# zwanzig

A static analyzer and linter for Zig code.

## Features

- **Extensible Architecture**: Easy to add new rules and checks
- **Fast Analysis**: Efficient source code scanning
- **Structured Diagnostics**: Rich diagnostic output with severity levels, source ranges, and rule identifiers

## Implemented Rules

### empty-catch

Detects empty `catch {}` blocks which silently ignore errors using AST-based analysis. This is often a code smell that can hide bugs. The rule uses the Zig parser's AST to accurately identify catch expressions and determine if their bodies are empty blocks.

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

### dupe-import

Detects duplicate `@import` statements in Zig code. Duplicate imports can indicate copy-paste errors or redundant code. The rule scans tokens to find `@import("...")` patterns and reports when the same module is imported multiple times.

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

Detects `// TODO` comments in Zig code. TODO comments indicate unfinished work that should be tracked. This rule helps identify and track incomplete tasks in the codebase.

**Example:**
```zig
fn processData(data: []const u8) void {
    // TODO: implement error handling
    _ = data;
}
```

This will produce a hint-level diagnostic pointing to the TODO comment with its message.

### file-as-struct

Enforces file naming conventions based on whether the file contains top-level fields (i.e., acts as a struct). In Zig, a file can act as an implicit struct by having top-level fields. This rule enforces the convention that:

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

Detects unused container-level `const`, `var`, and `fn` declarations that are not exported (`pub`). Declarations that are never referenced elsewhere in the file are reported as warnings.

The rule uses a conservative approach:
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

Detects unreachable code using control-flow graph (CFG) analysis. Code is unreachable when no feasible execution path leads to it. This uses the symbolic execution engine to detect code that can never execute.

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

Detects empty `defer {}` blocks using AST analysis. Empty defer blocks serve no purpose and clutter the code.

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

Detects empty `errdefer {}` blocks using AST analysis. Empty errdefer blocks serve no purpose and should be removed.

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

### empty-catch-engine

Engine-based checker that detects empty catch blocks using CFG and symbolic execution. This checker uses control-flow analysis to identify catch expressions where the error handler body is empty (no statements).

Unlike the AST-based `empty-catch` rule, this checker leverages the analysis engine's error state tracking for more accurate detection.

**Bad:**
```zig
fn foo() !i32 {
    return 42;
}

fn bar() void {
    const x = foo() catch {};  // Empty catch - error ignored
    _ = x;
}
```

**Good:**
```zig
fn bar() i32 {
    const x = foo() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return 0;
    };
    return x;
}
```

### swallowed-error

Engine-based checker that detects catch blocks that swallow errors without proper handling. An error is considered "swallowed" when the catch handler:

- Has a non-empty body (not just `catch {}`)
- Does NOT rethrow the error
- Does NOT log the error (no function calls)
- Simply ignores the error and continues execution

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

Analyze the current directory (recursively discovers all `.zig` files):

```bash
zig build run
zwanzig
```

Analyze specific files or directories:

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

### File Discovery

When no paths are specified, zwanzig walks the current directory and discovers all `.zig` files. The following directories are automatically ignored:

- `zig-cache/`
- `zig-out/`
- `.zigmod/`
- `.gyro/`

### Rule Selection

By default, all rules are run. You can control which rules run using the `--do` and `--skip` flags.

**Run only specific rules (allowlist):**

```bash
# Run only the empty-catch rule
zwanzig --do empty-catch file.zig

# Run multiple specific rules
zwanzig --do empty-catch --do unused-var file.zig
```

**Skip specific rules (blocklist):**

```bash
# Run all rules except empty-catch
zwanzig --skip empty-catch file.zig

# Skip multiple rules
zwanzig --skip empty-catch --skip unused-var file.zig
```

Note: `--do` and `--skip` are mutually exclusive and cannot be used together.

### Target Configuration

Specify the target platform for analysis using the `--target` flag:

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

When no target is specified, the analyzer uses the native host target configuration. Target configuration enables platform-specific analysis and rules.

## Testing

Run the test suite:

```bash
zig build test
```

## Examples

See the `examples/` directory for sample code demonstrating both violations and proper error handling patterns.

## Architecture

The analyzer is built with extensibility and performance in mind:

- **`source.zig`**: Source parsing cache that provides lazy, cached access to AST, tokens, and location mapping
- **`diagnostic.zig`**: Structured diagnostic model with severity levels and source ranges
- **`analyzer.zig`**: Core analysis engine that coordinates file reading and rule execution
- **`rule.zig`**: Base rule interface that all checks implement
- **`rules/`**: Directory containing individual rule implementations
- **`file_discovery.zig`**: Recursive file discovery with ignore filters
- **`main.zig`**: CLI interface and rule registration

### Parsing Cache

Zwanzig uses a smart caching strategy to avoid redundant parsing. When analyzing a file:

1. The analyzer creates a `Source` object that holds the file content
2. Rules access parsed representations (AST, tokens) through the `Source` interface
3. Parsing happens lazily on first access and results are cached
4. Subsequent accesses by other rules reuse the cached parse results

This ensures efficient analysis even with many rules, as each file is parsed at most once.

### Diagnostics

Zwanzig uses a structured diagnostic model for reporting issues:

- **Severity**: Each diagnostic has a severity level (`hint`, `warning`, or `err`)
- **Source Range**: Diagnostics include precise source locations with line and column information
- **Rule ID**: Each diagnostic identifies the rule that detected the issue

Output format:
```
file.zig:5:10: warning: [empty-catch] Empty catch block detected.
```

## Adding New Rules

To add a new rule:

1. Create a new file in `src/rules/` (e.g., `my_rule.zig`)
2. Implement the `Rule` interface with a `check` function
3. Register the rule in `src/main.zig`

Example:

```zig
const Source = @import("../source.zig").Source;

pub const MyRule = struct {
    pub const rule: Rule = Rule{
        .name = "my-rule",
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        violations: *std.ArrayList(Violation),
    ) RuleError!void {
        // Access parsed AST for sophisticated analysis
        const ast = try src.ast();

        // Or access raw source for simple text-based checks
        const source = src.getContent();

        // Your analysis logic here
    }
};
```

For detailed implementation guidance, see [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## License

MIT