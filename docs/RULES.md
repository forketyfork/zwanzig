# Rules and Checkers

Zwanzig ships with AST/token rules (legacy `Rule` interface) and checker-based passes (new `Checker` interface). Rules and checkers share the same namespace for `--do`/`--skip` filtering.

## Rules (Rule interface)

### dupe-import

Flags duplicate `@import` statements. These often signal copy-paste mistakes or forgotten refactoring.

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

Finds `// TODO` comments so you can track unfinished work.

**Example:**
```zig
fn processData(data: []const u8) void {
    // TODO: implement error handling
    _ = data;
}
```

This produces a hint pointing to the TODO with its message.

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

Detects unused container-level `const`, `var`, and `fn` declarations that aren't exported.

The check is conservative:
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

### optional-unwrap

Flags forced optional unwraps using `.?`, which panic at runtime if the value is `null`. Prefer handling the optional with `if (opt) |value|` or `orelse` to make the null case explicit.

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

#### Guarded patterns recognized

The checker uses flow analysis to recognize patterns where the optional is proven non-null before the unwrap. These safe patterns **do not produce warnings**:

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

### unreachable-code

Detects code that can never execute after an unconditional terminator (e.g., `return`) or after fully terminating branches (`if`, `switch`, `while`).

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

Flags empty `defer {}` blocks that serve no purpose.

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

Flags empty `errdefer {}` blocks that don't clean up anything.

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

Detects variable shadowing across scopes (including payloads) to avoid accidental name reuse.

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

Detects sentinel-terminated allocations that can cause memory mismatch bugs when freed.

Sentinel-terminated allocations (e.g., `[:0]u8`) allocate `len + 1` bytes but the slice length is `len`. If the slice is stored in a non-sentinel type (e.g., `[]u8`), the sentinel info is lost and freeing will cause an allocation size mismatch.

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

### identifier-style

Enforces Zig naming conventions:

- Types: PascalCase
- Functions: camelCase
- Variables/constants/parameters/payloads: snake_case (lowercase); SCREAMING_SNAKE_CASE only when mirroring established external conventions (e.g., `std.posix.ENOENT`)
- When type info is available, type aliases and function type aliases are treated as types and should use PascalCase; heuristics also treat C-style `*_t` aliases as types

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

Detects path-sensitive unreachable code where the condition is a compile-time constant. This checker complements `unreachable-code` by handling constant `true`/`false` conditions (including const boolean identifiers). It only reports when the condition is definitely constant.

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

### empty-catch-engine

Detects empty `catch {}` blocks that silently swallow errors.

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

Detects allocator/resource misuse based on the store model, including double-free, free-without-alloc, close-without-open, use-after-free/close, and leak violations.

**Error-Path Leak Policy:** Leak checks run only on normal (non-error) return paths. When a function returns an error (detected by literal error values like `return error.OutOfMemory` or by type-based analysis of error union returns), leak reports are suppressed on that path. This prevents false positives in code that follows the Zig idiom of cleaning up in `errdefer` blocks.

Resources stored in aggregates are treated as escaping with the aggregate.

**Bad:**
```zig
fn foo(allocator: std.mem.Allocator) !void {
    var ptr = try allocator.alloc(u8, 1);
    allocator.free(ptr);
    allocator.free(ptr); // double-free
}
```
