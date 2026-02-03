# Implementation details

Internal architecture and implementation of the Zwanzig static analyzer.

## Architecture

Zwanzig is a modular static analysis framework for Zig. The architecture has several components that work together to analyze source files and detect issues.

### Module layout

Larger subsystems are split into focused submodules with thin facades:

- `src/cli/` - CLI parsing (`args.zig`), config merge (`config_merge.zig`), default rule/checker registry (`registry.zig`), and the run loop (`run.zig`)
- `src/formatters/` - Output formatters (console text and SARIF)
- `src/cfg/` - CFG graph types, builder, and DOT output (facade: `src/cfg.zig`)
- `src/engine/` - Analysis engine internals (analysis, state, values, constraints, summaries, store) (facade: `src/engine.zig`)
- `src/zir/` + `src/types/` - ZIR bridge implementation and shared type info (facade: `src/zir_bridge.zig`)
- `src/lib.zig` - Public library exports for embedding

### Core components

#### Source parsing cache

The `Source` abstraction (`src/source.zig`) provides lazy, cached access to parsed Zig source code. Parsing happens once per file, even when multiple rules access the AST or tokens.

**Behavior:**
- Lazy parsing: AST and tokens are parsed when first requested
- Caching: Once parsed, results are cached for subsequent accesses
- Memory management: Cleanup via `deinit()`

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

The `Analyzer` (`src/analyzer.zig`) coordinates the analysis process:

1. Reads source files from disk
2. Creates a `Source` instance with parsed content
3. Runs all registered checkers and rules against the source (checkers first)
4. Collects and reports diagnostics

Each file is parsed once and the `Source` object is shared across all rules and checkers. The analyzer applies the configured rule filter and builds a `CheckerContext` (build metadata, type info, analysis limits/stats, config, dump directories) for checker execution.

#### Rule interface (legacy)

The `Rule` interface (`src/rule.zig`) defines the contract for legacy analysis rules:

```zig
pub const Rule = struct {
    name: []const u8,
    default_severity: Severity = .err,
    checkFn: *const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void,
};
```

Rules receive a `Source` pointer, allowing them to:
- Access raw source text via `getContent()`
- Parse and traverse the AST via `ast()`
- Examine tokens via `tokens()`
- Avoid redundant parsing when multiple rules access the same representations

#### Checker interface

The `Checker` interface (`src/checker.zig`) is the extensible API for analysis passes. It uses a hook-based architecture that supports multiple analysis stages (AST, CFG, IR).

```zig
pub const Checker = struct {
    name: []const u8,
    default_severity: Severity = .err,
    checkAstFn: ?*const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: CheckerContext,
    ) CheckerError!void = null,

    pub fn checkAst(...) CheckerError!void { ... }
    pub fn hasHooks(self: *const Checker) bool { ... }
};
```

**Behavior:**
- Hook-based design: Checkers implement specific hooks (currently `checkAstFn`) rather than a single check function
- Multiple analysis stages: Future versions will add CFG and IR hooks for control-flow and dataflow analysis
- Backward compatibility: `CheckerManagerWithRules` supports both new checkers and legacy rules
- Context-aware analysis: `CheckerContext` exposes build metadata, type information, analysis limits/stats, config, and visualization outputs

#### CheckerManager

The `CheckerManager` (`src/checker.zig`) handles checker registration and coordinates running checks:

```zig
pub const CheckerManager = struct {
    pub fn init(allocator: std.mem.Allocator) CheckerManager { ... }
    pub fn deinit(self: *CheckerManager) void { ... }
    pub fn registerChecker(self: *CheckerManager, checker: *const Checker) !void { ... }
    pub fn runAstChecks(self: *const CheckerManager, source: *Source, diagnostics: *std.ArrayList(Diagnostic), filter_fn: ?*const fn ([]const u8) bool, context: CheckerContext) CheckerError!void { ... }
};
```

#### CheckerManagerWithRules

For backward compatibility, `CheckerManagerWithRules` supports both checkers and legacy rules. Checkers run first, then adapted rules.

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
const context = CheckerContext{ .build_metadata = null };
try manager.runAstChecks(&source, &diagnostics, null, context);
```

#### Diagnostics

Diagnostics represent issues found by rules and checkers. Each includes:
- File path
- Source range (start and end locations)
- Rule ID
- Severity (`hint`, `warning`, or `err`)
- Message

The `Diagnostic` type (`src/diagnostic.zig`) provides:
- `Severity` enum with `hint`, `warning`, and `err` levels
- `Location` struct for line/column positions (1-based)
- `SourceRange` struct for start/end location pairs
- `LocationMapper` for converting byte offsets to line/column positions

**Message ownership:**

Diagnostics own their message strings. When creating via `Diagnostic.init()` or `Diagnostic.initAtLocation()`, the message is duplicated. `Analyzer.deinit()` frees all diagnostic messages. Rules and checkers should never manually free diagnostic messages.

**Output formats:**

The analyzer supports multiple output formats via `Analyzer.OutputFormat`:

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

- **SARIF format**: Code scanning format for GitHub and other tooling (SARIF 2.1.0)

The `--format` CLI flag controls output format (defaults to text). Formatter implementations are in `src/formatters/` (`console.zig`, `sarif.zig`).

## Parsing strategy

Zwanzig uses Zig's standard library parser (`std.zig.Ast.parse`). Parsing happens lazily:

1. `analyzeFile()` reads the file content
2. A `Source` object is created but no parsing occurs yet
3. When a checker or rule calls `source.ast()` or `source.tokens()`, parsing happens
4. The parsed AST is cached in the `Source` object
5. Subsequent calls return the cached result
6. `source.deinit()` releases the cached AST

This avoids parsing if no rule needs the AST and avoids redundant parsing when multiple rules need it.

## Parallel analysis

File-level analysis runs in parallel by default. The `--threads` flag controls thread pool size. Each worker uses a per-task arena allocator to reduce contention, and diagnostics are merged and sorted for deterministic output.

## Adding checkers

Implement analysis passes using the `Checker` interface.

### Creating a checker

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
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        _ = context;
        const tree = try src.ast();

        // Analyze the AST...

        // Report issues
        try diagnostics.append(allocator, Diagnostic.initAtLocation(
            allocator,
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

4. Register the checker in `src/cli/registry.zig` (for the CLI):
```zig
try analyzer.registerChecker(&MyChecker.checker);
```

### Legacy rules (backward compatibility)

Rules using the `Rule` interface continue to work via `CheckerManagerWithRules`.

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
4. Register the rule in `src/cli/registry.zig` (for the CLI)

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
            allocator,
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
            allocator,
            src.getFilePath(),
            "my-rule",
            .warning,
            "Issue description",
            range,
        ));
    }
};
```

## AST-based rule implementation

Rules use AST traversal to analyze code structure. Benefits over text-based scanning:

1. **Accuracy**: AST nodes precisely represent language constructs, avoiding false positives from string matching
2. **Context awareness**: The AST provides structural context (e.g., distinguishing a `catch` keyword in a comment vs actual code)
3. **Token information**: Access to token positions enables accurate source location reporting

### Example: empty-catch rule

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

### Example: dupe-import rule

The `dupe-import` rule uses token-based analysis to detect duplicate imports:

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

### Example: unused-decl rule

The `unused-decl` rule uses AST-based analysis to detect unused declarations:

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

The conservative approach avoids false positives by ignoring `pub` declarations (may be used externally), underscore-prefixed names (explicit opt-out), and special names like `main` and `panic` (entry points).

### Example: unreachable-code rule (CFG-based)

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

Handles unconditional returns, fully-terminating branches, and path-sensitive pruning.

### Example: empty-defer and empty-errdefer rules

These rules detect empty defer/errdefer blocks using AST analysis:

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
4. Report empty blocks as diagnostics

## Intermediate Representation (IR)

Zwanzig uses a minimal IR to bridge AST nodes and control-flow analysis, capturing the structure needed for dataflow analysis.

### IR node types

The IR (`src/ir.zig`) defines:

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

### IR node structure

Each `IrNode` contains:
- `tag`: The kind of IR node (`IrTag`)
- `ast_node`: Optional index of the corresponding AST node
- `source_range`: Optional source location for diagnostics

```zig
pub const IrNode = struct {
    tag: IrTag,
    ast_node: ?u32,
    source_range: ?SourceRange,
};
```

## Control Flow Graph (CFG)

The CFG (`src/cfg.zig`) represents control flow within a function. It maps IR nodes to their control flow relationships. The facade in `src/cfg.zig` re-exports from `src/cfg/` (`graph.zig`, `builder.zig`, `dot.zig`).

### CFG structure

A CFG has:
- `nodes`: List of `CfgNode` entries, each containing an IR node
- `edges`: List of `CfgEdge` entries connecting nodes
- `entry`: Index of the function entry node
- `exit`: Index of the function exit node

### Edge types

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

### CFG builder

The `CfgBuilder` constructs CFGs from Zig AST function declarations. Supported constructs:

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

### CFG traversal

The CFG provides methods for traversing the graph:

```zig
// Get all successor node indices
var succs: std.ArrayList(u32) = .empty;
try cfg.getSuccessors(allocator, node_index, &succs);

// Get all predecessor node indices
var preds: std.ArrayList(u32) = .empty;
try cfg.getPredecessors(allocator, node_index, &preds);
```

### Source location mapping

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

The CFG builder supports `if` and `if-else` constructs:

1. **Branch nodes**: An `if` creates a `branch` IR node for the condition evaluation
2. **True/false edges**: Edges to the then-block are `branch_true`, edges to else-block (or merge point) are `branch_false`
3. **Merge points**: A `nop` node after the if/else is where control flow reconverges
4. **Terminating branches**: If both branches terminate, the merge point is not connected (unreachable code)

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

The CFG builder supports `while` and `for` loops with back-edges:

1. **Loop header**: A `loop_header` node represents the condition evaluation
2. **Loop body**: A `loop_body` node marks entry into the body
3. **Back-edges**: After the body completes (without terminating), a `loop_back` edge connects back to the header
4. **Exit edge**: A `loop_exit` edge from the header leads to code after the loop
5. **Termination handling**: If the body terminates (e.g., with return), no back-edge is created

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

### Defer/errdefer CFG

The CFG builder models `defer` and `errdefer` statements:

1. **Defer nodes**: A `defer_stmt` node for each `defer`, connected via `defer_edge`
2. **Errdefer nodes**: An `errdefer_stmt` node for each `errdefer`, connected via `errdefer_edge`
3. **Body representation**: The defer body is a `block` node following the defer/errdefer node
4. **Execution order**: Defers are recorded in program order; actual execution is reverse order at function exit

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

### Try/catch CFG (error flow)

The CFG builder models Zig's error handling constructs (`try` and `catch`):

#### Try expressions

A `try` expression evaluates an error union and either unwraps the success value or propagates the error:

1. **Try node**: A `try_expr` node represents the error-checking point
2. **Error path**: A `try_error` edge connects to `fn_exit` (error propagation)
3. **Success path**: A `try_success` edge connects to the next statement

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

#### Catch expressions

A `catch` expression handles errors locally with a fallback value or handler block:

1. **Catch node**: A `catch_expr` node represents the error-handling point
2. **Success path**: A `catch_success` edge connects to the merge point (value unwrapped)
3. **Error path**: A `catch_error` edge connects to the handler, then to the merge point

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

#### Try in variable declarations

When `try` appears in a variable declaration's initializer (e.g., `const x = try foo();`), the CFG models both paths:

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

#### Catch in variable declarations

`catch` in a variable declaration creates branching for error handling:

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

## Typed IR bridge (ZIR integration)

The `ZirBridge` module (`src/zir_bridge.zig`) bridges Zwanzig's analysis pipeline and Zig's typed intermediate representation (ZIR). Implementation is in `src/zir/bridge.zig`, with declaration models in `src/zir/decls.zig` and shared type definitions in `src/types/type_info.zig`.

### Overview

ZIR (Zig Intermediate Representation) is the typed IR produced by the Zig compiler during semantic analysis. The ZirBridge uses `std.zig.AstGen` to generate ZIR from parsed source code, providing:

- Declaration types (variables, constants, functions)
- Function signatures and parameter types
- Type inference results

### Types

#### TypeInfo

Type information for a declaration or expression (defined in `src/types/type_info.zig`):

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

### ZirBridge usage

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

### How it works

1. **AST parsing**: Source code is parsed into `std.zig.Ast` via `Source`
2. **ZIR generation**: `std.zig.AstGen.generate()` converts AST to ZIR
3. **Declaration extraction**: Root declarations are extracted from both AST and ZIR
4. **Type mapping**: ZIR instruction types are mapped to `TypeInfo`

### AST to ZIR mapping

The `findZirInstForNode` function provides best-effort mapping from AST node indices to ZIR instruction indices by iterating ZIR instructions and checking their source node references:

- `pl_node` format: Most operations store their source node in `data.pl_node.src_node`
- `node` format: Parameters and declaration references store the node directly in `data.node`
- `un_node` format: Unary operations store their source node in `data.un_node.src_node`

### Limitations

- ZIR generation requires valid, parseable Zig code (no syntax errors)
- Full type resolution requires the complete compilation context; standalone analysis provides limited type inference
- Currently supports module-level declarations; nested scopes require future work
- AST-to-ZIR mapping is best-effort; some AST nodes may not have corresponding ZIR instructions or may map to multiple instructions

### Integration with analysis

ZirBridge typed information is used throughout the analysis pipeline for type-aware rules, CFG-based analysis, and IR nodes carrying `TypeInfo`.

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

#### Expression Type Queries

TypeContext provides methods for querying types of expressions and calls at specific AST nodes:

```zig
// Query expression type by AST node index
if (ctx.getExpressionType(ast_node)) |ti| {
    // Use type information
}

// Check if an expression returns an error union
if (ctx.isExpressionErrorUnion(ast_node)) {
    // Expression may return an error
}

// Get the return type of the containing function
if (ctx.getContainingFunctionReturnType(ast_node)) |ti| {
    if (ti.kind == .error_union) {
        // Function returns error union
    }
}

// Get expression type for a call node
if (ctx.getExpressionType(call_node)) |ti| {
    // ti.kind indicates the type category (e.g., .error_union)
    // ti.type_str contains the type name if known (e.g., "std.fs.File")
}
```

Expression type queries handle:
- **Call expressions**: Resolves the callee's return type
- **Try expressions**: Returns unknown (inner type not tracked)
- **Catch expressions**: Returns the RHS (catch body/fallback) type
- **Error values**: Returns error union type
- **Identifiers**: Looks up declared type (including local error variables)

### Source type API

The `Source` struct (`src/source.zig`) provides access to type information via lazy-loaded ZirBridge:

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

### CheckerContext type access

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

### Typed IR nodes

`IrNode` (`src/ir.zig`) carries optional type information:

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

### CfgBuilder type annotation

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

Annotations: `var_decl` nodes get the variable's declared type; `try_expr` and `catch_expr` nodes get `error_union` type.

## Analysis engine

The analysis engine (`src/engine.zig`) implements a worklist-based traversal of the CFG to build an exploded graph for path-sensitive static analysis. The facade in `src/engine.zig` re-exports from `src/engine/` (analysis, state, values, constraints, summaries, store, dot).

### Concepts

#### ProgramPoint

A `ProgramPoint` identifies a location in the analysis:

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

For each CFG node, there are two program points: pre-state (before execution) and post-state (after execution).

#### ProgramState

A `ProgramState` represents abstract program state at a given point, storing the environment mapping variables to abstract values:

```zig
pub const ProgramState = struct {
    env: Environment,       // Mapping from variables to abstract values
    cached_hash: ?u64,      // Cached hash for efficient deduplication
};
```

**Operations:** `init`, `clone`, `getVar`, `setVar`, `eql`, `computeHash`.

#### Abstract values

Abstract values represent possible runtime values:

```zig
pub const AbstractValue = union(enum) {
    unknown,              // No information available
    null_val,             // Definitely null
    non_null,             // Definitely not null (actual value unknown)
    int_range: IntRange,  // Integer within a known range
    concrete_int: i64,    // Known concrete integer
};
```

**Value categories:** `unknown` (default), `null_val`, `non_null`, `int_range`, `concrete_int`.

#### Environment

The `Environment` maps variable identifiers to abstract values:

```zig
pub const Environment = struct {
    bindings: std.AutoHashMap(u32, AbstractValue),
    allocator: std.mem.Allocator,
};
```

Variables are identified by their AST node index.

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

#### ExplodedGraph

The `ExplodedGraph` is the central data structure for path-sensitive analysis:

```zig
pub const ExplodedGraph = struct {
    nodes: std.ArrayList(ExplodedNode),
    node_map: std.AutoHashMap(u64, u32),  // For deduplication
    cfg: *const Cfg,
};
```

Deduplicates nodes with identical (point, state) pairs, tracks edges, and maps back to CFG nodes.

### Worklist algorithm

The `AnalysisEngine` uses a worklist-based algorithm:

1. Create entry node at `(pre(entry), initial_state)`
2. While worklist is not empty:
   - Pop a node
   - If at pre-state: apply transfer function, create post-state node
   - If at post-state: create pre-state nodes for all CFG successors
3. Skip nodes that already exist in the graph

```zig
var engine = AnalysisEngine.init(allocator, &cfg);
defer engine.deinit();

try engine.run();

const graph = engine.getGraph();
// Analyze the exploded graph...
```

### Deduplication

Deduplication ensures analysis terminates: loops don't cause infinite exploration, and paths converging to the same state are merged.

### Transfer function

The transfer function models how state changes when a CFG node executes:

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

Handles variable declarations (initializes with `unknown`) and assignments (updates in environment).

### Branch constraints and path pruning

The engine tracks constraints from branch conditions. When it encounters a branch node with `branch_true` or `branch_false` edges, it extracts constraints and applies them to successor states.

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

**Comparison operators:** `eq`, `ne`, `lt`, `le`, `gt`, `ge`.

#### ConstraintManager

The `ConstraintManager` tracks active constraints on a path. Operations: `addConstraint`, `isSatisfiable`, `refineValue`, `clone`.

#### ProgramState with constraints

The `ProgramState` includes a `ConstraintManager`:

```zig
pub const ProgramState = struct {
    env: Environment,
    constraints: ConstraintManager,
    cached_hash: ?u64,
};
```

#### Path pruning

When processing branch edges, the engine extracts constraints from the branch condition, applies the constraint (or its negation), checks satisfiability, and prunes unsatisfiable paths.

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

#### Value refinement

When a constraint is added, the engine refines the variable's abstract value (e.g., `unknown` + `x == 5` → `concrete_int(5)`). When refinement returns `null`, the path is unsatisfiable and pruned.

#### Satisfiability checking

The `ConstraintManager.isSatisfiable` method checks environment compatibility and constraint consistency (e.g., `x == 5` AND `x == 6` is contradictory).

### Usage example

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

## Error-handling checkers

The engine supports error-handling checkers using CFG and error state tracking.

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

The checker identifies empty handlers by checking if the `catch_error` edge goes directly to a merge node (nop).

### SwallowedErrorChecker

The `SwallowedErrorChecker` (`src/checkers/swallowed_error.zig`) detects catch blocks that swallow errors.

**Detection:** Build CFG, run engine to track error states, and for each `catch_expr` node check if the handler returns (good), contains a function call (good - might log), or just falls through to merge (swallowed).

The engine tracks `ErrorState`: `error_active`, `error_handled`, or `normal`. When the handler exits normally without logging or rethrowing, the error is swallowed.

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

### StoreViolationsEngineChecker

The `StoreViolationsEngineChecker` (`src/checkers/store_violations_engine.zig`) reports allocator/resource misuse: double-free, free-without-alloc, close-without-open, use-after-free/close, and leaks. It runs the engine per function and scans `ProgramState` store violations.

#### Ownership escape heuristics

The store model tracks when resources "escape" (ownership transferred) to avoid false leak reports.

**1. Field assignment escape**

Resources assigned to fields of long-lived owners are marked escaped:

```zig
// Resource escapes via field assignment
cache.entries = entries;  // entries is marked escaped
```

The `recordOwnershipFromFieldAssign` function detects this when the LHS is a field access, the base is `self` (method receiver), the base is a pointer type, or the base is not a locally-tracked allocation.

**2. Container method escape**

Resources passed to container insertion methods are marked escaped:

```zig
// Resource escapes via container insertion
list.append(allocator, data);    // data is marked escaped
list.insert(allocator, 0, item); // item is marked escaped
map.put(key, value);             // key and value are marked escaped
```

The `trackEscapesFromCall` function recognizes container methods: `append`, `appendAssumeCapacity`, `appendSlice`, `insert`, `put`, `putNoClobber`, etc.

**3. Init-like function escape**

Resources passed to functions with initialization-like prefixes are marked escaped:

```zig
// Resource escapes via init function
initCache(cache, entries, ...);  // all params are marked escaped
setupComponent(ptr, data);       // all params are marked escaped
```

Recognized prefixes: `init`, `setup`, `set`, `store`, `register`, `add`, `push`.

Escape tracking is performed **before** function inlining.

#### Error-path leak policy

Leak violations are only reported on normal return paths. Error returns suppress leak reports (caller handles cleanup via `errdefer`).

The engine detects error returns via literal error values (`return error.SomeError`) and type-based detection (`TypeContext`).

#### Type-based resource detection

The store model identifies resource operations using a priority-based system:

1. Config-defined models (highest priority)
2. Built-in name patterns (`alloc`/`free`, `create`/`destroy`, `open`/`close`)
3. Type-based detection (methods returning `File`, `Dir`, `Socket`, etc.)

#### Configuration integration

The checker accepts a `Config` pointer via `AnalysisEngine.setConfig()`. Config-defined resource models are checked before built-in heuristics.

```zig
// In checker code
var engine = AnalysisEngine.initWithSource(allocator, cfg, src);
engine.setTypeContext(&type_ctx);
if (context.config) |config| {
    engine.setConfig(config);
}
```

### Registration

These checkers are registered in `src/cli/registry.zig`:

```zig
try analyzer.registerChecker(&EmptyCatchEngineChecker.checker);
try analyzer.registerChecker(&OptionalUnwrapEngineChecker.checker);
try analyzer.registerChecker(&SwallowedErrorChecker.checker);
try analyzer.registerChecker(&UnreachableCodeChecker.checker);
try analyzer.registerChecker(&StoreViolationsEngineChecker.checker);
```

## Interprocedural analysis

The engine supports limited interprocedural analysis through function inlining.

### Function inlining

When the engine encounters a function call, it attempts to inline the callee's CFG if:

1. Source is available (initialized with `initWithSource()`)
2. Call is resolvable (simple identifier calls to local functions)
3. Depth limit not exceeded (default: 3)

If any condition fails, the call has **unknown effects**.

### Call stack tracking

The `ProgramState` maintains a call stack:

```zig
pub const CallSite = struct {
    call_node: u32,      // CFG node of the call instruction
    caller_cfg: *const Cfg,  // CFG containing the call
    return_node: u32,    // Node to continue from after return
};
```

When inlining: increment depth, push call site, analyze callee. On callee exit: pop call site, decrement depth, continue at caller.

### Configuration

```zig
var engine = AnalysisEngine.initWithSource(allocator, &cfg, &source);
defer engine.deinit();

engine.setMaxInlineDepth(5);  // Increase inline depth to 5
try engine.run();

std.debug.print("Inlined {d} calls\n", .{engine.getInlinedCallCount()});
```

### External calls

Calls that cannot be inlined are treated as **external calls** with unknown effects (method calls, indirect calls, depth-limited calls, built-ins). The engine conservatively assumes they may modify any mutable state, return `unknown`, and have unknown error behavior.

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

- Simple calls only: direct function calls with identifier callees
- No recursion handling: limited by inline depth
- Single-file only: cross-file calls are external

## Function summaries

The engine supports function summaries to avoid re-analyzing the same function body at each call site.

### Summary contents

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

### Summary cache

The `SummaryCache` stores summaries keyed by function AST node index:

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

### Summary application

When processing a function call, the engine: checks the cache, computes a summary if not cached, checks applicability, applies the summary, or falls back to inlining.

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

### Summary generation

Summaries are generated by analyzing the function's CFG: scanning nodes for error-returning constructs, checking edges for error paths, identifying pure functions, and setting conservative defaults.

### Configuration

```zig
var engine = AnalysisEngine.initWithSource(allocator, &cfg, &source);

// Disable summaries (always inline)
engine.setUseSummaries(false);

// Set inline depth limit
engine.setMaxInlineDepth(5);
```

## Build metadata integration

The analyzer integrates build metadata and target configuration, allowing rules and checkers to access platform-specific information.

### Build metadata types

The `build_metadata.zig` module provides types for build configuration:

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

### CLI integration

The `--target` flag specifies a target triple:

```bash
zwanzig --target x86_64-linux-gnu src/
zwanzig --target aarch64-macos src/
```

The target triple is parsed into `BuildMetadata` and propagated through the analyzer. Other CLI flags (`--do`/`--skip`, `--config`, `--format`, `--max-steps`, etc.) configure the analyzer and engine.

### Analysis engine integration

Build metadata is stored in `Analyzer`, `AnalysisEngine`, and propagated to `ProgramState`:

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

### Accessing build metadata

Rules and checkers access build metadata from `ProgramState`:

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

### Use cases

Build metadata enables target-specific analysis: platform-specific APIs, size optimization, freestanding checks, ABI compatibility.

### Native target detection

When no `--target` is specified, the analyzer uses native target from `@import("builtin").target`:

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

## Incremental cache

The analyzer supports incremental caching to track analysis metadata across runs. The cache stores metadata (e.g., whether type info was loaded) and cached CFGs to speed up repeated runs, but it never skips analysis.

### Cache architecture

The cache system has two components:

1. `Cache` (`src/cache.zig`): Low-level persistent storage
2. `CachedArtifacts` (`src/cached_artifacts.zig`): Serialization of intermediate artifacts

### Cache key components

Cache keys (`CacheKey`) are computed from multiple sources:

```zig
pub const CacheKey = struct {
    file_hash: [32]u8,      // SHA-256 of file content
    target_hash: [32]u8,    // Hash of target architecture/OS/ABI
    version_hash: [32]u8,   // Hash of Zwanzig tool version
    config_hash: [32]u8,    // Hash of enabled rules/checkers and type-info availability
};
```

**Invalidation triggers:** file content changes, target platform changes, version updates, rule configuration changes, or type-info availability changes.

### Cache behavior

**Key principle:** The cache never skips analysis. Diagnostics are always produced on every run. Cache stores metadata and cached CFGs.

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

### Cached artifacts

The `CachedArtifacts` struct stores CFGs per function and type info availability. Currently only `had_type_info` is populated; CFG serialization is in place but not yet emitted.

```zig
pub const CachedArtifacts = struct {
    allocator: std.mem.Allocator,
    cfgs: std.AutoHashMap(u32, *Cfg),
    had_type_info: bool,
};
```

### Serialization format

Binary format with magic bytes (`ZWCA`), format version, and payload. Version changes invalidate old cache entries.

### CLI usage

Enable caching with `--cache`:

```bash
zwanzig --cache src/
```

Cache files are stored in `.zwanzig-cache/` in the current directory.

### Cache directory structure

Cache files are stored in `.zwanzig-cache/` with hash-based filenames. Each file contains a header (version, key hashes, timestamp, data length) and body (serialized `CachedArtifacts`).

## Variable identification (VarId)

The analysis engine uses a `VarId` type for identifying variables. Variables are identified by their AST node index:

```zig
// In src/ids.zig
pub const VarId = enum(u32) { _ };

pub fn varId(value: u32) VarId {
    return @enumFromInt(value);
}

pub fn varIndex(id: VarId) u32 {
    return @intFromEnum(id);
}
```

Benefits: unique within a compilation unit, direct mapping to source locations, no separate symbol table, works with nested scopes.

### Environment bindings

The `Environment` maps `VarId` to `AbstractValue`:

```zig
// In src/engine/env.zig
pub const Environment = struct {
    bindings: std.AutoHashMap(VarId, AbstractValue),
    allocator: std.mem.Allocator,
};
```

When processing a declaration: extract AST node index, create `VarId`, bind to initial abstract value (`unknown`). When using a variable: look up AST node, query environment, use in transfer functions or constraint checks.
