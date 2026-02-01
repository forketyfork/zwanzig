# Task: Store Violations Engine Precision Improvements

Overview: Improve error-path classification for return expressions, add type-based open detection, and introduce a configurable model table that complements type inference. The goal is to reduce false positives without losing coverage for standard library and user-defined APIs.

## Step 1: Extend type access for expression and call nodes

### Status Quo
- `TypeContext.getNodeType` only resolves decl nodes via `ZirBridge`.
- `CfgBuilder` annotates type info on var declarations, not on call/return expressions.
- `AnalysisEngine` cannot reliably ask for expression types at return sites or call sites.

### Objectives
- Enable the analyzer to query the type of return expressions and call expressions.
- Make type info available to `AnalysisEngine` without re-parsing or ad hoc AST walking.

### Tech Notes
- Add a TypeContext API to resolve expression node types (call expressions and return expressions) using ZIR, not just decl nodes.
- Consider caching by AST node index to avoid repeated ZIR lookups.
- Ensure the API is safe to call when type info is unavailable (returns null).

### Acceptance Criteria
- A new TypeContext method can return a `TypeInfo` for a call expression AST node.
- Unit test demonstrates a call expression whose return type is resolved correctly.

## Step 2: Mark error returns by type (not just literals)

### Status Quo
- Error paths are marked for `try`/`catch` edges and literal `return error.Foo`.
- `return err;` and `return someFn();` (error-union returns) are treated as normal paths.

### Objectives
- Mark a path as `error_active` when returning an error-union expression, not only literal error values.
- Reduce false positives in leak reporting on error paths.

### Tech Notes
- In `AnalysisEngine.transferFunction` under `.ret`, inspect the return expression type via the new TypeContext API.
- If the return expression type is an error union, set `new_state` to `error_active`.
- Keep the existing literal error handling as a fast path.

### Acceptance Criteria
- New unit test: `return err;` inside an error union function sets error state.
- New unit test: `return someFn();` where `someFn` returns error union sets error state.
- No regression in existing store-violations fixtures.

## Step 3: Type-based open detection

### Status Quo
- `resolveResourceCallFromCall` identifies opens by name and base (`posix`, `std.posix`, `std.fs`).
- User-defined `open()` can still be misclassified in edge cases.

### Objectives
- Prefer type info over name heuristics for open detection.
- Keep the existing heuristics as a fallback when type info is unavailable.

### Tech Notes
- For call expressions, use the new TypeContext API to read the return type.
- Treat a call as `open` if its return type matches a known resource type (e.g., `std.fs.File`, `std.posix.fd_t`) or a configured resource “open” type.
- Only use the name-based heuristic when type info is missing.

### Acceptance Criteria
- `fp_open_close_fields.zig` remains clean without name-based false positives.
- A targeted test where a call returns `std.fs.File` or `std.posix.fd_t` is classified as open even if the method name is non-standard.

## Step 4: Add a config-driven resource model table

### Status Quo
- Resource APIs are hardcoded in `resolveResourceCallFromCall`.
- There is no user-configurable way to model custom alloc/open/close/free functions.

### Objectives
- Allow users to define resource acquisition/release patterns without code changes.
- Combine config-driven models with type-based detection.

### Tech Notes
- Extend the config schema to include resource models (e.g., `alloc`, `free`, `open`, `close`, plus optional type filters).
- Define matching rules by fully-qualified name, method name + receiver type, or return type.
- Resolution order: config-driven models → type-based detection → fallback heuristics.
- Ensure model lookup is fast (precompile patterns).

### Acceptance Criteria
- A test config models a custom `MyPool.open()` / `MyPool.close()` pair and is detected correctly.
- Default behavior remains unchanged when no model config is provided.

## Step 5: Document policy and update diagnostics guidance

### Status Quo
- `README.md` mentions store-violations-engine but not the new type/config modeling or error-return behavior.

### Objectives
- Make the analyzer’s leak policy and modeling hierarchy explicit.
- Document how to configure custom resource models.

### Tech Notes
- Update `README.md` and `docs/IMPLEMENTATION.md` with:
  - Error-path leak policy.
  - Type-based detection behavior.
  - Config model table format and precedence.

### Acceptance Criteria
- Documentation describes the model resolution order and configuration options.
- Clear guidance on when leaks are reported and why.
