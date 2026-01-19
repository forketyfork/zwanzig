# zwanzig

A static analyzer and linter for Zig code.

## Features

- **Extensible Architecture**: Easy to add new rules and checks
- **Fast Analysis**: Efficient source code scanning
- **Structured Diagnostics**: Rich diagnostic output with severity levels, source ranges, and rule identifiers

## Implemented Rules

### empty-catch

Detects empty `catch {}` blocks which silently ignore errors. This is often a code smell that can hide bugs.

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

- **Severity**: Each diagnostic has a severity level (`hint`, `warning`, or `error`)
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