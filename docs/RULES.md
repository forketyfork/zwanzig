# Rules and checkers

Zwanzig has AST/token rules (legacy `Rule` interface) and checker-based passes (`Checker` interface). Both share the same namespace for `--do`/`--skip` filtering.

## Rules (Rule interface)

### dupe-import

Flags duplicate `@import` statements that repeat the same full import path (module string plus any chained field access), usually from copy-paste mistakes or forgotten refactoring.

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

Finds TODO comments in line, doc (`///`, `//!`), and block (`/* */`) comments. Matching is case-insensitive (`TODO`, `todo`, etc.).

**Example:**
```zig
fn processData(data: []const u8) void {
    // TODO: implement error handling
    _ = data;
}
```

Produces a hint with the TODO's message. If no message is provided (e.g. `// TODO:`), the rule reports a default message.

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

Detects unused container-level `const`, `var`, and `fn` declarations that aren't exported. The check is conservative:
- Exported (`pub`) declarations are ignored (they may be used externally)
- `export` and `extern` declarations are ignored (they may be used by other compilation units)
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

### unused-parameter

Detects function parameters that are never referenced.

- Parameters starting with `_` are ignored (explicit opt-out)

**Bad:**
```zig
fn add(unused: i32, value: i32) i32 {
    return value + 1;
}
```

**Good:**
```zig
fn add(value: i32) i32 {
    return value + 1;
}
```

### unreachable-code

Detects code after an unconditional terminator (`return`, `unreachable`) or after fully terminating branches (`if`, `switch`, `while`).

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

Flags empty `defer {}` blocks.

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

Flags empty `errdefer {}` blocks.

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

Detects variable shadowing across scopes, including payloads (if/for/while/switch/catch/errdefer).

Notes:
- Underscore-prefixed identifiers (e.g. `_x`, `_unused`) are ignored and may intentionally shadow.

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

### sentinel-alloc

Detects sentinel-terminated allocations that cause memory mismatch bugs when freed.

Sentinel-terminated allocations (e.g., `[:0]u8`) allocate `len + 1` bytes but the slice length is `len`. If stored in a non-sentinel type (`[]u8`), the sentinel info is lost and freeing causes an allocation size mismatch.

**Bad:**
```zig
fn readFile(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    // dupeZ allocates len+1 bytes but returns [:0]u8
    // If stored as []u8, freeing loses the +1 byte info
    const content = try allocator.dupeZ(u8, "hello");
    return content; // Type erased to []u8, size mismatch on free
}
```

**Good:**
```zig
fn readFile(allocator: std.mem.Allocator, file: std.fs.File) ![:0]u8 {
    // Preserve the sentinel type
    const content = try allocator.dupeZ(u8, "hello");
    return content;
}

// Or use non-sentinel allocation if sentinel isn't needed
fn readFileNoSentinel(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const content = try allocator.dupe(u8, "hello");
    return content;
}
```

Detected functions:
- `dupeZ` - always creates null-terminated copy
- `allocSentinel` - always creates sentinel-terminated allocation
- `allocPrintSentinel` - always creates sentinel-terminated string
- `allocWithOptions` with non-null sentinel parameter
- `readToEndAllocOptions` with non-null sentinel parameter

### return-local-ptr

Detects functions that return slices or pointers derived from local stack buffers. This catches use-after-return bugs where the returned data points to memory that becomes invalid when the function returns. The rule only reports when the function’s return type is a pointer/slice (including optional or error-union wrappers).

The rule uses heuristics to detect the pattern:
1. A local array variable is declared (e.g., `var buf: [N]T = undefined;`)
2. Its address is passed to a function call (`&buf`)
3. The result of that call (or a field of it) is returned
4. Or the local buffer itself is returned as a pointer/slice (e.g., `return &buf` or `return buf[0..]`)

**Bad:**
```zig
fn getMembers(tree: *const Ast, node_idx: u32) ?[]const Node.Index {
    var buf: [2]Node.Index = undefined;  // Local buffer on stack
    // containerDeclTwo fills buf and returns struct with .members pointing to buf
    return tree.containerDeclTwo(&buf, node_idx).ast.members;  // Dangling pointer!
}
```

**Good:**
```zig
fn getMembers(tree: *const Ast, node_idx: u32, buf: *[2]Node.Index) ?[]const Node.Index {
    // Buffer passed from caller, stays alive after return
    return tree.containerDeclTwo(buf, node_idx).ast.members;
}

// Caller:
var buf: [2]Node.Index = undefined;
const members = getMembers(tree, node_idx, &buf);
```

This rule complements `stack-escape-engine` by catching patterns where the escape happens through an intermediate function call that the dataflow analysis can't track.

### identifier-style

Enforces Zig naming conventions:

- Types: PascalCase
- Functions: camelCase
- Variables/constants/parameters/payloads: snake_case (lowercase); SCREAMING_SNAKE_CASE only when mirroring established external conventions (e.g., `std.posix.ENOENT`)
- Namespaces/modules declared as `const` structs may use lowercase (e.g., `std.mem`)
- Quoted identifiers (e.g., `@"weird-name"`) are exempt from these checks
- When type info is available, type aliases and function type aliases are treated as types and should use PascalCase; heuristics also treat C-style `*_t` aliases as types (lowercase `*_t` names are allowed when mirroring external conventions like `fd_t`)

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

## Checkers (Checker interface)

### unreachable-code-engine

Detects path-sensitive unreachable code where the condition is a compile-time constant. Complements `unreachable-code` by handling constant `true`/`false` conditions (including const boolean identifiers and constant expressions like `(1 + 1) == 2`). Only reports when the condition is definitely constant.

**Bad:**
```zig
fn foo() i32 {
    if (false) {
        return 1;  // Unreachable - condition is always false
    }
    return 0;
}

fn bar() i32 {
    if (true) {
        return 1;
    } else {
        return 0;  // Unreachable - condition is always true
    }
}

fn baz() void {
    while (false) {
        doWork();  // Unreachable - loop never executes
    }
}
```

**Good:**
```zig
fn foo(condition: bool) i32 {
    if (condition) {
        return 1;
    }
    return 0;
}
```

### optional-unwrap

Flags forced optional unwraps using `.?`, which panic at runtime if the value is `null`. Prefer handling the optional with `if (opt) |value|` or `orelse`.

**Bad:**
```zig
fn readConfig(opt: ?[]const u8) []const u8 {
    return opt.?; // Panics if opt is null
}
```

**Good:**
```zig
fn readConfig(opt: ?[]const u8) []const u8 {
    return opt orelse "default";
}
```

#### Recognized safe patterns

The checker uses flow analysis to recognize patterns where the optional is non-null before the unwrap. These **do not produce warnings**:

**Null check guard:**
```zig
if (opt != null) {
    const value = opt.?;  // Safe: guarded by null check
}
```

**Early return guard:**
```zig
if (opt == null) {
    return null;
}
const value = opt.?;  // Safe: null case already returned
```

**Compound null check:**
```zig
if (a == null or b == null) {
    return null;
}
const sum = a.? + b.?;  // Safe: both guarded
```

**Short-circuit evaluation:**
```zig
// Safe: .? only evaluated when opt is non-null
return opt != null and opt.? == expected;
return opt == null or opt.? != expected;
```

**Ternary if expression:**
```zig
const value = if (opt != null) opt.? else 0;  // Safe: then branch guarded
```

**Lazy initialization:**
```zig
if (self.cached == null) {
    self.cached = computeValue();
}
return &self.cached.?;  // Safe: initialized above if null
```

**Payload capture:**
```zig
if (opt) |value| {
    _ = value;  // Safe: payload binding
}
```

**Debug assertion guard:**
```zig
std.debug.assert(opt != null);
const value = opt.?;  // Safe: assert guarantees non-null
```

**Switch null-case guard:**
```zig
switch (opt) {
    null => return null,
    else => |value| _ = value,
}
const value = opt.?;  // Safe: null path returned
```

**Comptime type expressions:**
```zig
// Safe: evaluated at compile time, fails as compile error not runtime panic
const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
```

**Method call with catch guard:**
```zig
fn render(self: *Self) void {
    self.ensureTexture() catch return;  // Returns early if texture init fails
    draw(self.texture.?);  // Safe: ensureTexture assigns self.texture on success
}
```

**Try-assign guard:**
```zig
self.path = try allocator.dupe(u8, input);
const basename = getBasename(self.path.?);  // Safe: try succeeded, so path is non-null
```

**Labeled block invariant:**
```zig
const should_process = blk: {
    const value = opt orelse break :blk false;  // Break with false if null
    break :blk value.isValid();
};
if (should_process) {
    use(opt.?);  // Safe: should_process=true implies opt was non-null
}
```

### divide-by-zero-engine

Detects integer division/modulo expressions where the denominator can be zero on at least one reachable path.

The checker is path-sensitive and tracks:
- constant literals
- variable assignments of literal/range-like values
- branch constraints such as `x == 0`, `x != 0`, `x > 0`, `x <= -1`
- mixed-path outcomes (reports "possible" when some paths are safe and some are unsafe)

Supported operations:
- binary operators: `/` and `%`
- builtins: `@divTrunc`, `@divFloor`, `@divExact`, `@mod`, `@rem`

**Bad:**
```zig
fn badLiteral() i32 {
    return @divTrunc(10, 0); // division by zero
}

fn badPathSensitive(x: i32) i32 {
    if (x == 0) {
        return @mod(10, x); // modulo by zero on this branch
    }
    return 0;
}
```

**Good:**
```zig
fn goodGuarded(x: i32) i32 {
    if (x != 0) {
        return @divTrunc(10, x); // guarded non-zero denominator
    }
    return 0;
}
```

### empty-catch-engine

Detects empty `catch {}` blocks.

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

### store-violations-engine

Detects allocator/resource misuse: double-free, free-without-alloc, close-without-open, use-after-free/close, and leaks.

**Error-path leak policy:** Leak checks run only on normal return paths. When a function returns an error (detected by literal error values or type-based analysis), leak reports are suppressed. This avoids false positives in code that cleans up via `errdefer`.

**Tracking scope:** The rule only tracks resources created by known alloc/open APIs (including built-in models for common std allocator and file/posix patterns). Closing a value that was not opened by a tracked API is reported as "close without tracked open". This includes manually constructed handles (for example, `std.fs.File{ .handle = fd }`) or values provided by external code, unless you model ownership with `resource_models`.

**Diagnostics per path:** When multiple control-flow paths violate the rule, multiple diagnostics can be emitted for the same source line.

Resources stored in aggregates are treated as escaping with the aggregate.

**Resource modeling:** Built-in allocator detection includes `alloc`/`free`, `dupe`, and `create`/`destroy`. Configurable `resource_models` can add project-specific APIs. `kind: "free_owned"` models APIs like `deinit` that free resources owned by a value without freeing the value itself.

**Bad:**
```zig
fn foo(allocator: std.mem.Allocator) !void {
    var ptr = try allocator.alloc(u8, 1);
    allocator.free(ptr);
    allocator.free(ptr); // double-free
}
```

### stack-escape-engine

Detects stack-backed pointers/slices that escape the current function scope or async/thread lifetime.

Key patterns:
- Stack array literals (e.g., `&.{ "open", owned_url }`) captured into a long-lived value
- Values captured into detached threads without a guaranteed `join()`
- Returning values that contain stack-backed references
- Escape is reported if any path proves a stack-backed origin can reach a capture sink

**Bad:**
```zig
fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    const child = std.process.Child.init(&.{ "open", owned_url }, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ child });
    thread.detach(); // child carries stack-backed argv
}
```

**Good:**
```zig
fn openUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const owned_url = try allocator.dupe(u8, url);
    var argv = try allocator.alloc([]const u8, 2);
    argv[0] = "open";
    argv[1] = owned_url;
    const child = std.process.Child.init(argv, allocator);
    const thread = try std.Thread.spawn(.{}, openUrlThread, .{ child });
    thread.join(); // join guarantees thread completion before return
}
```

Built-in escape models:
- `std.process.Child.init` captures `argv` into the returned `Child`
- `std.Thread.spawn` captures its argument tuple into the spawned thread

Config:
- `escape_models`: custom escape/capture rules
- `escape_max_depth`: helper call depth for origin tracking (default: 3)
- `resource_models` of kind `alloc` are used to treat allocator-backed values as heap

Notes:
- `try std.Thread.spawn(...)` ignores the `try_error` edge when checking join guarantees (no thread is created on the error path).
- Joining must be guaranteed on all paths; a join in only some branches still reports an escape.
- Capturing allocator-backed or static data does not trigger this rule.
