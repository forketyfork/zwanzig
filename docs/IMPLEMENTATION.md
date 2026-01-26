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

#### Rule Interface (Legacy)

The `Rule` interface (`src/rule.zig`) defines the contract for legacy analysis rules:

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

#### Checker Interface

The `Checker` interface (`src/checker.zig`) is the new extensible API for implementing analysis passes. It provides a more flexible hook-based architecture that will support multiple analysis stages (AST, CFG, IR) as the analyzer evolves.

```zig
pub const Checker = struct {
    name: []const u8,
    default_severity: Severity = .err,
    checkAstFn: ?*const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void = null,

    pub fn checkAst(...) CheckerError!void { ... }
    pub fn hasHooks(self: *const Checker) bool { ... }
};
```

**Key Features:**
- **Hook-based design**: Checkers implement specific hooks (currently `checkAstFn`) rather than a single check function
- **Multiple analysis stages**: Future versions will add CFG and IR hooks for control-flow and dataflow analysis
- **Backward compatibility**: The `CheckerManagerWithRules` supports both new checkers and legacy rules

#### CheckerManager

The `CheckerManager` (`src/checker.zig`) owns checker registration and coordinates running checks:

```zig
pub const CheckerManager = struct {
    pub fn init(allocator: std.mem.Allocator) CheckerManager { ... }
    pub fn deinit(self: *CheckerManager) void { ... }
    pub fn registerChecker(self: *CheckerManager, checker: *const Checker) !void { ... }
    pub fn runAstChecks(self: *const CheckerManager, source: *Source, diagnostics: *std.ArrayList(Diagnostic), filter_fn: ?*const fn ([]const u8) bool) CheckerError!void { ... }
};
```

#### CheckerManagerWithRules

For backward compatibility, `CheckerManagerWithRules` supports both new-style checkers and legacy rules:

```zig
pub const CheckerManagerWithRules = struct {
    pub fn registerChecker(self: *CheckerManagerWithRules, checker: *const Checker) !void { ... }
    pub fn registerRule(self: *CheckerManagerWithRules, rule: *const Rule) !void { ... }
    pub fn runAstChecks(...) CheckerError!void { ... }
};
```

**Usage:**
```zig
var manager = CheckerManagerWithRules.init(allocator);
defer manager.deinit();

// Register a new-style checker
try manager.registerChecker(&MyChecker.checker);

// Register a legacy rule
try manager.registerRule(&MyRule.rule);

// Run all checks
try manager.runAstChecks(&source, &diagnostics, null);
```

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

**Message Ownership:**

Diagnostics always own their message strings. When creating a diagnostic via `Diagnostic.init()` or `Diagnostic.initAtLocation()`, an allocator must be provided and the message is duplicated. The `Analyzer.deinit()` method is the single point that frees all diagnostic messages, ensuring safe memory management. Rules and checkers should never manually free diagnostic messages.

**Output Formats:**

The analyzer supports multiple output formats via the `Analyzer.OutputFormat` enum:

- **Text format**: Human-readable output with one diagnostic per line
  ```
  file.zig:10:5: error: [rule-name] Message
  ```

- **JSON format**: Machine-readable structured output for tool integration
  ```json
  {
    "diagnostics": [
      {
        "file": "file.zig",
        "rule": "rule-name",
        "severity": "error",
        "message": "Message",
        "location": {
          "start": {"line": 10, "column": 5},
          "end": {"line": 10, "column": 20}
        }
      }
    ],
    "total": 1
  }
  ```

The output format is controlled by the `--format` CLI flag and defaults to text. The `Analyzer.printResults()` method takes an `OutputFormat` parameter and dispatches to the appropriate formatter.

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

## Adding New Checkers

The preferred way to implement analysis passes is using the new `Checker` interface.

### Creating a Checker

1. Create a file in `src/checkers/` (e.g., `my_checker.zig`)
2. Define a checker constant of type `Checker`
3. Implement the hook functions you need

Example:
```zig
const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;

pub const MyChecker = struct {
    pub const checker: Checker = .{
        .name = "my-checker",
        .default_severity = .warning,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        const tree = try src.ast();

        // Analyze the AST...

        // Report issues
        try diagnostics.append(allocator, Diagnostic.initAtLocation(
            src.getFilePath(),
            "my-checker",
            .warning,
            "Issue description",
            line,
            column,
        ));
    }
};
```

4. Register the checker in `main.zig`:
```zig
try analyzer.registerChecker(&MyChecker.checker);
```

### Legacy Rules (Backward Compatibility)

Existing rules using the `Rule` interface continue to work. They are run through the `CheckerManagerWithRules` adapter.

To add a legacy rule:

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

### Example: unreachable-code Rule (CFG-based)

The `unreachable-code` rule uses the analysis engine to detect unreachable code:

```zig
fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
    const tree = try src.ast();
    var builder = CfgBuilder.init(allocator);

    for (function_nodes) |fn_node| {
        // Build CFG for the function
        var cfg_opt = try builder.buildFromFn(src, fn_node);
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            // Run the analysis engine
            var engine = AnalysisEngine.init(allocator, cfg);
            defer engine.deinit();
            try engine.run();

            const graph = engine.getGraph();

            // Check each CFG node to see if it's reachable
            for (cfg.nodes.items) |cfg_node| {
                var has_incoming_feasible_edge = false;
                for (graph.nodes.items) |exploded_node| {
                    if (exploded_node.point.node_index == cfg_node_idx) {
                        has_incoming_feasible_edge = true;
                        break;
                    }
                }

                // If no exploded nodes reach this CFG node, it's unreachable
                if (!has_incoming_feasible_edge) {
                    try diagnostics.append(allocator, Diagnostic.init(...));
                }
            }
        }
    }
}
```

The rule:
1. Builds a CFG for each function in the source file
2. Runs the analysis engine to build the exploded graph
3. Checks if any exploded nodes reach each CFG node
4. Reports CFG nodes that have no incoming feasible paths as unreachable

This approach correctly handles:
- Unconditional returns (code after `return` is unreachable)
- Fully-terminating branches (code after `if/else` where both branches return)
- Path-sensitive pruning (branches pruned due to contradictory constraints)

### Example: empty-defer and empty-errdefer Rules

The `empty-defer` and `empty-errdefer` rules detect empty defer/errdefer blocks using AST analysis:

```zig
fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
    const tree = try src.ast();
    const tags = tree.nodes.items(.tag);
    const data = tree.nodes.items(.data);

    for (tags, 0..) |tag, i| {
        if (tag == .@"defer") {  // or .@"errdefer"
            const defer_body_opt = data[i].opt_node;
            if (defer_body_opt.unwrap()) |defer_body_node| {
                const body_tag = tags[defer_body_idx];

                var is_empty = false;
                switch (body_tag) {
                    .block, .block_semicolon => {
                        const extra = data[defer_body_idx].extra_range;
                        is_empty = (extra.end <= extra.start);
                    },
                    .block_two, .block_two_semicolon => {
                        const opt_nodes = data[defer_body_idx].opt_node_and_opt_node;
                        is_empty = (opt_nodes[0].unwrap() == null and opt_nodes[1].unwrap() == null);
                    },
                    else => {},
                }

                if (is_empty) {
                    try diagnostics.append(allocator, Diagnostic.init(...));
                }
            }
        }
    }
}
```

The rules:
1. Scan AST nodes for `defer` or `errdefer` tags
2. Extract the defer body from the AST node data
3. Check if the body is an empty block by examining the block structure
4. Report empty blocks as violations

These rules help detect:
- `defer {}` - empty defer blocks that do nothing
- `errdefer {}` - empty errdefer blocks that don't clean up resources

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
| `branch` | Branch condition evaluation (if/else) |
| `loop_header` | While/for loop header (condition evaluation) |
| `loop_body` | Loop body entry point |
| `defer_stmt` | Defer statement body |
| `errdefer_stmt` | Errdefer statement body |
| `try_expr` | Try expression - propagates errors to caller |
| `catch_expr` | Catch expression - handles errors locally |

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
| `branch_true` | Edge taken when branch condition is true |
| `branch_false` | Edge taken when branch condition is false |
| `loop_back` | Loop back-edge (from loop body back to condition) |
| `loop_exit` | Loop exit edge (when condition is false) |
| `defer_edge` | Defer execution edge (before return/exit) |
| `errdefer_edge` | Errdefer execution edge (on error path) |
| `try_error` | Error path from try expression (propagates to caller) |
| `try_success` | Success path from try expression (continues normally) |
| `catch_error` | Error path into catch handler |
| `catch_success` | Success path from catch (value unwrapped) |

### CFG Builder

The `CfgBuilder` constructs CFGs from Zig AST function declarations. Currently supported constructs:

- Function entry/exit
- Block statements
- Return statements
- Variable declarations
- Assignment expressions
- Function calls
- If/else branching (with merge points)
- While loops (with back-edges)
- For loops (with back-edges)
- Defer statements
- Errdefer statements
- Try expressions
- Catch expressions

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
try cfg.getSuccessors(allocator, node_index, &succs);

// Get all predecessor node indices
var preds: std.ArrayList(u32) = .empty;
try cfg.getPredecessors(allocator, node_index, &preds);
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

### Branching CFG

The CFG builder supports `if` and `if-else` constructs, creating proper branching structures:

1. **Branch Nodes**: When an `if` statement is encountered, a `branch` IR node is created to represent the condition evaluation
2. **True/False Edges**: Edges from the branch node to the then-block are marked with `branch_true`, and edges to the else-block (or merge point if no else) are marked with `branch_false`
3. **Merge Points**: A `nop` node is inserted after the if/else to serve as a merge point where control flow reconverges
4. **Terminating Branches**: If both branches terminate (e.g., with return statements), the merge point is not connected, correctly representing unreachable code after the if

**Example CFG for if-else:**
```
fn_entry
    │
    ▼
  branch ─────┐
    │         │
    │ true    │ false
    ▼         ▼
 then_body  else_body
    │         │
    ▼         ▼
   nop ◄──────┘
    │
    ▼
  fn_exit
```

### Loop CFG

The CFG builder supports `while` and `for` loops with proper back-edges for cyclic control flow:

1. **Loop Header**: A `loop_header` node is created to represent the loop condition evaluation point
2. **Loop Body**: A `loop_body` node marks the entry into the loop body
3. **Back-Edges**: After the loop body completes (without terminating), a `loop_back` edge connects back to the header
4. **Exit Edge**: A `loop_exit` edge from the header leads to the code after the loop (when the condition is false)
5. **Termination Handling**: If the loop body terminates (e.g., with return), no back-edge is created from that path

**Example CFG for while loop:**
```
fn_entry
    │
    ▼
loop_header ◄────┐
    │            │
    │ true       │ loop_back
    ▼            │
loop_body ───────┘
    │
    │ loop_exit
    ▼
   nop
    │
    ▼
  fn_exit
```

### Defer/Errdefer CFG

The CFG builder models `defer` and `errdefer` statements to represent their execution order:

1. **Defer Nodes**: A `defer_stmt` node is created for each `defer` statement, connected via `defer_edge`
2. **Errdefer Nodes**: An `errdefer_stmt` node is created for each `errdefer` statement, connected via `errdefer_edge`
3. **Body Representation**: The defer body is represented as a `block` node following the defer/errdefer node
4. **Execution Order**: Defers are recorded in program order; actual execution happens in reverse order at function exit (to be modeled in future analysis passes)

**Example CFG with defers:**
```
fn_entry
    │
    ▼
defer_stmt ──► block (defer body)
    │
    ▼
errdefer_stmt ──► block (errdefer body)
    │
    ▼
  fn_exit
```

### Try/Catch CFG (Error Flow)

The CFG builder models Zig's error handling constructs (`try` and `catch`) to represent error flow:

#### Try Expressions

A `try` expression evaluates an error union and either unwraps the success value or propagates the error to the caller:

1. **Try Node**: A `try_expr` node is created to represent the error-checking point
2. **Error Path**: A `try_error` edge connects the try node directly to `fn_exit`, representing error propagation
3. **Success Path**: A `try_success` edge connects to the next statement, representing successful unwrapping

**Example CFG for try:**
```
fn_entry
    │
    ▼
try_expr ──────┐
    │          │
    │ success  │ error
    ▼          ▼
var_decl    fn_exit
    │
    ▼
  fn_exit
```

#### Catch Expressions

A `catch` expression handles errors locally by providing a fallback value or handler block:

1. **Catch Node**: A `catch_expr` node is created to represent the error-handling point
2. **Success Path**: A `catch_success` edge connects to the merge point (value unwrapped without error)
3. **Error Path**: A `catch_error` edge connects to the handler, then the handler continues to the merge point

**Example CFG for catch with handler:**
```
fn_entry
    │
    ▼
catch_expr ─────────┐
    │               │
    │ success       │ error
    │               ▼
    │           handler_body
    │               │
    ▼               │
   nop ◄────────────┘
    │
    ▼
  fn_exit
```

#### Try in Variable Declarations

When `try` appears in a variable declaration's initializer (e.g., `const x = try foo();`), the CFG correctly models both paths:

```
fn_entry
    │
    ▼
try_expr ──────┐
    │          │
    │ success  │ error
    ▼          ▼
var_decl    fn_exit
    │
    ▼
  ...
```

#### Catch in Variable Declarations

Similarly, `catch` in a variable declaration creates branching for error handling:

```
fn_entry
    │
    ▼
catch_expr ─────────┐
    │               │
    │ success       │ error
    │               ▼
    │            handler
    │               │
    ▼               │
var_decl ◄──────────┘
    │
    ▼
  ...
```

## Typed IR Bridge (ZIR Integration)

The `ZirBridge` module (`src/zir_bridge.zig`) provides a bridge between Zwanzig's analysis pipeline and Zig's typed intermediate representation (ZIR). This enables access to type information that is not available in the raw AST.

### Overview

ZIR (Zig Intermediate Representation) is the typed IR produced by the Zig compiler during semantic analysis. The ZirBridge uses `std.zig.AstGen` to generate ZIR from parsed source code, providing typed information for:

- Declaration types (variables, constants, functions)
- Function signatures and parameter types
- Type inference results

### Key Types

#### TypeInfo

Represents type information for a declaration or expression:

```zig
pub const TypeInfo = struct {
    kind: TypeKind,      // Type category (int, pointer, function, etc.)
    size_bits: u16,      // Bit width for numeric types
    is_signed: bool,     // Signedness for integers
    is_comptime: bool,   // Whether compile-time known
};

pub const TypeKind = enum {
    unknown, void_type, bool_type, int, uint, float,
    pointer, slice, array, optional, error_union,
    function, @"struct", @"enum", @"union", type_type,
};
```

#### DeclInfo

Information about a declaration extracted from ZIR:

```zig
pub const DeclInfo = struct {
    name: []const u8,        // Declaration name
    type_info: TypeInfo,     // Type information
    is_pub: bool,            // Whether exported
    is_const: bool,          // Whether constant
    is_fn: bool,             // Whether function
    ast_node: ?u32,          // AST node index
    zir_inst: ?u32,          // ZIR instruction index
};
```

### ZirBridge Usage

```zig
const ZirBridge = @import("zir_bridge.zig").ZirBridge;

var bridge = ZirBridge.init(allocator);
defer bridge.deinit();

// Load typed IR from a source file
try bridge.loadFromSource(&source);

// Query typed information
if (bridge.hasZir()) {
    std.debug.print("Instructions: {d}\n", .{bridge.getInstructionCount()});

    // Find a declaration by name
    if (bridge.findDeclByName("my_function")) |decl| {
        if (decl.is_fn) {
            std.debug.print("Found function: {s}\n", .{decl.name});
        }
    }

    // Iterate all declarations
    for (0..bridge.getDeclCount()) |i| {
        if (bridge.getDecl(i)) |decl| {
            std.debug.print("{s}: {}\n", .{decl.name, decl.type_info});
        }
    }
}
```

### How It Works

1. **AST Parsing**: Source code is parsed into a `std.zig.Ast` via the existing `Source` abstraction
2. **ZIR Generation**: `std.zig.AstGen.generate()` converts the AST to ZIR
3. **Declaration Extraction**: Root declarations are extracted from both AST and ZIR
4. **Type Mapping**: ZIR instruction types are mapped to the simplified `TypeInfo` representation

### AST to ZIR Mapping

The `findZirInstForNode` function provides a best-effort mapping from AST node indices to ZIR instruction indices. It iterates through ZIR instructions and checks their source node references:

- **pl_node format**: Most expression and declaration operations store their source node in `data.pl_node.src_node`
- **node format**: Parameters and declaration references store the node directly in `data.node`
- **un_node format**: Unary operations store their source node in `data.un_node.src_node`

This mapping enables correlating high-level AST constructs with their corresponding ZIR instructions, which is useful for type-aware analysis and debugging.

### Limitations

- ZIR generation requires valid, parseable Zig code (no syntax errors)
- Full type resolution requires the complete compilation context; standalone analysis provides limited type inference
- Currently supports module-level declarations; nested scopes require future work
- AST-to-ZIR mapping is best-effort; some AST nodes may not have corresponding ZIR instructions or may map to multiple instructions

### Integration with Analysis

The ZirBridge provides typed information that is integrated throughout the analysis pipeline:

- **Type-aware rules**: Rules that need to distinguish between integer types, pointers, error unions, etc.
- **CFG-based analysis**: Control flow analysis can use type information to understand error propagation
- **IR nodes**: `IrNode` instances can carry `TypeInfo` for type-aware dataflow analysis

### TypeContext

The `TypeContext` (`src/type_context.zig`) provides a unified interface for type queries, wrapping ZirBridge with caching and convenience methods:

```zig
const TypeContext = @import("type_context.zig").TypeContext;

var ctx = TypeContext.init(allocator, &source);
defer ctx.deinit();

// Query declaration types
if (ctx.getDeclType("my_var")) |ti| {
    if (ti.kind == .error_union) {
        // Handle error union type
    }
}

// Classify identifiers (useful for naming rules)
switch (ctx.classifyIdentifier("MyType")) {
    .type_decl => {},   // struct, enum, union
    .function => {},    // function
    .constant => {},    // const declaration
    .variable => {},    // var declaration
    .unknown => {},     // not found or ZIR unavailable
}

// Type kind queries
if (ctx.isDeclErrorUnion("result")) { /* ... */ }
if (ctx.isDeclOptional("maybe_val")) { /* ... */ }
if (ctx.isDeclPointer("ptr")) { /* ... */ }
```

### Source Type API

The `Source` struct (`src/source.zig`) provides direct access to type information via lazy-loaded ZirBridge:

```zig
var source = Source.init(allocator, "test.zig", code);
defer source.deinit();

// Check if type info is available
if (source.hasTypeInfo()) {
    // Query by declaration name
    if (source.findDeclType("x")) |ti| {
        // Use type information
    }

    // Check declaration properties
    if (source.isDeclFunction("foo")) { /* ... */ }
    if (source.isDeclType("MyStruct")) { /* ... */ }
    if (source.isDeclPublic("exported")) { /* ... */ }
}
```

### CheckerContext Type Access

The `CheckerContext` (`src/checker.zig`) passed to checkers includes an optional `TypeContext`:

```zig
pub fn checkAst(
    source: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    context: CheckerContext,
) CheckerError!void {
    // Check if type info is available
    if (context.hasTypeInfo()) {
        // Use type context for type-aware analysis
        if (context.getDeclType("my_var")) |ti| {
            // Make decisions based on type
        }

        // Classify identifiers for naming rules
        const kind = context.classifyIdentifier("MyType");
    }
}
```

### Typed IR Nodes

`IrNode` (`src/ir.zig`) now carries optional type information:

```zig
pub const IrNode = struct {
    tag: IrTag,
    ast_node: ?u32,
    source_range: ?SourceRange,
    operand_node: ?u32,
    operand2_node: ?u32,
    type_info: ?TypeInfo,  // NEW: Type info from ZIR

    // Type query helpers
    pub fn hasType(self: *const IrNode) bool;
    pub fn getTypeKind(self: *const IrNode) ?TypeInfo.TypeKind;
    pub fn isErrorUnion(self: *const IrNode) bool;
    pub fn isOptional(self: *const IrNode) bool;
    pub fn isPointer(self: *const IrNode) bool;
    pub fn isInteger(self: *const IrNode) bool;
};
```

### CfgBuilder Type Annotation

The `CfgBuilder` (`src/cfg/builder.zig`) can annotate IR nodes with types during CFG construction:

```zig
// Create builder with type context for type-annotated CFG
var type_ctx = TypeContext.init(allocator, &source);
defer type_ctx.deinit();

var builder = CfgBuilder.initWithTypes(allocator, &type_ctx);
const cfg = try builder.buildFromFn(&source, fn_node);

// IR nodes in the CFG now have type information
for (cfg.nodes.items) |node| {
    if (node.ir_node.isErrorUnion()) {
        // Handle error union
    }
}
```

Key annotations:
- **var_decl nodes**: Annotated with the variable's declared type
- **try_expr nodes**: Annotated with `error_union` type
- **catch_expr nodes**: Annotated with `error_union` type

## Analysis Engine

The analysis engine (`src/engine.zig`) implements a worklist-based traversal of the CFG to build an exploded graph. This is the foundation for path-sensitive static analysis.

### Key Concepts

#### ProgramPoint

A `ProgramPoint` identifies a specific location in the analysis:

```zig
pub const ProgramPoint = struct {
    node_index: u32,  // CFG node index
    kind: Kind,       // pre or post

    pub const Kind = enum {
        pre,   // Before node execution
        post,  // After node execution
    };
};
```

For each CFG node, there are two program points:
- **Pre-state**: Before the node executes
- **Post-state**: After the node has executed

This separation allows the engine to model state changes at each CFG node.

#### ProgramState

A `ProgramState` represents the abstract program state at a given point. It stores the environment mapping variables to abstract values:

```zig
pub const ProgramState = struct {
    env: Environment,       // Mapping from variables to abstract values
    cached_hash: ?u64,      // Cached hash for efficient deduplication
};
```

**Key Operations:**
- `init(allocator)`: Creates an empty state
- `clone(allocator)`: Creates a deep copy of the state
- `getVar(var_id)`: Retrieves the abstract value of a variable
- `setVar(var_id, value)`: Sets a variable's abstract value
- `eql(other)`: Compares states for structural equality
- `computeHash()`: Returns a hash for deduplication

Future steps will add:
- **Store**: Heap/memory model
- **Constraints**: Path conditions from branches

#### Abstract Values

Abstract values represent possible runtime values of variables and expressions:

```zig
pub const AbstractValue = union(enum) {
    unknown,              // No information available
    null_val,             // Definitely null
    non_null,             // Definitely not null (actual value unknown)
    int_range: IntRange,  // Integer within a known range
    concrete_int: i64,    // Known concrete integer
};
```

**Value Categories:**
| Value | Description | Use Case |
|-------|-------------|----------|
| `unknown` | No information | Default for uninitialized variables |
| `null_val` | Definitely null | Null pointer analysis |
| `non_null` | Definitely not null | Non-null assertions |
| `int_range` | Integer in [min, max] | Range analysis |
| `concrete_int` | Known integer | Constant propagation |

**IntRange Operations:**
- `init(min, max)`: Creates a range
- `single(value)`: Creates a single-value range
- `contains(value)`: Checks if value is in range
- `overlaps(other)`: Checks if ranges overlap
- `merge(other)`: Combines two ranges (union)

**AbstractValue Operations:**
- `eql(other)`: Checks structural equality
- `hash()`: Computes hash for deduplication
- `merge(other)`: Computes join of two values
- `isUnknown()`, `isNull()`, `isNonNull()`, `isConcrete()`: Type predicates
- `toConcreteInt()`: Extracts concrete value if available

#### Environment

The `Environment` maps variable identifiers to abstract values:

```zig
pub const Environment = struct {
    bindings: std.AutoHashMap(u32, AbstractValue),
    allocator: std.mem.Allocator,
};
```

Variables are identified by their AST node index, providing a simple and unique identifier within a module.

**Operations:**
- `get(var_id)`: Returns the abstract value, or null if not bound
- `set(var_id, value)`: Binds a variable to a value
- `remove(var_id)`: Removes a binding
- `clone()`: Creates a deep copy
- `eql(other)`: Checks structural equality
- `computeHash()`: Computes hash for deduplication

#### ExplodedNode

An `ExplodedNode` combines a program point and state:

```zig
pub const ExplodedNode = struct {
    point: ProgramPoint,
    state: ProgramState,
    index: u32,
    predecessors: std.ArrayList(u32),
    successors: std.ArrayList(u32),
};
```

Each exploded node represents a unique (point, state) pair encountered during analysis.

#### ExplodedGraph

The `ExplodedGraph` is the central data structure for path-sensitive analysis:

```zig
pub const ExplodedGraph = struct {
    nodes: std.ArrayList(ExplodedNode),
    node_map: std.AutoHashMap(u64, u32),  // For deduplication
    cfg: *const Cfg,
};
```

Key features:
- **Deduplication**: Nodes with identical (point, state) pairs are merged
- **Edge tracking**: Predecessor and successor relationships are maintained
- **CFG mapping**: Each exploded node maps back to a CFG node

### Worklist Algorithm

The `AnalysisEngine` uses a worklist-based algorithm:

1. **Initialize**: Create entry node at `(pre(entry), initial_state)`
2. **Process**: While worklist is not empty:
   - Pop a node from the worklist
   - If at pre-state: apply transfer function, create post-state node
   - If at post-state: create pre-state nodes for all CFG successors
3. **Deduplicate**: Skip nodes that already exist in the graph

```zig
var engine = AnalysisEngine.init(allocator, &cfg);
defer engine.deinit();

try engine.run();

const graph = engine.getGraph();
// Analyze the exploded graph...
```

### Deduplication

Deduplication is critical for termination when analyzing loops. The engine computes a hash key from (point, state) and checks if a node with that key already exists:

```zig
const key = ExplodedNode.computeKey(point, state);
if (self.node_map.get(key)) |existing_index| {
    return .{ .index = existing_index, .is_new = false };
}
```

This ensures that:
- Loops don't cause infinite exploration
- Paths that converge to the same state are merged
- Analysis terminates in finite time

### Transfer Function

The transfer function models how state changes when a CFG node executes. It evaluates the semantics of each IR node and updates the environment accordingly:

```zig
fn transferFunction(self: *AnalysisEngine, point: ProgramPoint, state: *const ProgramState) !ProgramState {
    const cfg_node = self.graph.cfg.getNode(point.node_index) orelse return try state.clone(self.allocator);
    var new_state = try state.clone(self.allocator);

    switch (cfg_node.ir_node.tag) {
        .var_decl => {
            // Variable declarations start with unknown value
            if (cfg_node.ir_node.ast_node) |ast_node| {
                try new_state.setVar(ast_node, .unknown);
            }
        },
        .assign => {
            // Assignments update the variable's value
            if (cfg_node.ir_node.ast_node) |ast_node| {
                try new_state.setVar(ast_node, .unknown);
            }
        },
        else => {},
    }

    return new_state;
}
```

The transfer function currently handles:
- **Variable declarations**: Initializes variables with `unknown` value
- **Assignments**: Updates variable values in the environment

### Branch Constraints and Path Pruning

The analysis engine supports path-sensitive analysis by tracking constraints from branch conditions. When the engine encounters a branch node with `branch_true` or `branch_false` edges, it extracts constraints and applies them to the successor states.

#### Constraints

Constraints represent conditions that must hold on a given execution path:

```zig
pub const Constraint = union(enum) {
    /// Variable compared to an integer value: var <op> value
    int_compare: struct {
        var_id: u32,
        op: CompareOp,
        value: i64,
    },
    /// Variable compared to null: var == null or var != null
    null_check: struct {
        var_id: u32,
        is_null: bool,
    },
    /// Variable compared to another variable: var1 <op> var2
    var_compare: struct {
        var1_id: u32,
        op: CompareOp,
        var2_id: u32,
    },
};
```

**Comparison Operators:**
| Op | Description |
|----|-------------|
| `eq` | Equal (==) |
| `ne` | Not equal (!=) |
| `lt` | Less than (<) |
| `le` | Less or equal (<=) |
| `gt` | Greater than (>) |
| `ge` | Greater or equal (>=) |

#### ConstraintManager

The `ConstraintManager` tracks active constraints on a path:

```zig
pub const ConstraintManager = struct {
    constraints: std.ArrayList(Constraint),
    allocator: std.mem.Allocator,
};
```

**Key Operations:**
- `addConstraint(constraint)`: Adds a constraint (ignores duplicates)
- `isSatisfiable(env)`: Checks if constraints are satisfiable given the environment
- `refineValue(value, constraint)`: Refines an abstract value based on a constraint
- `clone()`: Creates a deep copy

#### ProgramState with Constraints

The `ProgramState` now includes a `ConstraintManager`:

```zig
pub const ProgramState = struct {
    env: Environment,
    constraints: ConstraintManager,
    cached_hash: ?u64,
};
```

**Constraint Integration:**
- `addConstraint(constraint)`: Adds a constraint and refines variable values
- `isSatisfiable()`: Checks if the state's constraints are satisfiable
- `constraintCount()`: Returns the number of active constraints

#### Path Pruning

When processing branch edges, the engine:

1. Extracts the constraint from the branch condition (if available)
2. For `branch_true` edges: applies the constraint as-is
3. For `branch_false` edges: applies the negated constraint
4. Checks if the resulting state is satisfiable
5. If unsatisfiable, prunes the path (skips exploration)

**Example:**
```
// Code:
if (x == 5) {
    // then-branch: constraint x == 5
} else {
    // else-branch: constraint x != 5
}

// If x is known to be 10:
// - then-branch is pruned (x == 5 contradicts x == 10)
// - else-branch is explored (x != 5 is satisfiable)
```

#### Value Refinement

When a constraint is added, the engine refines the affected variable's abstract value:

| Value Type | Constraint | Result |
|------------|------------|--------|
| `unknown` | `x == 5` | `concrete_int(5)` |
| `unknown` | `x < 10` | `int_range(MIN, 9)` |
| `unknown` | `x is null` | `null_val` |
| `unknown` | `x is non-null` | `non_null` |
| `int_range(0,10)` | `x < 5` | `int_range(0,4)` |
| `concrete_int(5)` | `x == 5` | `concrete_int(5)` |
| `concrete_int(5)` | `x == 10` | `null` (contradiction) |
| `null_val` | `x is non-null` | `null` (contradiction) |

When a refinement returns `null`, the path is unsatisfiable and is pruned.

#### Satisfiability Checking

The `ConstraintManager.isSatisfiable` method performs two checks:

1. **Environment compatibility**: Each constraint is checked against known variable values
2. **Constraint consistency**: Pairs of constraints are checked for contradictions

**Contradictory constraint pairs:**
- `x == 5` AND `x == 6` (different equality values)
- `x == 5` AND `x != 5` (equality vs inequality)
- `x == null` AND `x != null` (null check contradiction)
- `x < 5` AND `x > 10` (non-overlapping ranges)

### Usage Example

```zig
const cfg_mod = @import("cfg.zig");
const engine_mod = @import("engine.zig");

// Build CFG from source
var builder = cfg_mod.CfgBuilder.init(allocator);
const cfg = (try builder.buildFromFn(&source, fn_node)) orelse return;
defer cfg.deinit();

// Run analysis
var engine = engine_mod.AnalysisEngine.init(allocator, &cfg);
defer engine.deinit();

try engine.run();

// Examine results
const graph = engine.getGraph();
std.debug.print("Exploded graph has {d} nodes\n", .{graph.nodeCount()});
```

## Error-Handling Checkers

The analysis engine supports error-handling checkers that use CFG and error state tracking to detect issues with error handling in Zig code.

### EmptyCatchEngineChecker

The `EmptyCatchEngineChecker` (`src/checkers/empty_catch_engine.zig`) detects empty catch blocks using CFG analysis:

```zig
fn checkAst(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) CheckerError!void {
    const tree = src.ast() catch return;

    // Find all function declarations
    for (function_nodes) |fn_node| {
        var builder = CfgBuilder.init(allocator);
        var cfg_opt = builder.buildFromFn(src, fn_node) catch return;
        if (cfg_opt) |*cfg| {
            defer cfg.deinit();

            var engine = AnalysisEngine.init(allocator, cfg);
            defer engine.deinit();
            engine.run() catch return;

            // Examine CFG nodes for catch_expr with empty handlers
            for (cfg.nodes.items) |cfg_node| {
                if (cfg_node.ir_node.tag == .catch_expr) {
                    if (hasEmptyHandler(cfg, cfg_node.index)) {
                        // Report diagnostic...
                    }
                }
            }
        }
    }
}
```

The checker identifies empty handlers by checking if the `catch_error` edge goes directly to a merge node (nop) without any intervening handler nodes.

### SwallowedErrorChecker

The `SwallowedErrorChecker` (`src/checkers/swallowed_error.zig`) detects catch blocks that swallow errors without proper handling:

**Detection Strategy:**

1. Build CFG for each function
2. Run the analysis engine to track error states
3. For each `catch_expr` node:
   - Find the `catch_error` edge leading to the handler
   - Trace through the handler body
   - Check if it:
     - Returns (good - might rethrow)
     - Contains a function call (good - might log)
     - Just falls through to merge (swallowed error)

**Error State Integration:**

The checker uses the analysis engine's `ErrorState` tracking:
- `error_active`: Error produced but not yet handled
- `error_handled`: Error caught and being handled in catch block
- `normal`: No error or error has been fully processed

When the error handler exits normally without logging or rethrowing, the error is considered swallowed.

```zig
fn isErrorSwallowed(cfg: *const Cfg, catch_node_idx: u32, engine: *const AnalysisEngine, allocator: std.mem.Allocator) CheckerError!bool {
    // Find handler entry via catch_error edge
    // Trace through handler checking for:
    // - Returns (has_return)
    // - Function calls (has_call - potential logging)
    // - Normal exit to merge point (swallowed)

    if (!has_return and !has_call and reaches_merge_from_error) {
        return true;  // Error is swallowed
    }
    return false;
}
```

### Registration

Both checkers are registered in `main.zig`:

```zig
try analyzer.registerChecker(&EmptyCatchEngineChecker.checker);
try analyzer.registerChecker(&SwallowedErrorChecker.checker);
```

## Interprocedural Analysis

The analysis engine supports limited interprocedural analysis through function inlining. This allows tracking data and control flow across function boundaries.

### Function Inlining

When the engine encounters a function call, it attempts to inline the callee's CFG if:

1. **Source is available**: The engine was initialized with `initWithSource()` providing access to the source file
2. **Call is resolvable**: The callee can be identified (simple identifier calls to local functions)
3. **Depth limit not exceeded**: The current inline depth is below `max_inline_depth` (default: 3)

If any condition fails, the call is treated as having **unknown effects**.

### Call Stack Tracking

The `ProgramState` maintains a call stack to track the interprocedural context:

```zig
pub const CallSite = struct {
    call_node: u32,      // CFG node of the call instruction
    caller_cfg: *const Cfg,  // CFG containing the call
    return_node: u32,    // Node to continue from after return
};
```

When a function is inlined:
1. The inline depth is incremented
2. The call site is pushed onto the call stack
3. Analysis continues at the callee's entry point

When the callee's exit is reached:
1. The call site is popped from the stack
2. The inline depth is decremented
3. Analysis continues at the caller's return point

### Configuration

The inline depth can be configured via `setMaxInlineDepth()`:

```zig
var engine = AnalysisEngine.initWithSource(allocator, &cfg, &source);
defer engine.deinit();

engine.setMaxInlineDepth(5);  // Increase inline depth to 5
try engine.run();

std.debug.print("Inlined {d} calls\n", .{engine.getInlinedCallCount()});
```

### External Calls

Calls that cannot be inlined are treated as **external calls** with unknown effects:

- **Unresolvable calls**: Method calls, indirect calls, calls to functions not in the current source
- **Depth-limited calls**: Calls that would exceed the inline depth limit
- **Built-in calls**: Calls to `@import`, `@compileError`, etc.

For external calls, the engine conservatively assumes:
- The call may modify any mutable state
- The return value is `unknown`
- Error behavior is unknown (for error-returning functions)

### Example

```zig
// Source code being analyzed
fn helper(x: i32) i32 {
    return x + 1;
}

fn main() void {
    const a = 5;
    const b = helper(a);  // This call will be inlined
    _ = b;
}

// Analysis with inlining
var engine = AnalysisEngine.initWithSource(allocator, &main_cfg, &source);
try engine.run();

// The analysis will trace through both main() and helper()
// tracking that helper() is called with x = 5 (if constant propagation is enabled)
```

### Limitations

Current inlining limitations:

- **Simple calls only**: Only direct function calls with identifier callees are supported
- **No recursion handling**: Recursive calls are limited by inline depth
- **Single-file only**: Cross-file calls are treated as external

## Function Summaries

The analysis engine supports function summaries to avoid re-analyzing the same function body at each call site. Summaries capture the essential effects of a function call, enabling efficient interprocedural analysis.

### Summary Contents

A `FunctionSummary` stores:

- **Preconditions**: Constraints on parameter values that affect behavior
- **Postconditions**: Constraints on the return value
- **Error behavior**: Whether the function may return an error, always returns an error, or may not return
- **Return value**: Abstract value representing the return (e.g., `unknown`, `concrete_int`, etc.)
- **Side effects**: Whether the function may modify global state

```zig
pub const FunctionSummary = struct {
    fn_ast_node: u32,              // AST node of the function
    preconditions: ArrayList(Constraint),   // Input constraints
    postconditions: ArrayList(Constraint),  // Output constraints
    may_return_error: bool,        // Can return an error
    always_returns_error: bool,    // Always returns an error
    may_not_return: bool,          // May not return (e.g., @panic)
    return_value: AbstractValue,   // Abstract return value
    has_side_effects: bool,        // May modify global state
    use_count: u32,                // Number of times applied
};
```

### Summary Cache

The `SummaryCache` stores computed summaries keyed by function AST node index:

```zig
var cache = SummaryCache.init(allocator);
defer cache.deinit();

// Check if a summary exists
if (cache.get(fn_node)) |summary| {
    // Use the cached summary
} else {
    // Compute a new summary
}

// Cache statistics
const stats = cache.getStats();
std.debug.print("Hits: {d}, Misses: {d}, Count: {d}\n",
    .{stats.hits, stats.misses, stats.count});
```

### Summary Application

When processing a function call, the engine:

1. **Checks the cache** for an existing summary
2. **Computes a summary** if not cached (analyzes the function's CFG)
3. **Checks applicability** against the current state's preconditions
4. **Applies the summary** by updating the state with postconditions
5. **Falls back to inlining** if no applicable summary is found

```zig
// The engine automatically uses summaries when available
var engine = AnalysisEngine.initWithSource(allocator, &cfg, &source);

// Summaries are enabled by default
engine.setUseSummaries(true);

try engine.run();

// Check summary statistics
std.debug.print("Summary uses: {d}\n", .{engine.getSummaryUseCount()});
const cache_stats = engine.getSummaryCache().getStats();
std.debug.print("Cache hits: {d}, misses: {d}\n",
    .{cache_stats.hits, cache_stats.misses});
```

### Summary Generation

Summaries are automatically generated by analyzing the function's CFG. The current implementation:

1. **Scans CFG nodes** to detect error-returning constructs (`try_expr`)
2. **Checks CFG edges** for error paths (`try_error` edges)
3. **Identifies pure functions** (no calls, only computation)
4. **Sets conservative defaults** for unknown behavior

Future enhancements will add:
- Parameter-dependent postconditions
- More precise return value tracking
- Interprocedural side-effect analysis

### Configuration

```zig
var engine = AnalysisEngine.initWithSource(allocator, &cfg, &source);

// Disable summaries (always inline)
engine.setUseSummaries(false);

// Set inline depth limit
engine.setMaxInlineDepth(5);
```

## Build Metadata Integration

The analyzer integrates build metadata and target configuration into the analysis pipeline, allowing rules and checkers to access platform-specific information.

### Build Metadata Types

The `build_metadata.zig` module provides types for representing build configuration:

```zig
pub const TargetArch = enum {
    x86_64,
    aarch64,
    arm,
    riscv64,
    wasm32,
    other,
};

pub const TargetOS = enum {
    linux,
    windows,
    macos,
    freestanding,
    wasi,
    other,
};

pub const TargetConfig = struct {
    arch: TargetArch,
    os: TargetOS,
    abi: ?[]const u8,
};

pub const BuildMetadata = struct {
    target: TargetConfig,
    optimize_mode: ?OptimizeMode,
    root_source_file: ?[]const u8,
};
```

### CLI Integration

The `--target` flag allows specifying a target triple:

```bash
zwanzig --target x86_64-linux-gnu src/
zwanzig --target aarch64-macos src/
```

The target triple is parsed and converted to a `BuildMetadata` struct that is propagated through the analyzer.

### Analysis Engine Integration

Build metadata is stored in both the `Analyzer` and `AnalysisEngine`, and is propagated to `ProgramState`:

```zig
// In Analyzer
var analyzer = Analyzer.init(allocator);
if (build_metadata) |metadata| {
    analyzer.setBuildMetadata(metadata);
}

// In AnalysisEngine
var engine = AnalysisEngine.init(allocator, &cfg);
if (analyzer.getBuildMetadata()) |metadata| {
    engine.setBuildMetadata(metadata);
}

// In ProgramState (as a shared pointer)
pub const ProgramState = struct {
    env: Environment,
    constraints: ConstraintManager,
    error_state: ErrorState,
    build_metadata: ?*const BuildMetadata,  // Shared, not owned
    // ...
};
```

### Accessing Build Metadata

Rules and checkers can access build metadata from the `ProgramState`:

```zig
pub fn check(state: *const ProgramState) void {
    if (state.build_metadata) |metadata| {
        if (metadata.target.arch == .wasm32) {
            // Apply WASM-specific checks
        }
        if (metadata.target.os == .freestanding) {
            // Apply freestanding-specific checks
        }
    }
}
```

### Use Cases

Build metadata enables target-specific analysis:

1. **Platform-specific APIs**: Detect use of platform-specific APIs on incompatible targets
2. **Size optimization**: Different rules for `.release_small` builds
3. **Freestanding checks**: Enforce restrictions for embedded/kernel code
4. **ABI compatibility**: Detect ABI-incompatible patterns

### Native Target Detection

When no `--target` is specified, the analyzer uses native target information from `@import("builtin").target`:

```zig
pub fn fromNative() BuildMetadata {
    const native = @import("builtin").target;
    // Extract arch, os from native target
    return BuildMetadata{
        .target = TargetConfig.init(arch, os, null),
        .optimize_mode = null,
        .root_source_file = null,
    };
}
```

## Incremental Cache

The analyzer supports incremental caching of intermediate artifacts to speed up repeated analysis runs. The cache stores precomputed CFGs and other analysis data, avoiding redundant computation.

### Cache Architecture

The cache system consists of two main components:

1. **Cache** (`src/cache.zig`): Low-level persistent storage
2. **CachedArtifacts** (`src/cached_artifacts.zig`): Serialization of intermediate artifacts

### Cache Key Components

Cache keys (`CacheKey`) are computed from multiple sources to ensure proper invalidation:

```zig
pub const CacheKey = struct {
    file_hash: [32]u8,      // SHA-256 of file content
    target_hash: [32]u8,    // Hash of target architecture/OS/ABI
    version_hash: [32]u8,   // Hash of Zwanzig tool version
    config_hash: [32]u8,    // Hash of enabled rules/checkers
};
```

**Invalidation triggers:**
- File content changes → `file_hash` changes
- Target platform changes (`--target` flag) → `target_hash` changes
- Zwanzig version update → `version_hash` changes
- Rule configuration changes (`--do`/`--skip` flags) → `config_hash` changes

### Cache Behavior

**Key principle:** The cache never skips analysis. It only caches intermediate artifacts like CFGs.

When analyzing a file:
1. Compute cache key from file content, target, version, and enabled rules
2. Check if cached artifacts exist for this key
3. If cache hit: load cached CFGs and other precomputed data
4. **Always run analysis** - diagnostics are produced on every run
5. Store computed artifacts back to cache

This ensures diagnostics are always reported regardless of cache state.

```zig
// Cache hit still produces diagnostics
var analyzer = Analyzer.init(allocator);
try analyzer.enableCache();
try analyzer.registerRule(&MyRule.rule);

// First run - computes and caches artifacts
try analyzer.analyzeFile("test.zig");
const first_diag_count = analyzer.diagnostics.items.len;

// Second run - uses cached artifacts, still produces same diagnostics
try analyzer.analyzeFile("test.zig");
const second_diag_count = analyzer.diagnostics.items.len;
// first_diag_count == second_diag_count
```

### Cached Artifacts

The `CachedArtifacts` struct stores:

- **CFGs per function**: Control-flow graphs keyed by function AST node index
- **Type info availability**: Whether ZIR/type info was available during caching

```zig
pub const CachedArtifacts = struct {
    allocator: std.mem.Allocator,
    cfgs: std.AutoHashMap(u32, *Cfg),
    had_type_info: bool,
};
```

### Serialization Format

Cached artifacts use a binary format with:
- Magic bytes: `ZWCA` (Zwanzig Cached Artifacts)
- Format version: Incremented when serialization format changes
- Payload: Serialized CFGs with nodes, edges, and metadata

The format version ensures old cache entries are automatically invalidated when the format changes.

### CLI Usage

Enable caching with `--cache`:

```bash
zwanzig --cache src/
```

Cache files are stored in `.zwanzig-cache/` in the current directory.

### Cache Directory Structure

```
.zwanzig-cache/
├── <hash1>.cache    # Cached artifacts for file 1
├── <hash2>.cache    # Cached artifacts for file 2
└── ...
```

Each cache file contains:
- Header: version, key hashes, timestamp, data length
- Body: serialized `CachedArtifacts`

## Variable Identification (VarId)

The analysis engine uses a `VarId` type for identifying variables throughout the analysis. This is an opaque identifier that maps to AST node indices.

### VarId Mapping

Variables are identified by their AST node index, providing a simple and unique identifier within a module:

```zig
pub const VarId = struct {
    value: u32,

    pub fn fromAstNode(node: u32) VarId {
        return .{ .value = node };
    }

    pub fn toAstNode(self: VarId) u32 {
        return self.value;
    }
};
```

**Benefits of AST-based identification:**
- Unique within a compilation unit
- Direct mapping back to source locations for diagnostics
- No separate symbol table required
- Works with nested scopes (inner declarations get different AST nodes)

### Environment Bindings

The `Environment` maps `VarId` to `AbstractValue`:

```zig
pub const Environment = struct {
    bindings: std.AutoHashMap(u32, AbstractValue),
    allocator: std.mem.Allocator,
};
```

When a variable declaration is processed:
1. Extract the AST node index for the declaration
2. Create a `VarId` from the AST node
3. Bind the variable to an initial abstract value (typically `unknown`)

When a variable is used:
1. Look up the AST node of the identifier
2. Query the environment for the abstract value
3. Use the value in transfer functions or constraint checks

## Future Directions

The current implementation provides a solid foundation. Potential future enhancements include:

- **Richer Abstract Domains** - Symbolic values, arithmetic propagation, slice length tracking
- **Cross-File Analysis** - Module discovery and interprocedural analysis across compilation units
- **Constraint Solver Upgrade** - Modular solver backend for more precise path pruning
- **Expanded Checker Suite** - Resource leaks, double-free detection, out-of-bounds access
