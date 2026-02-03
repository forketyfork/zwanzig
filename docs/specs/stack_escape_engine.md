# Stack Escape Engine Checker Spec

## Summary
Add a new engine-based checker, `stack-escape-engine`, that detects stack-backed
pointers/slices escaping the current function scope or async/thread lifetime.
The initial target is the Architect bug pattern:

- stack-allocated argv array literal (`&.{ ... }`) passed to
  `std.process.Child.init`
- `Child` passed to `std.Thread.spawn`
- thread is detached or not provably joined

The checker should emit a single diagnostic with two source locations:
the capture site (primary) and the origin site (secondary).

## Goals
- Catch stack-backed pointer/slice escapes into:
  - returned values
  - stored values (container or captured by return/receiver/global)
  - thread/async lifetimes
- Use AST patterns for origin tracking, with ZIR when available to avoid false
  positives on compile-time array literals
- Provide configurable escape models in `.zwanzig.json`
- Hard-code a minimal stdlib list in v1

## Non-goals
- Precise lifetime analysis across arbitrary interprocedural flows
- Full escape analysis for heap-backed ownership correctness
- Cross-file flow tracking (initially in-file)

## Terminology
- Origin: where a value was created (stack temp, static, heap, unknown)
- Escape: a use that causes the value to outlive the current function scope
- Capture site: the call or return where the escape happens
- Origin site: the AST node where the stack-backed value is formed

## Rule Identity
- Rule id: `stack-escape-engine`
- Severity: `err`

## Detection Overview
We track origins for values (variables and expressions) and report when a
stack-backed origin reaches a configured escape sink.

High-level flow (per function):
1. Build CFG and analyze calls and assignments.
2. Track origins for expressions and variables.
3. Detect escape sinks and apply models.
4. If a stack origin reaches an escape sink, emit a diagnostic with
   capture-site and origin-site locations.

## Origin Classification

### Stack-backed (definite)
Mark an expression as stack-backed if it is:
- `&.{ ... }`, `&[_]T{ ... }`, `&[N]T{ ... }` with any non-comptime element
- `&local_array`, `&local_struct`, or slice derived from a local array
- Slice derived from the above (e.g., `buf[0..]`)

### Static (safe)
Mark as static if:
- Address-of array literal where all elements are compile-time constants
  (string literal, number literal, enum literal, `comptime` param, or ZIR-proven
  constant)
- Address-of global constants or globals with static storage

### Heap (safe)
Mark as heap if derived from:
- allocator calls (recognized by existing resource models or common std patterns)
- `std.heap` or known allocator APIs

### Unknown
Fallback when origin cannot be inferred. Unknown should not trigger diagnostics
unless the origin is later proven stack-backed by propagation.

### ZIR usage
If type info is available, use ZIR to determine compile-time literals for array
elements. If ZIR is unavailable, fall back to AST heuristics.

## Propagation Rules
Track origin through:
- assignments and variable declarations
- simple field access and indexing
- struct/array initializers (propagate element origins)
- slices and `@ptrCast`-like wrappers
- address-of and deref

Propagation should be depth-limited through helper calls (see below).

## Escape Sinks and Models
Escape behavior is modeled via:
- Hard-coded stdlib models (v1)
- Config-driven models in `.zwanzig.json`

Each escape model specifies:
- `fqn`: fully qualified name (highest priority)
- `method_name`: function or method name
- `receiver_type`: receiver type for method calls
- `param_indices`: which arguments are captured (0-based)
- `captures_into`: one of `return`, `receiver`, `global`, `thread`

Capture semantics:
- `return`: argument is stored in the returned value
- `receiver`: argument is stored in the receiver (like `list.append`)
- `global`: argument is stored in global/static storage
- `thread`: argument is captured by an async/thread and may outlive scope

## Thread Heuristics
`captures_into = thread` is an escape unless the analysis can prove that
`join()` is called on all paths to function exit for the thread value.

Best-effort definition of "join guaranteed":
- `join()` post-dominates the spawn call in the CFG
- no `detach()` is called on the thread value before `join()`

If post-dominator calculation is not available, use a conservative
approximation:
- Compute all paths from spawn to any exit; if any path lacks `join()`, treat as
  escape

## Interprocedural Depth
Track through helper functions up to a configurable depth.
- Default: 3
- Depth counts only direct helper calls
- Struct/field wrapping does not increase depth

Implementation note:
- Use function summaries or shallow inlining to propagate origins through small
  wrappers.
- If the depth limit is exceeded, stop propagating and treat origin as unknown.

## Hard-coded stdlib models (v1)
- `std.process.Child.init`:
  - `param_indices = [0]`, `captures_into = return`
- `std.Thread.spawn`:
  - `param_indices = [2]` (argument tuple), `captures_into = thread`

Note: we keep this minimal initially; all other models should be defined via
config.

## Config Schema (in .zwanzig.json)
Add a new top-level field:

```
"escape_models": [
  {
    "fqn": "std.process.Child.init",
    "param_indices": [0],
    "captures_into": "return"
  },
  {
    "method_name": "append",
    "receiver_type": "std.ArrayList",
    "param_indices": [0],
    "captures_into": "receiver"
  }
]
```

Rules:
- `fqn` takes precedence when present.
- At least one of `fqn`, `method_name`, or `receiver_type` must be present.
- `captures_into` is required.

## Diagnostics
Single diagnostic with two locations:
- Primary: capture site (call or return)
- Secondary: origin site (stack allocation / literal)

Suggested message:
"Stack-backed value escapes via <capture>, origin at <line:col>."

Implementation requires extending `Diagnostic` to carry an optional secondary
location, and updating formatters (text/json/sarif) accordingly. SARIF should
map secondary location to `relatedLocations`.

## Tests
Add fixtures under `test/fixtures/stack_escape_engine/`:
- `child_init_thread_detach.zig` (positive)
- `argv_in_thread_ok.zig` (negative)
- `static_argv_ok.zig` (negative)
- `heap_argv_ok.zig` (negative)
- `thread_join_ok.zig` (negative)
- `helper_wrap_depth_ok.zig` (depth limit)

Wire in fixture runner test under `test/fixture_tests.zig`.

## Documentation
- Update `docs/RULES.md` with the new checker, scope, and config.
- Update `README.md` with a brief mention of the new checker.

## Rollout
- Default enabled, same as other engine checkers.
- If too noisy, allow suppressions via existing suppression mechanism.
