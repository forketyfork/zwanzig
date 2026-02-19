# Parity Implementation Plan

This document outlines features to implement in zwanzig to expand its rule coverage and configurability.

## Table of Contents

1. [New Rules](#new-rules)
2. [Per-Rule Configuration](#per-rule-configuration)
3. [GitHub Output Format](#github-output-format)
4. [JSON Schema for Configuration](#json-schema-for-configuration)

---

## New Rules

### 1. `homeless-try`

**Category:** Compiler
**Default Severity:** Error
**Complexity:** Medium

**Description:**
Flags `try` expressions used in contexts where errors cannot be propagated. The `try` keyword is only valid inside functions that return an error union.

**Detect violations in:**
- Container-level (file scope) variable declarations
- Functions with non-error return types (e.g., `void`, `u32`)
- Struct field default values
- Enum/union field default values

**Allowed exceptions:**
- `try` inside `comptime` blocks within functions (Zig allows this)
- Functions returning error unions (`!T`)

**Examples of violations:**

```zig
const std = @import("std");

// Violation: container-level try
var global = try std.heap.page_allocator.alloc(u8, 8);

// Violation: non-error-returning function
fn foo() void {
    var x = try std.heap.page_allocator.alloc(u8, 8);
}

// Violation: struct field default
fn bar() !void {
    const Baz = struct {
        data: []u8 = try std.heap.page_allocator.alloc(u8, 8),
    };
}
```

**Correct code:**

```zig
fn foo() !void {
    var x = try std.heap.page_allocator.alloc(u8, 8);
}

// comptime blocks are allowed
fn bar(x: u32) void {
    comptime {
        try baz(x);
    }
}
```

**Implementation notes:**
- Walk AST to find `try` expressions
- Track current function context and its return type
- Check if inside `comptime` block (allowed)
- Use `Source.findDeclType()` or return type analysis to determine if function returns error union

---

### 2. `no-unresolved`

**Category:** Correctness
**Default Severity:** Error
**Complexity:** Low

**Description:**
Flags `@import` calls that reference non-existent files. Only validates file-based imports (paths ending in `.zig`), not build system modules.

**Detection logic:**
1. Find all `@import("...")` calls where the string ends with `.zig`
2. Resolve the path relative to the importing file's directory
3. Check that the target exists and is a regular file (not a directory)
4. Symlinks are allowed but not followed for validation

**Examples of violations:**

Given directory structure:
```
.
├── foo.zig
├── mod/
│   └── bar.zig
├── not_a_file.zig/   <- directory
│   └── baz.zig
└── root.zig
```

```zig
// root.zig
const x = @import("mod/foo.zig");    // Error: foo.zig is in root, not mod/
const y = @import("not_a_file.zig"); // Error: this is a directory
const z = @import("missing.zig");    // Error: file does not exist
```

**Correct code:**

```zig
// root.zig
const x = @import("foo.zig");
const y = @import("mod/bar.zig");
const z = @import("std");            // Not checked: no .zig extension
```

**Implementation notes:**
- Parse `@import` builtin calls from AST
- Extract string literal argument
- Only process if path ends with `.zig`
- Use `std.fs` to check file existence and type
- Report with the import location and missing path

---

### 3. `useless-error-return`

**Category:** Suspicious
**Default Severity:** Warning (disabled by default)
**Complexity:** High

**Description:**
Detects functions declared with error union return types (`!T`) that never actually return or propagate errors. This misleads callers into handling errors that cannot occur.

**Detection scenarios:**
1. Function body contains no `return error.*` statements
2. Function contains no `try` expressions that could propagate
3. All error-returning calls are caught and handled (e.g., `catch @panic(...)`, `catch null`)
4. Function only returns success values

**Allowed exceptions:**
- Functions with explicit empty error set: `error{}!void`
- Functions that return the result of another error-returning call directly
- Functions using `try` (implicit propagation)

**Examples of violations:**

```zig
// Never returns an error
fn foo() !void {
    return;
}

// Catches all errors internally
fn init(allocator: std.mem.Allocator) !Foo {
    const ptr = allocator.create(Foo) catch @panic("OOM");
    ptr.* = .{};
    return ptr;
}

// Only returns success value
fn compute() !u32 {
    return 42;
}
```

**Correct code:**

```zig
// Actually returns errors
fn foo() !void {
    return error.Failed;
}

// Propagates errors
fn bar() !void {
    return baz();
}

// Uses try
fn qux() !void {
    try riskyOperation();
}

// Empty error set is explicit
fn safe() error{}!void {}
```

**Implementation notes:**
- Requires control flow analysis to track all return paths
- May need to be a checker (CFG-based) rather than a simple rule
- Track: `return error.*`, `try` expressions, `catch |e| return e` patterns
- Consider using existing engine infrastructure for path analysis

---

### 4. `unsafe-undefined`

**Category:** Restriction
**Default Severity:** Warning
**Complexity:** Medium

**Description:**
Flags variables initialized or assigned to `undefined`. Reading uninitialized memory causes undefined behavior that debug builds may catch but release builds will not.

**Detect violations:**
- Variable declarations: `var x: T = undefined;`
- Assignments: `x = undefined;`
- Struct field defaults: `field: T = undefined`
- Comparisons (always unsafe): `x == undefined`

**Allowed exceptions:**

1. **SAFETY comments:** A `// SAFETY:` comment on the preceding line suppresses the warning
   ```zig
   // SAFETY: initializeFoo writes to foo before any read
   var foo: u32 = undefined;
   initializeFoo(&foo);
   ```

2. **Array-typed variables:** Array initialization with undefined is common and safe when immediately filled
   ```zig
   var buf: [1024]u8 = undefined;
   @memset(&buf, 0);
   ```
   Note: Array-typed struct fields with `undefined` default are still violations.

3. **Whitelisted types:** Configurable list of types allowed to use undefined (default: `ThreadPool`, `Thread.Pool`)

4. **Destructor functions:** Methods named `deinit`, `destroy`, or `reset` may use undefined to invalidate freed data
   ```zig
   fn deinit(self: *Foo, alloc: Allocator) void {
       alloc.free(self.data);
       self.* = undefined;  // OK: invalidates freed struct
   }
   ```

5. **Test blocks:** All `undefined` usage in `test` blocks is allowed

**Examples of violations:**

```zig
const x = undefined;

const Foo = struct {
    ptr: *u32 = undefined,  // Forces consumers to handle uninitialized state
};

var y: *u32 = allocator.create(u32);
y.* = undefined;
```

**Correct code:**

```zig
// SAFETY: initialized by initBar before use
var bar: Bar = undefined;
initBar(&bar);

var arr: [10]u8 = undefined;  // Arrays OK
@memset(&arr, 0);

test "example" {
    var x: Foo = undefined;  // OK in tests
}
```

**Configuration options:**
- `allowed_types`: `[]string` - Types that may use undefined (default: `["ThreadPool", "Thread.Pool"]`)
- `allow_arrays`: `bool` - Whether array-typed variables may use undefined (default: `true`)

---

### 5. `no-print`

**Category:** Restriction
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Flags usage of `std.debug.print`. Print statements are useful for debugging but should be removed before merging. Use `std.log` for production logging.

**Detection patterns:**
- `std.debug.print(...)`
- `debug.print(...)` where `debug = std.debug`
- `print(...)` where `print = std.debug.print`

**Allowed exceptions:**

1. **Test blocks:** By default, print in `test` blocks is allowed
2. **Test files:** Files ending with `test.zig` are ignored by default
3. **Local print functions:** If a `print` function is defined in the same file, calls to it are not flagged

**Examples of violations:**

```zig
const std = @import("std");
const debug = std.debug;
const print = std.debug.print;

fn main() void {
    std.debug.print("Debug: {d}\n", .{42});
    debug.print("Also debug\n", .{});
    print("Still debug\n", .{});
}
```

**Correct code:**

```zig
const std = @import("std");

fn foo() u32 {
    std.log.debug("running foo", .{});
    return 1;
}

test "example" {
    std.debug.print("testing\n", .{});  // OK in tests
}

// Local print function - not flagged
fn print(comptime msg: []const u8, args: anytype) void {
    // custom implementation
}
fn bar() void {
    print("custom print", .{});  // OK: local function
}
```

**Configuration options:**
- `allow_tests`: `bool` - Allow print in test blocks and test files (default: `true`)

---

### 6. `must-return-ref`

**Category:** Suspicious
**Default Severity:** Warning
**Complexity:** Medium

**Description:**
Flags functions that return copies of types storing a `capacity` field. Zig lacks move semantics, so returning by value copies the struct. For container types that track allocated memory, this can lead to memory leaks when the copy's capacity diverges from the original.

**Detection logic:**
1. Find functions returning struct types (not pointers)
2. Check if the return type has a `capacity` field
3. Flag if the returned value comes from a struct field access (not a fresh instance)

**Known types with capacity:**
- `std.ArrayList(T)`
- `std.ArrayListUnmanaged(T)`
- `std.mem.Allocator` (some implementations)
- `std.heap.ArenaAllocator`
- Any struct with a `capacity: usize` field

**Examples of violations:**

```zig
const std = @import("std");

const Foo = struct {
    list: std.ArrayList(u32),

    // Violation: returns copy of capacity-storing field
    pub fn getList(self: *Foo) std.ArrayList(u32) {
        return self.list;
    }
};

pub fn main() !void {
    var foo: Foo = .{ .list = std.ArrayList(u32).init(allocator) };
    defer foo.list.deinit();

    var list = foo.getList();  // Copy!
    try list.append(1);         // Allocates new memory, leaked
}
```

**Correct code:**

```zig
// Return by reference
fn getList(self: *Foo) *std.ArrayList(u32) {
    return &self.list;
}

// Returning new instances is fine
fn createList(allocator: Allocator) std.ArrayList(u32) {
    return std.ArrayList(u32).init(allocator);
}

// Returning from init/create functions is fine
fn init(allocator: Allocator) ArenaAllocator {
    return std.heap.ArenaAllocator.init(allocator);
}
```

**Implementation notes:**
- Need type information to identify capacity-storing types
- Track whether return value is a field access vs. fresh construction
- May need `ZirBridge` for type resolution

---

### 7. `duplicate-case`

**Category:** Suspicious
**Default Severity:** Warning (disabled by default)
**Complexity:** Medium

**Description:**
Flags switch statements with case branches that have identical target expressions. Such branches could be merged without changing behavior, suggesting copy-paste errors or dead code.

**Detection logic:**
- Compare AST structure of case target expressions
- Flag when two or more cases have structurally identical targets
- Does not compare the values being switched over, only the result expressions

**Examples of violations:**

```zig
fn foo(x: u32) u32 {
    return switch (x) {
        1 => 1,
        2 => 1,      // Duplicate of case 1's expression
        else => 0,
    };
}

fn bar(y: u32) u32 {
    return switch (y) {
        1 => y + 1,
        2 => 1 + y,  // Structurally identical: addition is commutative
        else => y * 2,
    };
}
```

**Correct code:**

```zig
fn foo(x: u32) u32 {
    return switch (x) {
        1, 2 => 1,   // Merged cases
        else => 0,
    };
}

fn bar(y: u32) u32 {
    return switch (y) {
        1 => y + 1,
        2 => y * 2,  // Different expressions
        3 => y - 1,
        else => 0,
    };
}
```

**Implementation notes:**
- AST comparison needs to handle commutative operations
- Consider providing hints about which cases are duplicates
- May want configurable strictness for structural comparison

---

### 8. `avoid-as`

**Category:** Pedantic
**Default Severity:** Warning
**Complexity:** Medium

**Description:**
Flags usage of `@as()` when the type could be inferred from context. Zig's Result Location Semantics allow types to flow from variable declarations, function parameters, and return types. Explicit `@as()` is only needed when no other context exists.

**Detection scenarios:**
- `const x = @as(T, value)` - type annotation preferred: `const x: T = value`
- `return @as(T, value)` - function return type provides context
- `foo(@as(T, value))` - function parameter type provides context

**Note:** Checks for function parameters and return types may be complex to implement and can be deferred.

**Examples of violations:**

```zig
const x = @as(u32, 1);  // Should be: const x: u32 = 1

fn foo(x: u32) u64 {
    return @as(u64, x);  // Return type already specifies u64
}

fn bar(val: u32) void {}
bar(@as(u32, 1));  // Parameter type already specifies u32
```

**Correct code:**

```zig
const x: u32 = 1;

fn foo(x: u32) u64 {
    return x;  // Implicit coercion to return type
}

bar(1);  // Implicit coercion to parameter type

// @as is appropriate when no context exists
const arr = [_]u8{ @as(u8, value), @as(u8, other) };
```

**Implementation notes:**
- Track declaration context (variable type annotation, function return type)
- Start with simple case: `const x = @as(T, ...)` where `: T` annotation is missing
- May need flow analysis for return statements and function calls

---

### 9. `no-catch-return`

**Category:** Pedantic
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Flags `catch` blocks that immediately return the caught error without any side effects. Such blocks should be replaced with `try`, which is more idiomatic.

**Detection pattern:**
- `expr catch |e| return e`
- `expr catch |e| { return e; }`

**Allowed exceptions:**
- Catch blocks with additional statements (logging, cleanup)
- Catch blocks that return a different error

**Examples of violations:**

```zig
fn foo() !void {
    riskyOp() catch |e| return e;

    riskyOp() catch |e| {
        return e;
    };
}
```

**Correct code:**

```zig
fn foo() !void {
    try riskyOp();  // Preferred
}

// Side effects before return are fine
fn bar() !void {
    riskyOp() catch |e| {
        std.log.err("Operation failed: {}", .{e});
        return e;
    };
}

// Returning different error is fine
fn baz() !void {
    riskyOp() catch |_| return error.WrappedError;
}
```

**Implementation notes:**
- Find catch expressions with payload capture
- Check if body is single return statement returning the captured payload
- Simple AST pattern matching

---

### 10. `no-return-try`

**Category:** Pedantic
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Flags `return try expr` patterns. Returning an error union directly has identical semantics to `try`ing it and returning the result. The `try` is redundant.

**Note:** `errdefer` blocks still execute correctly without the `try`.

**Examples of violations:**

```zig
fn foo() !void {
    return error.Failed;
}

fn bar() !void {
    return try foo();  // Redundant try
}
```

**Correct code:**

```zig
fn bar() !void {
    errdefer {
        std.debug.print("cleanup on error\n", .{});
    }
    return foo();  // errdefer still runs on error
}
```

**Implementation notes:**
- Find return statements where the expression is a try expression
- Simple AST pattern matching

---

### 11. `empty-file`

**Category:** Style
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Flags empty `.zig` files. A file is considered empty if it contains only:
- Zero bytes
- Whitespace characters (as defined by `std.ascii.whitespace`)
- Comments (regular `//` or doc `///`)

**Examples of violations:**

```zig
// empty_module.zig

// This file only has comments
// Nothing meaningful here
```

**Correct code:**

```zig
// module.zig

pub fn init() void {}
```

**Implementation notes:**
- Check file content after stripping whitespace and comments
- Can use tokenizer to skip comment tokens
- Report on the file as a whole, not a specific location

---

### 12. `line-length`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Flags lines exceeding a configurable maximum column count. Long lines reduce readability and cause horizontal scrolling.

**Examples of violations (with max_length: 120):**

```zig
const longStructDeclarationInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };

fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherName() u32 {
    return 123;
}
```

**Correct code:**

```zig
const Config = struct {
    max_length: u32 = 120,
    a: usize = 123,
    b: usize = 12354,
    c: usize = 1234352,
};

fn getConstant() u32 {
    return 123;
}
```

**Configuration options:**
- `max_length`: `int` - Maximum allowed line length in columns (default: 120)

**Implementation notes:**
- Iterate source lines, check byte length
- Consider Unicode: count columns, not bytes (or document byte-based behavior)
- Report each offending line with its length

---

### 13. `allocator-first-param`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Flags functions that accept an allocator but not as the first parameter (or second, after `self`). This enforces the common Zig convention for consistent API design.

**Allocator parameter detection:**
- Parameter named: `allocator`, `alloc`, `gpa`, `arena`
- Parameter type ending with: `Allocator`

**Allowed positions:**
- First parameter
- Second parameter if first is `self`, `*Self`, `*const Self`, or similar self-reference

**Examples of violations:**

```zig
fn process(data: []const u8, allocator: std.mem.Allocator) !void {
    // allocator should be first
}

fn Foo.doWork(self: *Foo, value: u32, alloc: Allocator) !void {
    // allocator should be second (after self)
}
```

**Correct code:**

```zig
fn process(allocator: std.mem.Allocator, data: []const u8) !void {
    // ...
}

fn Foo.doWork(self: *Foo, allocator: Allocator, value: u32) !void {
    // ...
}
```

**Configuration options:**
- `ignore`: `[]string` - Function names to ignore (default: `[]`)

**Implementation notes:**
- Find function declarations with allocator-like parameters
- Check parameter position relative to self
- Simple AST inspection

---

### 14. `returned-stack-reference`

**Category:** Suspicious
**Default Severity:** Warning (disabled by default)
**Complexity:** High

**Description:**
Flags functions returning pointers or slices to stack-allocated memory. Once the function returns and the stack frame is popped, such references become invalid, causing undefined behavior or segfaults.

**Detection scenarios:**
- Returning address of local variable: `return &x`
- Returning slice of local array: `return arr[0..]`
- Returning pointer from local struct field: `return &local.field`

**Examples of violations:**

```zig
fn foo() *u32 {
    var x: u32 = 1;
    return &x;  // x is on stack, invalid after return
}

fn bar() []u32 {
    var arr: [4]u32 = .{ 1, 2, 3, 4 };
    return arr[0..];  // slice of stack array
}

fn baz() *u32 {
    var s: MyStruct = .{};
    return &s.value;  // pointer into stack struct
}
```

**Correct code:**

```zig
fn foo(allocator: Allocator) !*u32 {
    const ptr = try allocator.create(u32);
    ptr.* = 1;
    return ptr;  // Heap allocated, valid after return
}

fn bar(out: *[4]u32) void {
    out.* = .{ 1, 2, 3, 4 };  // Caller provides storage
}

// Returning static/global references is fine
var global: u32 = 0;
fn getGlobal() *u32 {
    return &global;
}
```

**Implementation notes:**
- Requires tracking variable storage class (stack vs. heap vs. static)
- May need CFG analysis to track pointer provenance
- Consider implementing as a checker using the engine
- Start with simple cases: direct `return &local_var`

---

### 15. `no-panic`

**Category:** Restriction
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Flags usage of `@panic`. Panics terminate the program and should generally be avoided in library code and production applications. Use error returns for recoverable failures.

**Detection patterns:**
- Direct calls: `@panic("message")`
- Aliased calls: `const panic = @panic; panic("message")`

**Allowed exceptions:**
1. **Test blocks:** Panics in test code are allowed by default
2. **Specific messages:** Configurable list of panic messages to allow (e.g., "unimplemented")

**Examples of violations:**

```zig
fn process(data: []const u8) void {
    if (data.len == 0) {
        @panic("empty data");  // Should return error instead
    }
}

fn init() *Resource {
    return allocator.create(Resource) catch @panic("OOM");
}
```

**Correct code:**

```zig
fn process(data: []const u8) !void {
    if (data.len == 0) {
        return error.EmptyData;
    }
}

fn init() !*Resource {
    return try allocator.create(Resource);
}

test "panics are ok in tests" {
    @panic("test failure");
}
```

**Configuration options:**
- `exclude_tests`: `bool` - Allow panics in test blocks (default: `true`)
- `allowed_messages`: `[]string` - Panic messages to allow (default: `[]`)

**Implementation notes:**
- Find `@panic` builtin calls in AST
- Check if inside test block
- Extract and match panic message string

---

### 16. `no-orelse-unreachable`

**Category:** Pedantic
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Flags `orelse unreachable` patterns. The `.?` operator is equivalent but more concise and idiomatic.

**Examples of violations:**

```zig
const value = optional orelse unreachable;
const ptr = maybePtr orelse unreachable;
```

**Correct code:**

```zig
const value = optional.?;
const ptr = maybePtr.?;
```

**Implementation notes:**
- Find `orelse` expressions where the RHS is `unreachable`
- Simple AST pattern matching

---

### 17. `explicit-error-sets`

**Category:** Restriction
**Default Severity:** Warning (disabled by default)
**Complexity:** Medium

**Description:**
Flags functions using inferred error unions (`!T`). Explicit error sets document possible failures and enable better error handling by callers.

**Detect violations:**
- Function return types using `!T` without explicit error set
- Functions returning `anyerror!T`

**Allowed exceptions:**
- Private functions (non-`pub`) can use inferred errors by default
- `anyerror` can be allowed via configuration

**Examples of violations:**

```zig
pub fn readFile(path: []const u8) ![]u8 {
    // Callers don't know what errors to expect
}

pub fn parse(input: []const u8) anyerror!Ast {
    // anyerror is too broad
}
```

**Correct code:**

```zig
pub fn readFile(path: []const u8) FileError![]u8 {
    // Error set is documented
}

const FileError = error{
    FileNotFound,
    AccessDenied,
    IoError,
};

// Private functions can use inferred errors
fn helper() !void {
    // ...
}
```

**Configuration options:**
- `allow_private`: `bool` - Allow inferred errors in non-pub functions (default: `true`)
- `allow_anyerror`: `bool` - Allow `anyerror` (default: `false`)

**Implementation notes:**
- Parse function return types
- Check for `!` without preceding error set identifier
- Track `pub` visibility

---

### 18. `no-hidden-allocations`

**Category:** Restriction
**Default Severity:** Warning (disabled by default)
**Complexity:** Medium

**Description:**
Flags functions that perform heap allocations without accepting an allocator parameter. Hidden allocations make resource management unpredictable and complicate testing.

**Detection patterns:**
- Usage of `std.heap.page_allocator`
- Usage of `std.heap.c_allocator`
- Usage of `std.heap.GeneralPurposeAllocator` without passing it to callers
- Direct `@import("std").heap.*` usage

**Allowed exceptions:**
1. **Test blocks:** Hidden allocations in tests are allowed
2. **Functions accepting allocator:** If the function takes an allocator parameter, it's fine

**Examples of violations:**

```zig
fn createBuffer() ![]u8 {
    return std.heap.page_allocator.alloc(u8, 1024);
}

const gpa = std.heap.GeneralPurposeAllocator(.{}){};
fn doWork() !void {
    const mem = try gpa.allocator().alloc(u8, 100);
    // ...
}
```

**Correct code:**

```zig
fn createBuffer(allocator: std.mem.Allocator) ![]u8 {
    return allocator.alloc(u8, 1024);
}

fn doWork(allocator: std.mem.Allocator) !void {
    const mem = try allocator.alloc(u8, 100);
    // ...
}

test "hidden allocations ok in tests" {
    const mem = try std.heap.page_allocator.alloc(u8, 100);
    defer std.heap.page_allocator.free(mem);
}
```

**Configuration options:**
- `exclude_tests`: `bool` - Allow in test blocks (default: `true`)
- `detect_page_allocator`: `bool` - Detect page_allocator usage (default: `true`)
- `detect_c_allocator`: `bool` - Detect c_allocator usage (default: `true`)
- `detect_gpa`: `bool` - Detect GeneralPurposeAllocator (default: `true`)

**Implementation notes:**
- Track imports and field accesses to `std.heap.*`
- Check if containing function has allocator parameter
- May require alias tracking for renamed imports

---

### 19. `require-braces`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Requires braces for control flow statements. Single-statement bodies without braces can lead to bugs when adding statements later.

**Applies to:**
- `if` / `else` statements
- `while` loops
- `for` loops
- `defer` statements
- `catch` blocks

**Examples of violations:**

```zig
if (condition)
    doSomething();

while (iter.next()) |item|
    process(item);

defer cleanup();
```

**Correct code:**

```zig
if (condition) {
    doSomething();
}

while (iter.next()) |item| {
    process(item);
}

defer {
    cleanup();
}
```

**Configuration options:**
- `if_else`: `string` - Requirement for if/else (`"always"`, `"multi_line_only"`, `"off"`) (default: `"always"`)
- `while`: `string` - Requirement for while (default: `"always"`)
- `for`: `string` - Requirement for for (default: `"always"`)
- `defer`: `string` - Requirement for defer (default: `"always"`)
- `catch`: `string` - Requirement for catch (default: `"always"`)

**Implementation notes:**
- Check if statement body is a block vs. single expression
- `multi_line_only` mode only flags when statement spans multiple lines

---

### 20. `require-doc-comment`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Requires documentation comments (`///`) for public declarations. Good documentation improves code maintainability and enables automatic doc generation.

**Applies to:**
- Public functions (`pub fn`)
- Public constants (`pub const`)
- Public types (structs, enums, unions)

**Examples of violations:**

```zig
pub fn processData(data: []const u8) !void {
    // No doc comment
}

pub const MaxSize = 1024;

pub const Config = struct {
    timeout: u32,
};
```

**Correct code:**

```zig
/// Processes the input data and returns processed result.
/// Returns error.InvalidData if the input is malformed.
pub fn processData(data: []const u8) !void {
    // ...
}

/// Maximum buffer size in bytes.
pub const MaxSize = 1024;

/// Configuration options for the processor.
pub const Config = struct {
    /// Timeout in milliseconds. Zero means no timeout.
    timeout: u32,
};
```

**Configuration options:**
- `public_only`: `bool` - Only require for pub declarations (default: `true`)
- `require_for_fields`: `bool` - Also require for struct fields (default: `false`)

**Implementation notes:**
- Find declarations without preceding `///` comment
- Check visibility (`pub` keyword)

---

### 21. `no-commented-code`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Medium

**Description:**
Flags commented-out code. Dead code should be removed rather than commented out; version control preserves history.

**Detection heuristics:**
- Comments containing Zig keywords (`fn`, `const`, `var`, `if`, `while`, `return`)
- Comments with Zig syntax patterns (`;` at end, `{}`, `()`)
- Multi-line comment blocks that look like code

**Allowed exceptions:**
- Comments explaining code (not containing code-like patterns)
- Single keywords used as notes (e.g., `// TODO: implement`)
- Example code in doc comments

**Examples of violations:**

```zig
fn foo() void {
    // const old_value = compute();
    // if (old_value > 0) {
    //     process(old_value);
    // }
    const new_value = compute_v2();
}
```

**Correct code:**

```zig
fn foo() void {
    // Use compute_v2 for better performance
    const new_value = compute_v2();
}
```

**Implementation notes:**
- Heuristic-based detection; may have false positives/negatives
- Analyze comment content for code patterns
- Consider consecutive comment lines as blocks

---

### 22. `no-deprecated`

**Category:** Correctness
**Default Severity:** Warning
**Complexity:** Medium

**Description:**
Flags usage of deprecated items. Items are considered deprecated if their doc comment contains "Deprecated:" followed by an explanation.

**Detection:**
- Find declarations with `/// Deprecated:` in doc comment
- Flag all references to those declarations

**Examples of violations:**

```zig
/// Deprecated: Use newFunction instead.
pub fn oldFunction() void {}

fn caller() void {
    oldFunction();  // Warning: using deprecated function
}
```

**Correct code:**

```zig
fn caller() void {
    newFunction();
}
```

**Implementation notes:**
- First pass: collect deprecated declarations
- Second pass: flag usages
- Parse doc comments for "Deprecated:" pattern

---

### 23. `no-magic-numbers`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Flags numeric literals passed directly as function arguments. Magic numbers reduce readability; named constants document intent.

**Allowed exceptions:**
- Common constants: `0`, `1`, `-1`, `2`
- Array/slice indexing
- Test blocks (by default)
- Specific function names (configurable)

**Examples of violations:**

```zig
fn setup() void {
    configure(8080, 30000, 5);  // What do these mean?
    setRetries(3);
}
```

**Correct code:**

```zig
const default_port = 8080;
const timeout_ms = 30000;
const max_connections = 5;
const max_retries = 3;

fn setup() void {
    configure(default_port, timeout_ms, max_connections);
    setRetries(max_retries);
}
```

**Configuration options:**
- `exclude_tests`: `bool` - Allow magic numbers in tests (default: `true`)
- `allowed_values`: `[]int` - Numbers that are always allowed (default: `[-1, 0, 1, 2]`)
- `ignore_functions`: `[]string` - Function names where magic numbers are allowed (default: `[]`)

**Implementation notes:**
- Find function call arguments that are numeric literals
- Check against allowed values list
- Skip indexing operations

---

### 24. `field-ordering`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Enforces consistent field ordering in struct, enum, and union declarations. Alphabetical ordering makes fields easier to locate in large types.

**Applies to:**
- Struct fields
- Enum variants
- Union fields
- Error set values

**Allowed exceptions:**
- `packed` structs (field order affects memory layout)
- `extern` structs (field order must match C ABI)

**Examples of violations:**

```zig
const Config = struct {
    timeout: u32,
    host: []const u8,
    port: u16,        // Should come before timeout
    buffer_size: usize,  // Should come before host
};

const Status = enum {
    running,
    idle,      // Should come before running
    stopped,
};
```

**Correct code:**

```zig
const Config = struct {
    buffer_size: usize,
    host: []const u8,
    port: u16,
    timeout: u32,
};

const Status = enum {
    idle,
    running,
    stopped,
};
```

**Configuration options:**
- `order`: `string` - Ordering direction (`"ascending"`, `"descending"`) (default: `"ascending"`)
- `exclude_packed`: `bool` - Skip packed structs (default: `true`)
- `exclude_extern`: `bool` - Skip extern structs (default: `true`)

**Implementation notes:**
- Extract field names from struct/enum/union declarations
- Compare against sorted order
- Check for `packed` or `extern` keywords

---

### 25. `import-ordering`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Enforces consistent ordering of `@import` statements. Organized imports improve readability.

**Ordering rules:**
1. Standard library imports (`@import("std")`) first
2. External package imports (no `.zig` extension)
3. Local file imports (`.zig` extension)
4. Within each group, alphabetical order

**Examples of violations:**

```zig
const utils = @import("utils.zig");
const std = @import("std");  // Should be first
const json = @import("json");
```

**Correct code:**

```zig
const std = @import("std");

const json = @import("json");

const utils = @import("utils.zig");
```

**Configuration options:**
- `order`: `string` - Ordering within groups (`"ascending"`, `"descending"`) (default: `"ascending"`)
- `require_groups`: `bool` - Require blank lines between groups (default: `false`)

**Implementation notes:**
- Collect all top-level `@import` declarations
- Classify by import type
- Check order within and between groups

---

### 26. `switch-else-last`

**Category:** Style
**Default Severity:** Warning
**Complexity:** Low

**Description:**
Enforces that `else` branches appear last in switch statements. This matches the conventional reading order and Zig's own style.

**Examples of violations:**

```zig
switch (value) {
    else => handleDefault(),
    .specific => handleSpecific(),  // else should be last
}
```

**Correct code:**

```zig
switch (value) {
    .specific => handleSpecific(),
    else => handleDefault(),
}
```

**Implementation notes:**
- Find switch expressions with `else` prong
- Check if `else` is the last case
- Simple AST inspection

---

### 27. `max-params`

**Category:** Style
**Default Severity:** Warning (disabled by default)
**Complexity:** Low

**Description:**
Flags functions with too many parameters. Many parameters suggest the function is doing too much or should accept a config struct.

**Allowed exceptions:**
- `extern` functions (must match external API)
- Functions where first parameter is `self` (one extra allowed)

**Examples of violations (with max_count: 5):**

```zig
fn createWidget(
    name: []const u8,
    width: u32,
    height: u32,
    color: Color,
    border: Border,
    padding: u32,  // 6th parameter
) Widget {
    // ...
}
```

**Correct code:**

```zig
const WidgetConfig = struct {
    name: []const u8,
    width: u32,
    height: u32,
    color: Color,
    border: Border,
    padding: u32 = 0,
};

fn createWidget(config: WidgetConfig) Widget {
    // ...
}
```

**Configuration options:**
- `max_count`: `int` - Maximum allowed parameters (default: `5`)
- `exclude_extern`: `bool` - Skip extern functions (default: `true`)

**Implementation notes:**
- Count function parameters
- Check for `extern` keyword
- Account for `self` parameter

---

## Per-Rule Configuration

Extend the configuration system to support rule-specific options and common overrides.

### Common Options

Every rule supports these common configuration options:

| Option | Type | Description |
|--------|------|-------------|
| `severity` | `string` | Override default severity: `"error"`, `"warning"`, `"hint"`, or `"off"` |
| `exclude_tests` | `bool` | Skip checking inside `test` blocks (default varies by rule) |
| `exclude_files` | `[]string` | Glob patterns for files to skip (e.g., `["*_test.zig", "vendor/**"]`) |

### Updated Config Format

```json
{
  "enabled_rules": ["unsafe-undefined", "line-length"],
  "disabled_rules": ["todo"],
  "rules": {
    "unsafe-undefined": {
      "severity": "error",
      "exclude_tests": true,
      "allowed_types": ["ThreadPool", "Thread.Pool", "CustomBuffer"],
      "allow_arrays": true
    },
    "no-print": {
      "severity": "warning",
      "exclude_tests": true,
      "exclude_files": ["examples/**"]
    },
    "no-panic": {
      "severity": "warning",
      "exclude_tests": true,
      "allowed_messages": ["unimplemented"]
    },
    "line-length": {
      "max_length": 100
    },
    "field-ordering": {
      "order": "ascending",
      "exclude_packed": true
    },
    "max-params": {
      "max_count": 6,
      "exclude_extern": true
    },
    "allocator-first-param": {
      "ignore": ["legacyFunction", "externalCallback"]
    }
  },
  "max_worklist_steps": 200000,
  "max_states_per_point": 50
}
```

### Implementation Tasks

1. **Extend config parser** (`src/cli/config.zig`):
   - Parse `rules` object from JSON
   - Store rule configs as `StringHashMap(json.Value)` or typed structs
   - Validate rule names exist
   - Support common options for all rules

2. **Add `RuleConfig` type**:
   ```zig
   pub const RuleConfig = struct {
       // Common fields (all rules)
       severity: ?Severity = null,
       exclude_tests: ?bool = null,
       exclude_files: ?[]const []const u8 = null,

       // Rule-specific options stored as JSON for flexibility
       options: ?std.json.Value = null,

       pub fn get(self: RuleConfig, comptime T: type, key: []const u8, default: T) T {
           // Extract typed value from options
       }

       pub fn shouldSkipFile(self: RuleConfig, file_path: []const u8) bool {
           // Check against exclude_files patterns
       }
   };
   ```

3. **Update Rule interface**:
   - Pass `?*const RuleConfig` to `checkFn`
   - Rules extract their options with defaults
   - Check `exclude_tests` in common code before invoking rule

4. **Add test context detection**:
   - Helper to determine if AST node is inside a `test` block
   - Used by rules respecting `exclude_tests`

5. **Document** in `docs/CONFIG.md`:
   - Add per-rule configuration section
   - Document common options
   - Document each rule's specific options

---

## GitHub Output Format

Add `--format github` (or `--format gh`) for GitHub Actions workflow command output.

### Output Format

GitHub Actions interprets lines starting with `::` as workflow commands:

```
::warning file=src/main.zig,line=10,col=5,title=empty-catch::Empty catch block detected
::error file=src/utils.zig,line=23,col=1,title=homeless-try::try used outside error-returning function
```

### Format Specification

```
::<severity> file=<path>,line=<line>,col=<column>,title=<rule>::<message>
```

- `severity`: `notice`, `warning`, or `error`
- `file`: Relative file path
- `line`: 1-based line number
- `col`: 1-based column number
- `title`: Rule name (displayed as annotation title)
- `message`: Diagnostic message (after `::`)

### Severity Mapping

| Zwanzig Severity | GitHub Severity |
|------------------|-----------------|
| `hint`           | `notice`        |
| `warning`        | `warning`       |
| `error`          | `error`         |

### Implementation Tasks

1. **Create formatter** (`src/formatters/github.zig`):
   ```zig
   pub fn format(diagnostics: []const Diagnostic, writer: anytype) !void {
       for (diagnostics) |diag| {
           const severity = switch (diag.severity) {
               .hint => "notice",
               .warning => "warning",
               .@"error" => "error",
           };
           try writer.print("::{s} file={s},line={d},col={d},title={s}::{s}\n", .{
               severity,
               diag.file_path,
               diag.line,
               diag.column,
               diag.rule,
               diag.message,
           });
       }
   }
   ```

2. **Register in CLI** (`src/cli/args.zig`):
   - Add `github` and `gh` as valid format options
   - Map to github formatter

3. **Document** in `docs/OUTPUT.md`:
   - Add GitHub format section
   - Show example workflow usage

### Example Workflow Usage

```yaml
- name: Run zwanzig
  run: zwanzig --format github src/
```

---

## JSON Schema for Configuration

Create `zwanzig.schema.json` for IDE autocompletion and validation.

### Schema Location

Place at repository root: `zwanzig.schema.json`

### Schema Content

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/forketyfork/zwanzig/blob/main/zwanzig.schema.json",
  "title": "Zwanzig Configuration",
  "description": "Configuration file for the zwanzig Zig static analyzer",
  "type": "object",
  "definitions": {
    "commonRuleConfig": {
      "type": "object",
      "properties": {
        "severity": {
          "type": "string",
          "enum": ["error", "warning", "hint", "off"],
          "description": "Override the default severity for this rule"
        },
        "exclude_tests": {
          "type": "boolean",
          "description": "Skip checking inside test blocks"
        },
        "exclude_files": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Glob patterns for files to skip"
        }
      }
    }
  },
  "properties": {
    "$schema": {
      "type": "string",
      "description": "JSON Schema reference"
    },
    "enabled_rules": {
      "type": "array",
      "description": "Rules to enable (allowlist mode). Mutually exclusive with disabled_rules.",
      "items": {
        "type": "string"
      }
    },
    "disabled_rules": {
      "type": "array",
      "description": "Rules to disable (blocklist mode). Mutually exclusive with enabled_rules.",
      "items": {
        "type": "string"
      }
    },
    "rules": {
      "type": "object",
      "description": "Per-rule configuration options",
      "properties": {
        "unsafe-undefined": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "allowed_types": {
                  "type": "array",
                  "items": { "type": "string" },
                  "default": ["ThreadPool", "Thread.Pool"],
                  "description": "Type names allowed to use undefined"
                },
                "allow_arrays": {
                  "type": "boolean",
                  "default": true,
                  "description": "Allow array-typed variables to use undefined"
                }
              }
            }
          ]
        },
        "no-print": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" }
          ]
        },
        "no-panic": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "allowed_messages": {
                  "type": "array",
                  "items": { "type": "string" },
                  "default": [],
                  "description": "Panic messages to allow"
                }
              }
            }
          ]
        },
        "line-length": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "max_length": {
                  "type": "integer",
                  "minimum": 1,
                  "default": 120,
                  "description": "Maximum line length in columns"
                }
              }
            }
          ]
        },
        "field-ordering": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "order": {
                  "type": "string",
                  "enum": ["ascending", "descending"],
                  "default": "ascending",
                  "description": "Field ordering direction"
                },
                "exclude_packed": {
                  "type": "boolean",
                  "default": true,
                  "description": "Skip packed structs"
                },
                "exclude_extern": {
                  "type": "boolean",
                  "default": true,
                  "description": "Skip extern structs"
                }
              }
            }
          ]
        },
        "import-ordering": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "order": {
                  "type": "string",
                  "enum": ["ascending", "descending"],
                  "default": "ascending",
                  "description": "Ordering within groups"
                },
                "require_groups": {
                  "type": "boolean",
                  "default": false,
                  "description": "Require blank lines between import groups"
                }
              }
            }
          ]
        },
        "max-params": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "max_count": {
                  "type": "integer",
                  "minimum": 1,
                  "default": 5,
                  "description": "Maximum allowed parameters"
                },
                "exclude_extern": {
                  "type": "boolean",
                  "default": true,
                  "description": "Skip extern functions"
                }
              }
            }
          ]
        },
        "no-magic-numbers": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "allowed_values": {
                  "type": "array",
                  "items": { "type": "integer" },
                  "default": [-1, 0, 1, 2],
                  "description": "Numbers that are always allowed"
                },
                "ignore_functions": {
                  "type": "array",
                  "items": { "type": "string" },
                  "default": [],
                  "description": "Function names where magic numbers are allowed"
                }
              }
            }
          ]
        },
        "require-braces": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "if_else": {
                  "type": "string",
                  "enum": ["always", "multi_line_only", "off"],
                  "default": "always"
                },
                "while": {
                  "type": "string",
                  "enum": ["always", "multi_line_only", "off"],
                  "default": "always"
                },
                "for": {
                  "type": "string",
                  "enum": ["always", "multi_line_only", "off"],
                  "default": "always"
                },
                "defer": {
                  "type": "string",
                  "enum": ["always", "multi_line_only", "off"],
                  "default": "always"
                },
                "catch": {
                  "type": "string",
                  "enum": ["always", "multi_line_only", "off"],
                  "default": "always"
                }
              }
            }
          ]
        },
        "allocator-first-param": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "ignore": {
                  "type": "array",
                  "items": { "type": "string" },
                  "default": [],
                  "description": "Function names to ignore"
                }
              }
            }
          ]
        },
        "explicit-error-sets": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "allow_private": {
                  "type": "boolean",
                  "default": true,
                  "description": "Allow inferred errors in non-pub functions"
                },
                "allow_anyerror": {
                  "type": "boolean",
                  "default": false,
                  "description": "Allow anyerror"
                }
              }
            }
          ]
        },
        "no-hidden-allocations": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "detect_page_allocator": {
                  "type": "boolean",
                  "default": true
                },
                "detect_c_allocator": {
                  "type": "boolean",
                  "default": true
                },
                "detect_gpa": {
                  "type": "boolean",
                  "default": true
                }
              }
            }
          ]
        },
        "require-doc-comment": {
          "allOf": [
            { "$ref": "#/definitions/commonRuleConfig" },
            {
              "properties": {
                "public_only": {
                  "type": "boolean",
                  "default": true,
                  "description": "Only require for pub declarations"
                },
                "require_for_fields": {
                  "type": "boolean",
                  "default": false,
                  "description": "Also require for struct fields"
                }
              }
            }
          ]
        }
      },
      "additionalProperties": {
        "allOf": [
          { "$ref": "#/definitions/commonRuleConfig" },
          { "type": "object" }
        ],
        "description": "Configuration for other rules"
      }
    },
    "max_worklist_steps": {
      "type": "integer",
      "minimum": 1,
      "default": 50000,
      "description": "Maximum worklist steps per engine run"
    },
    "max_states_per_point": {
      "type": "integer",
      "minimum": 1,
      "default": 10,
      "description": "Maximum unique states per CFG point"
    },
    "use_widening": {
      "type": "boolean",
      "default": true,
      "description": "Enable loop-header widening for convergence"
    },
    "resource_models": {
      "type": "array",
      "description": "Custom resource acquisition/release patterns",
      "items": {
        "type": "object",
        "required": ["kind"],
        "properties": {
          "kind": {
            "type": "string",
            "enum": ["alloc", "free", "open", "close"],
            "description": "Resource operation type"
          },
          "method_name": {
            "type": "string",
            "description": "Method name to match"
          },
          "receiver_type": {
            "type": "string",
            "description": "Type of the receiver object"
          },
          "return_type": {
            "type": "string",
            "description": "Return type of the function"
          },
          "fqn": {
            "type": "string",
            "description": "Fully-qualified name pattern"
          }
        }
      }
    }
  },
  "additionalProperties": false
}
```

### Implementation Tasks

1. **Create schema file**: `zwanzig.schema.json` at repository root

2. **Update sample config** (`docs/zwanzig.sample.json`):
   ```json
   {
     "$schema": "./zwanzig.schema.json",
     "enabled_rules": ["empty-catch-engine", "dupe-import"],
     ...
   }
   ```

3. **Document schema usage** in `docs/CONFIG.md`:
   - How to reference schema in config files
   - IDE integration (VS Code, etc.)

4. **Optional: Generate schema** from Zig types:
   - Consider generating schema from config struct definition
   - Ensures schema stays in sync with code

---

## Implementation Priority

### Phase 1: Quick Wins (Low Complexity)
1. `empty-file` - Empty file detection
2. `no-print` - Debug print detection
3. `no-unresolved` - Missing import file detection
4. `no-catch-return` - Redundant catch-return pattern
5. `no-return-try` - Redundant return-try pattern
6. `no-orelse-unreachable` - Prefer `.?` over `orelse unreachable`
7. `no-panic` - Panic usage detection
8. `line-length` - Line length limit
9. `switch-else-last` - Else branch ordering
10. `max-params` - Parameter count limit

### Phase 2: Style Rules (Low-Medium Complexity)
11. `allocator-first-param` - Allocator parameter position
12. `field-ordering` - Struct/enum field ordering
13. `import-ordering` - Import statement ordering
14. `require-braces` - Brace requirements
15. `require-doc-comment` - Documentation requirements

### Phase 3: Infrastructure
16. Per-rule configuration support (severity, exclude_tests, exclude_files)
17. GitHub output format
18. JSON Schema for config validation

### Phase 4: Medium Complexity Rules
19. `unsafe-undefined` - Undefined usage detection
20. `homeless-try` - Try in non-error context
21. `duplicate-case` - Duplicate switch cases
22. `avoid-as` - Unnecessary @as usage
23. `no-magic-numbers` - Magic number detection
24. `no-commented-code` - Commented-out code detection
25. `no-deprecated` - Deprecated usage detection
26. `explicit-error-sets` - Inferred error union detection
27. `no-hidden-allocations` - Hidden allocation detection

### Phase 5: High Complexity Rules
28. `must-return-ref` - Capacity-type copy detection
29. `useless-error-return` - Unused error return detection
30. `returned-stack-reference` - Stack pointer escape detection

---

## Summary

| Category | Count |
|----------|-------|
| New Rules | 27 |
| Config Extensions | 1 (per-rule options with common fields) |
| Output Formats | 1 (GitHub) |
| Tooling | 1 (JSON Schema) |
| **Total Tasks** | **30** |

### Rules by Category

| Category | Rules |
|----------|-------|
| **Correctness** | `no-unresolved`, `homeless-try`, `returned-stack-reference` |
| **Error Handling** | `no-catch-return`, `no-return-try`, `useless-error-return`, `explicit-error-sets` |
| **Restriction** | `no-panic`, `no-print`, `unsafe-undefined`, `no-hidden-allocations` |
| **Suspicious** | `must-return-ref`, `duplicate-case`, `no-deprecated` |
| **Pedantic** | `no-orelse-unreachable`, `avoid-as` |
| **Style** | `empty-file`, `line-length`, `allocator-first-param`, `field-ordering`, `import-ordering`, `switch-else-last`, `require-braces`, `require-doc-comment`, `no-commented-code`, `no-magic-numbers`, `max-params` |
