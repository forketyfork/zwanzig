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
- `locationMapper()`: Returns the cached location mapper for byte-to-line/column conversion
- `byteToLocation(byte_offset)`: Converts a byte offset to a `Location` (line, column)
- `byteRangeToSourceRange(start, end)`: Converts a byte range to a `SourceRange`
- `tokenLocation(token_index)`: Gets the location of a token by its index
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

#### Diagnostics

Diagnostics represent issues found by rules. Each diagnostic includes:
- **File path**: The source file containing the issue
- **Source range**: Start and end locations (line, column) for precise highlighting
- **Rule ID**: The identifier of the rule that detected the issue
- **Severity**: The importance level (`hint`, `warning`, or `err`)
- **Message**: A descriptive message explaining the issue

The `Diagnostic` type (`src/diagnostic.zig`) provides:
- `Severity` enum with `hint`, `warning`, and `err` levels
- `Location` struct for line/column positions (1-based)
- `SourceRange` struct for start/end location pairs
- `LocationMapper` for converting byte offsets to line/column positions

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
       diagnostics: *std.ArrayList(Diagnostic),
   ) RuleError!void
   ```
4. Register the rule in `main.zig`

Example:
```zig
const Diagnostic = @import("../rule.zig").Diagnostic;
const Severity = @import("../rule.zig").Severity;

pub const MyRule = struct {
    pub const rule: Rule = Rule{
        .name = "my-rule",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        // Access the AST
        const ast = try src.ast();

        // Traverse nodes and detect issues
        // ...

        // Report diagnostics with location
        try diagnostics.append(allocator, Diagnostic.initAtLocation(
            src.getFilePath(),
            "my-rule",
            .warning,
            "Issue description",
            line,
            column,
        ));

        // Or with a source range for better highlighting
        const range = try src.byteRangeToSourceRange(start_byte, end_byte);
        try diagnostics.append(allocator, Diagnostic.init(
            src.getFilePath(),
            "my-rule",
            .warning,
            "Issue description",
            range,
        ));
    }
};
```

## AST-Based Rule Implementation

Rules in Zwanzig use AST traversal to accurately analyze code structure. This approach provides several benefits over text-based scanning:

1. **Accuracy**: AST nodes precisely represent language constructs, avoiding false positives from string matching
2. **Context Awareness**: The AST provides structural context (e.g., distinguishing a `catch` keyword in a comment vs actual code)
3. **Token Information**: Access to token positions enables accurate source location reporting

### Example: empty-catch Rule

The `empty-catch` rule demonstrates AST-based analysis:

```zig
fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
    const tree = try src.ast();
    const tags = tree.nodes.items(.tag);

    for (tags, 0..) |tag, node_idx| {
        if (tag == .@"catch") {
            // Found a catch expression - check if body is empty
            if (hasEmptyCatchBody(tree, node_idx)) {
                // Report diagnostic with accurate source range
                const main_token = tree.nodes.items(.main_token)[node_idx];
                const catch_start = tree.tokens.items(.start)[main_token];
                const range = try src.byteRangeToSourceRange(catch_start, catch_start + 5);

                try diagnostics.append(allocator, Diagnostic.init(...));
            }
        }
    }
}
```

The rule:
1. Iterates through AST nodes looking for `.@"catch"` tags
2. For each catch node, examines the following tokens to determine if the block is empty
3. Uses token positions to compute accurate source ranges for diagnostics

### Example: dupe-import Rule

The `dupe-import` rule demonstrates token-based analysis for detecting duplicate imports:

```zig
fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
    const tree = try src.ast();
    const token_tags = tree.tokens.items(.tag);
    const token_starts = tree.tokens.items(.start);

    var seen_imports = std.StringHashMap(ImportInfo).init(allocator);
    defer seen_imports.deinit();

    var i: usize = 0;
    while (i < token_tags.len) : (i += 1) {
        if (token_tags[i] == .builtin) {
            // Check if this is @import followed by ("...")
            if (isImportPattern(token_tags, i)) {
                const import_path = getStringLiteralContent(...);
                if (seen_imports.get(import_path)) |first_import| {
                    // Report duplicate
                    try diagnostics.append(allocator, Diagnostic.init(...));
                } else {
                    try seen_imports.put(import_path, ...);
                }
            }
        }
    }
}
```

The rule:
1. Scans tokens looking for builtin identifiers (`@import`)
2. Checks for the pattern `@import("...")` by examining following tokens
3. Tracks seen import paths in a hash map
4. Reports duplicates with reference to the first occurrence

### Example: unused-decl Rule

The `unused-decl` rule demonstrates AST-based analysis for detecting unused declarations:

```zig
fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
    const tree = try src.ast();
    const root_decls = tree.rootDecls();

    // Collect non-pub declarations
    var decls = std.ArrayList(DeclInfo).init(allocator);
    for (root_decls) |decl_idx| {
        const tag = tree.nodes.items(.tag)[decl_idx];
        if (tag == .simple_var_decl or tag == .fn_decl) {
            // Extract name, check if pub, skip special names
            if (decl_info) |info| {
                if (!info.is_pub and !isSpecialName(info.name)) {
                    try decls.append(info);
                }
            }
        }
    }

    // Check usage by scanning tokens
    for (decls.items) |decl| {
        if (!isNameUsed(source_content, decl.name, token_tags, token_starts)) {
            try diagnostics.append(allocator, Diagnostic.init(...));
        }
    }
}
```

The rule:
1. Iterates root declarations to find `const`, `var`, and `fn` declarations
2. Filters out exported (`pub`) declarations and special names
3. Scans all identifier tokens to count usages of each declaration name
4. Reports declarations that appear only once (their definition)

The conservative approach avoids false positives by:
- Ignoring `pub` declarations (may be used externally)
- Ignoring underscore-prefixed names (explicit opt-out convention)
- Ignoring special names like `main` and `panic` (entry points)

## Intermediate Representation (IR)

Zwanzig uses a minimal Intermediate Representation (IR) to bridge AST nodes and control-flow analysis. The IR is designed to be lightweight while capturing the essential structure needed for dataflow analysis.

### IR Node Types

The IR (`src/ir.zig`) defines the following node types:

| Tag | Description |
|-----|-------------|
| `fn_entry` | Function entry point |
| `fn_exit` | Function exit point (normal return path) |
| `ret` | Return statement |
| `var_decl` | Variable declaration (const/var) |
| `assign` | Assignment expression |
| `call` | Function call expression |
| `block` | Block of statements |
| `expr` | Generic expression |
| `nop` | No-op placeholder for control flow merge points |

### IR Node Structure

Each `IrNode` contains:
- **tag**: The kind of IR node (`IrTag`)
- **ast_node**: Optional index of the corresponding AST node
- **source_range**: Optional source location for diagnostics

```zig
pub const IrNode = struct {
    tag: IrTag,
    ast_node: ?u32,
    source_range: ?SourceRange,
};
```

## Control Flow Graph (CFG)

The CFG (`src/cfg.zig`) represents the control flow within a single function. It is built from the AST and maps IR nodes to their control flow relationships.

### CFG Structure

A CFG consists of:
- **nodes**: A list of `CfgNode` entries, each containing an IR node
- **edges**: A list of `CfgEdge` entries connecting nodes
- **entry**: Index of the function entry node
- **exit**: Index of the function exit node

### Edge Types

| Kind | Description |
|------|-------------|
| `normal` | Sequential control flow |
| `jump` | Unconditional jump (e.g., from return to exit) |

### CFG Builder

The `CfgBuilder` constructs CFGs from Zig AST function declarations. Currently supported constructs:

- Function entry/exit
- Block statements
- Return statements
- Variable declarations
- Assignment expressions
- Function calls

**Usage:**
```zig
var builder = CfgBuilder.init(allocator);
const tree = try source.ast();
const root_decls = tree.rootDecls();

for (root_decls) |decl| {
    if (try builder.buildFromFn(&source, decl)) |*cfg| {
        defer cfg.deinit();
        // Analyze the CFG...
    }
}
```

### CFG Traversal

The CFG provides methods for traversing the graph:

```zig
// Get all successor node indices
var succs: std.ArrayList(u32) = .empty;
try cfg.getSuccessors(node_index, &succs);

// Get all predecessor node indices
var preds: std.ArrayList(u32) = .empty;
try cfg.getPredecessors(node_index, &preds);
```

### Source Location Mapping

CFG nodes maintain source range information for diagnostic reporting:

```zig
if (cfg.getNode(index)) |node| {
    if (node.ir_node.source_range) |range| {
        // range.start.line, range.start.column
        // range.end.line, range.end.column
    }
}
```

## Future Enhancements

The current implementation provides a foundation for more sophisticated analysis:

- **Branching CFG**: Support for if/else and switch control flow
- **Loop CFG**: Support for while/for loops with back-edges
- **Defer/Errdefer**: Proper modeling of cleanup paths
- **Try/Catch Edges**: Error flow representation
- **Semantic Analysis**: Integration with typed IR for deeper checks
- **Multiple Output Formats**: JSON, SARIF for CI/CD integration
- **Configuration Files**: Project-specific rule configuration
