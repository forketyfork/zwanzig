# zwanzig

A static analyzer and linter for Zig code.

## Features

- **Extensible Architecture**: Easy to add new rules and checks
- **Fast Analysis**: Efficient source code scanning
- **Clear Error Messages**: Helpful diagnostics with line and column information

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

Analyze one or more Zig files:

```bash
zig build run -- path/to/file.zig
zig build run -- file1.zig file2.zig file3.zig
```

Or use the compiled binary directly:

```bash
./zig-out/bin/zwanzig path/to/file.zig
```

## Testing

Run the test suite:

```bash
zig build test
```

## Examples

See the `examples/` directory for sample code demonstrating both violations and proper error handling patterns.

## Architecture

The analyzer is built with extensibility in mind:

- **`analyzer.zig`**: Core analysis engine that coordinates file reading and rule execution
- **`rule.zig`**: Base rule interface that all checks implement
- **`rules/`**: Directory containing individual rule implementations
- **`main.zig`**: CLI interface and rule registration

## Adding New Rules

To add a new rule:

1. Create a new file in `src/rules/` (e.g., `my_rule.zig`)
2. Implement the `Rule` interface with a `check` function
3. Register the rule in `src/main.zig`

Example:

```zig
pub const MyRule = struct {
    pub const rule: Rule = Rule{
        .name = "my-rule",
        .checkFn = check,
    };

    fn check(source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) !void {
        // Your analysis logic here
    }
};
```

## License

MIT