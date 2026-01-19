# Zwanzig Implementation Details

This document describes the internal architecture and implementation details of the Zwanzig static analyzer.

## Architecture Overview

Zwanzig is designed as a modular static analysis framework for Zig code. The architecture consists of several key components that work together to analyze source files and detect issues.

### Core Components

#### Source Parsing Cache

The `Source` abstraction (`src/source.zig`) provides lazy, cached access to parsed representations of Zig source code. This is a critical performance optimization that ensures parsing work is done only once per file, even when multiple rules need to access the AST or tokens.

**Key Features:**
- Lazy parsing: AST and tokens are only parsed when first requested
- Caching: Once parsed, the AST and tokens are cached for subsequent accesses
- Memory management: Proper cleanup via `deinit()` to avoid memory leaks

**API:**
- `init(allocator, file_path, content)`: Creates a new Source instance
- `ast()`: Returns the cached AST, parsing if necessary
- `tokens()`: Returns the cached token list, parsing if necessary
- `getContent()`: Returns the raw source text
- `getFilePath()`: Returns the file path
- `deinit()`: Releases cached resources

**Usage Pattern:**
```zig
var source = Source.init(allocator, file_path, content);
defer source.deinit();

// First call parses and caches
const ast1 = try source.ast();

// Second call returns cached result (no re-parsing)
const ast2 = try source.ast();

// Same for tokens
const tokens = try source.tokens();
```

#### Analyzer

The `Analyzer` (`src/analyzer.zig`) is the main engine that coordinates the analysis process:

1. Reads source files from disk
2. Creates a `Source` instance with parsed content
3. Runs all registered rules against the source
4. Collects and reports violations

The analyzer ensures that each file is parsed once and the resulting `Source` object is shared across all rules.

#### Rule Interface

The `Rule` interface (`src/rule.zig`) defines the contract that all analysis rules must implement:

```zig
pub const Rule = struct {
    name: []const u8,
    checkFn: *const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        violations: *std.ArrayList(Violation),
    ) RuleError!void,
};
```

Rules receive a `Source` pointer, allowing them to:
- Access raw source text via `getContent()`
- Parse and traverse the AST via `ast()`
- Examine tokens via `tokens()`
- Avoid redundant parsing when multiple rules access the same representations

#### Violations

Violations represent issues found by rules. Each violation includes:
- File path and location (line, column)
- Rule name that detected the issue
- Descriptive message

## Parsing Strategy

Zwanzig uses Zig's standard library parser (`std.zig.Ast.parse`) to build the AST. The parsing happens lazily:

1. When `analyzeFile()` is called, the analyzer reads the file content
2. A `Source` object is created but no parsing occurs yet
3. When a rule calls `source.ast()` or `source.tokens()`, parsing happens
4. The parsed AST is cached in the `Source` object
5. Subsequent calls to `ast()` or `tokens()` return the cached result
6. After all rules complete, `source.deinit()` releases the cached AST

This design ensures:
- No wasted parsing if no rule needs the AST
- No redundant parsing when multiple rules need the AST
- Proper memory management via RAII pattern

## Adding New Rules

To add a new rule:

1. Create a file in `src/rules/` (e.g., `my_rule.zig`)
2. Define a struct with a `rule` constant of type `Rule`
3. Implement the check function with signature:
   ```zig
   fn check(
       source: *Source,
       allocator: std.mem.Allocator,
       violations: *std.ArrayList(Violation),
   ) RuleError!void
   ```
4. Register the rule in `main.zig`

Example:
```zig
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
        // Access the AST
        const ast = try src.ast();

        // Traverse nodes and detect issues
        // ...

        // Report violations
        try violations.append(allocator, Violation{
            .file_path = src.getFilePath(),
            .line = line,
            .column = column,
            .rule_name = "my-rule",
            .message = "Issue description",
        });
    }
};
```

## Future Enhancements

The current implementation provides a foundation for more sophisticated analysis:

- **Rule Selection**: CLI flags to enable/disable specific rules
- **File Discovery**: Recursive directory traversal with ignore patterns
- **Structured Diagnostics**: Rich diagnostic model with severity levels and ranges
- **AST-Based Rules**: Migration from text-based to AST-based rule implementations
- **Control Flow Analysis**: CFG construction for inter-procedural analysis
- **Semantic Analysis**: Integration with typed IR for deeper checks
