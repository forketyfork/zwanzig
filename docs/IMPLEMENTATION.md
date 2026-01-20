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

### Limitations

- ZIR generation requires valid, parseable Zig code (no syntax errors)
- Full type resolution requires the complete compilation context; standalone analysis provides limited type inference
- Currently supports module-level declarations; nested scopes require future work

### Integration with Analysis

The ZirBridge provides typed information that can be used by:

- **Type-aware rules**: Rules that need to distinguish between integer types, pointers, error unions, etc.
- **CFG-based analysis**: Control flow analysis can use type information to understand error propagation
- **Future semantic analysis**: Foundation for more sophisticated dataflow analysis

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

Future enhancements will implement transfer functions for:
- Literal evaluation (concrete integer values)
- Arithmetic operations
- Branch conditions (state forking)
- Function calls

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

## Future Enhancements

The current implementation provides a foundation for more sophisticated analysis:

- **Branch Constraints**: Fork state on conditions and prune infeasible paths
- **Error Semantics**: Model error unions and try/catch propagation
- **Interprocedural Analysis**: Inline function calls and build summaries
- **Multiple Output Formats**: JSON, SARIF for CI/CD integration
- **Configuration Files**: Project-specific rule configuration
