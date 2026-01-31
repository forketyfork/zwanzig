# Feature: Engine Type Metadata Tracking (Sentinel Coercion)

Extend the analysis engine to carry type metadata (including sentinel tri-state) through dataflow and summaries, and report sentinel-coercion frees via `store-violations-engine`. Typed IR is enabled automatically when any enabled checker declares `.optional` or `.required`. Parse failures become diagnostics and do not abort analysis of other files.

This plan explicitly defines under-specified behaviors, splits larger steps into smaller, testable steps, and addresses known integration gaps (state equality/hashing, error-union success type usage, catch typing, deferred semantics, and summary return propagation).

## Glossary / Definitions

- **Typed IR**: ZIR-derived type information surfaced through `TypeContext` (not full semantic analysis). Availability is per-file and may fail on parse/AstGen errors.
- **Sentinel state**: Tri-state representation of sentinel presence on slices/pointers: `.none`, `.present_unknown`, `.present_value`.
- **Sentinel coercion**: Assigning a sentinel-terminated value into a non-sentinel type, losing sentinel metadata and making `free` size-mismatched.
- **TypeInfo**: Compiler-derived type summary (kind, size, sentinel state, error-union success type).
- **TypeFlags**: Lightweight boolean flags derived from `TypeInfo` (e.g., `is_slice`, `is_pointer`, `is_optional`, `is_error_union`) used in engine metadata.
- **TypeMetadata**: Engine-level metadata wrapper that tracks `TypeFlags`, sentinel state, and coercion status; used by `AbstractValue`.
- **AbstractValue**: Engine value lattice (unknown/null/non-null/int range/etc.) extended to carry `TypeMetadata`.
- **ProgramState.return_value**: Per-state captured return value metadata for summary derivation.
- **Summary return metadata**: The merged `AbstractValue` for all return paths, computed by running the engine for the callee.

## Step 1: Parse-error diagnostics and AST pre-parse (per file)

### Status Quo
- Parsing happens lazily when rules or checkers call `Source.ast()`.
- If `Source.ast()` fails and the error propagates, file analysis aborts via `try analyzer.analyzeFile(...)`.

### Objectives
Parse the AST once up front per file. Parse errors must emit diagnostics and skip all checks for that file, while analysis continues for other files.

### Tech Notes
- In `Analyzer.analyzeFile`, call `source.ast()` before running any rules/checkers.
- On parse error:
  - If `source.ast()` fails OR the parsed tree has `errors.len > 0`, emit a diagnostic with rule id `parse-error` at line 1, column 1.
  - Skip all rules and checkers for that file.
  - Continue analyzing remaining files (no fatal error).
- Do **not** change `Source.ast()` behavior; the check lives in `Analyzer.analyzeFile`.

### Acceptance Criteria
- A file with a parse error produces a diagnostic and does not run any rules/checkers for that file.
- Analysis continues for subsequent files after a parse error.
- `just test` passes.

## Step 2: Add per-checker type requirements and respect rule filter

### Status Quo
- `CheckerContext.type_context` is optional and only populated when `Analyzer.use_typed_ir` is enabled.
- There is no checker-specific type requirement or gating.

### Objectives
Allow each checker to declare `.none`, `.optional`, or `.required` typed-IR usage, and only enable typed IR when **enabled** checkers require it.

### Tech Notes
- Add `Checker.type_requirement: enum { none, optional, required }` with default `.none`.
- In `Analyzer.analyzeFile`, pre-scan **enabled** checkers only:
  - Use `Analyzer.isRuleEnabled(chkr.name)` to respect `--do/--skip`.
  - If any enabled checker is `.optional` or `.required`, typed IR is needed for this file.
- Create a `TypeContext` only when typed IR is needed; otherwise pass `null`.
- Update `CheckerContext.createCfgBuilder` to use `initWithTypes` when `type_context` is present.

### Acceptance Criteria
- Typed IR is created only when an enabled checker requires it.
- `--do/--skip` correctly controls typed IR gating.
- `just test` passes.

## Step 3: Remove analyzer-owned ZirBridge and add explicit required-ZIR APIs

### Status Quo
- `Source.zirBridge()` lazily loads ZIR and swallows parse/AstGen failures.
- `Analyzer` owns `zir_bridge` and `use_typed_ir`.

### Objectives
Make typed IR availability explicit and remove duplicated ZIR ownership. Required checkers must fail cleanly when ZIR is unavailable, while optional checkers can proceed without it.

### Tech Notes
- Add `Source.requireZirBridge() !*const ZirBridge` that fails on parse/AstGen errors and does not swallow them.
- Add `TypeContext.ensureAvailable() !void` that calls `Source.requireZirBridge()`.
- Remove `Analyzer.zir_bridge`, `Analyzer.enableTypedIr()`, `Analyzer.getZirBridge()`, `Analyzer.use_typed_ir`, and `Analyzer.loadTypedIr()`.
- In `Analyzer.runChecksOnSource`, for each enabled checker:
  - If `type_requirement == .required`, call `type_ctx.ensureAvailable()` before running it.
  - On failure, skip only the required checker and continue with others.
  - Optional checkers can run with `TypeContext` even when unavailable (they should check `ctx.isAvailable()`).
- Update `CachedArtifacts.had_type_info` to reflect `type_ctx.isAvailable()` rather than a removed `use_typed_ir` flag.

### Acceptance Criteria
- Required checkers are skipped if `TypeContext.ensureAvailable()` fails; optional checkers still run.
- `Analyzer` no longer owns a `ZirBridge` and typed IR is enabled automatically based on checker requirements.
- `just test` passes.

## Step 4: Remove typed-IR fallback in CfgBuilder

### Status Quo
- `CfgBuilder.annotateWithType` falls back to `Source.zirBridge()` even when `type_context` is null.

### Objectives
Ensure typed IR is only used when a checker explicitly receives a `TypeContext`.

### Tech Notes
- Remove the fallback that uses `Source.zirBridge()` when `type_context` is null.
- Leave `CfgBuilder` annotations unchanged when no `TypeContext` is provided.
- Update or add tests to confirm no type annotations are applied without `TypeContext`.

### Acceptance Criteria
- `CfgBuilder` only annotates IR nodes when `type_context` is provided.
- Tests confirm type annotations are absent when `type_context` is null.
- `just test` passes.

## Step 5: Redesign TypeInfo for sentinel tri-state and error-union success types

### Status Quo
- `TypeInfo.sentinel: ?SentinelInfo` stores only `value: i64` and collapses unknown into null.
- Error unions have no explicit success type in `TypeInfo`.

### Objectives
Preserve sentinel information precisely and represent error unions with an explicit success type. Provide stable accessors so downstream logic can unwrap error unions without relying on `type_str`.

### Tech Notes
- Replace `sentinel: ?SentinelInfo` with:
  - `sentinel: SentinelState = .none`
  - `SentinelState = union(enum) { none, present_unknown, present_value: i64 }`
- Add nested success type for error unions:
  - `error_union: ?ErrorUnionInfo = null`
  - `ErrorUnionInfo = struct { success: TypeInfo }`
  - Enforce invariant: `error_union != null` only when `kind == .error_union`.
- Add helper accessors:
  - `hasSentinel()` returns true for both present states.
  - `getErrorUnionSuccess()` returns `?TypeInfo`.
  - `getDisplayTypeStr()` returns a stable string for diagnostics/logging.
- Define `TypeInfo.initErrorUnion(success: ?TypeInfo)` or equivalent explicit constructor.

### Acceptance Criteria
- Unit tests cover all three sentinel states and error-union success type accessors.
- Invariants are enforced (error_union only for `.error_union`).
- `just test` passes.

## Step 6: Update cached artifacts serialization for new TypeInfo

### Status Quo
- Cached artifacts serialization only stores `kind`, `size_bits`, and flags.

### Objectives
Persist sentinel state, error-union success type, **and `type_str`** in cached artifacts to preserve resource detection behavior under `--cache`.

### Tech Notes
- Bump cached artifacts format version.
- Update serialization/deserialization to include:
  - Sentinel state (none/unknown/value).
  - Error-union success type, recursively serialized.
- `type_str` for all `TypeInfo` (including within error-union success).
- Add round-trip tests that include sentinel and error union success types.

### Acceptance Criteria
- Cache serialization/deserialization round-trips sentinel and error-union success type.
- `just test` passes.

## Step 7: Update TypeInfo consumers to use error_union.success

### Status Quo
- Resource detection and config matching depend on `type_str` (including error unions).

### Objectives
Use the new `error_union.success` field instead of relying on `type_str` in error unions. Preserve `type_str` as a debug string, not as a semantic dependency.

### Tech Notes
- Update resource detection and config matching to:
  - If `TypeInfo.kind == .error_union` and `error_union.success` exists, unwrap to that type for checks.
  - Otherwise fall back to existing `type_str` (if any).
- Add tests that exercise error union resource types (e.g., `std.fs.File`).

### Acceptance Criteria
- Resource detection works for `error_union` types using `success`.
- No regressions in config-driven matching.
- `just test` passes.

## Step 8: Populate new TypeInfo fields in ZirBridge

### Status Quo
- ZIR extraction only preserves sentinel value when a literal is found.
- Error union success type is not extracted.

### Objectives
Extract sentinel state and error-union success type from ZIR/AST to keep typed IR precise.

### Tech Notes
- For pointer/slice sentinel nodes:
  - If sentinel node exists but value cannot be extracted, set `.present_unknown`.
  - If no sentinel node, keep `.none`.
  - If literal value available, set `.present_value`.
- When extracting error unions, populate `TypeInfo.error_union.success`.
- Update `zir_bridge.zig` tests to cover:
  - sentinel present but unknown value
  - error-union success type extraction

### Acceptance Criteria
- New ZIR tests cover sentinel unknown vs value and error-union success type.
- `just test` passes.

## Step 9: Extend TypeContext with call-arg-aware inference and sound try/catch typing

### Status Quo
- `TypeContext.getKnownMethodReturnType` only takes a method name.
- `try`/`catch` do not use error-union success types.

### Objectives
Return sentinel-aware types and explicit error-union success types for known allocator APIs by inspecting call arguments. Ensure `try`/`catch` typing is sound.

### Tech Notes
- Extend call inference to pass the call AST node (or param list) into known-method resolution.
- For allocator methods that return slices, return `TypeInfo.initErrorUnion(TypeInfo.initSlice(...))` with sentinel state computed from call arguments.
- Methods:
  - `allocSentinel`, `dupeZ`, `allocPrintSentinel`: sentinel derived from the call argument; if literal, use `.present_value`; if non-literal, use `.present_unknown`.
  - `readToEndAllocOptions`, `allocWithOptions`: inspect sentinel argument: `null` => `.none`; literal => `.present_value`; unknown => `.present_unknown`.
- `try` typing:
  - If inner type is error union with `success`, return `success`.
  - If no success info, return `.unknown`.
- `catch` typing:
  - Compute `success` from LHS if available and `rhs` type from fallback.
  - If both are known and compatible, return a merged type; otherwise return `.unknown`.
  - Never return only success when RHS is incompatible.

### Acceptance Criteria
- Tests verify sentinel-aware `TypeInfo` for known methods, including `allocSentinel` derived from arguments.
- `try` and `catch` use error-union success types when available and degrade to unknown when types disagree.
- `just test` passes.

## Step 10: Introduce TypeMetadata and coercion semantics (explicit, testable)

### Status Quo
- No shared metadata type for engine values.
- No coercion tracking abstraction.

### Objectives
Create a reusable metadata carrier with explicit states and well-defined merge/widen/equality behavior.

### Tech Notes
- Define:
  - `TypeMetadata = union(enum) { unknown, known: KnownMetadata }`
  - `KnownMetadata = struct { flags: TypeFlags, sentinel: SentinelState, coercions: Coercions }`
  - `Coercions = struct { sentinel: CoercionState }`
  - `CoercionState = enum { no, maybe }`
- Define minimal `TypeFlags` and map from `TypeInfo`.
- Define **explicit merge/widen/equality semantics**:
  - If either side is `.unknown`, result is `.unknown`.
  - If flags differ, result is `.unknown` (avoid unsound cross-type mixing).
  - Sentinel merge:
    - none + none => none
    - present_value(x) + present_value(x) => present_value(x)
    - present_value(x) + present_value(y) (x != y) => present_unknown
    - present_unknown with any present => present_unknown
  - Coercion merge: if either is `maybe`, result is `maybe`.
- Add sentinel coercion detection helper: if RHS has sentinel and LHS does not, set `coercions.sentinel = .maybe`.

### Acceptance Criteria
- Unit tests cover sentinel coercion rules, unknown behavior, and merge/widen semantics.
- `just test` passes.

## Step 11: Add typed wrapper to AbstractValue (metadata-aware equality/hash)

### Status Quo
- `AbstractValue` only has scalar/null/range variants.
- Equality/hash/merge/widen ignore metadata.

### Objectives
Introduce typed values while ensuring metadata participates in equality/hash/merge/widen so states with different metadata do not collapse.

### Tech Notes
- Introduce `AbstractValueBase` and `TypedValue`, then add `AbstractValue.typed`.
- Update `eql`, `hash`, `merge`, `widen`, `isUnknown`, `isNull`, `isNonNull`, `toConcreteInt`:
  - For `.typed`, compare/merge both base value and metadata.
  - Do **not** drop metadata in equality/hash (prevents state dedup loss).
- Update Environment equality/hash (already uses `AbstractValue` methods).
- Add tests for typed equality, hashing, and merge/widen with mixed typed/untyped values.

### Acceptance Criteria
- New unit tests validate typed `AbstractValue` behavior and metadata-sensitive equality/hash.
- `just test` passes.

## Step 12: Preserve metadata in constraints and refinements

### Status Quo
- `ConstraintManager.refineValue` returns a new base value, dropping metadata.

### Objectives
Keep metadata when applying constraints so it is not lost during refinement.

### Tech Notes
- Update `ConstraintManager.refineValue` to refine the base and preserve metadata when the input is typed.
- Add tests that verify metadata survives int and null constraints.

### Acceptance Criteria
- Constraint refinement preserves metadata for typed values.
- `just test` passes.

## Step 13: Implement expression evaluation with metadata (isolated helper)

### Status Quo
- Engine sets `var_decl` and `assign` values to `.unknown`.
- No shared `evaluateExprValue` helper.

### Objectives
Compute `AbstractValue` (base + metadata) for expressions to propagate metadata through the environment.

### Tech Notes
- Add `evaluateExprValue(ast_node, state)`:
  - Identifiers: use current env value.
  - Literals: return concrete base values.
  - Calls:
    - If a summary is applicable, use `summary.return_value`.
    - Else, fallback to `TypeContext.getExpressionType`.
  - Type-based results: wrap in `.typed` via `TypeMetadata.fromTypeInfo`.
- Keep this helper isolated and unit-testable.

### Acceptance Criteria
- Unit tests validate `evaluateExprValue` for literals, identifiers, and calls (summary + type fallback).
- `just test` passes.

## Step 14: Propagate metadata on var_decl/assign

### Status Quo
- `.var_decl` and `.assign` set variables to `.unknown`.
- Alias propagation tracks regions but not value metadata.
- Deferred actions store only an action, not a value.

### Objectives
Propagate metadata through assignments and declarations and record sentinel coercion.

### Tech Notes
- On var decl and assign, set LHS to evaluated RHS value rather than `.unknown`.
- If LHS has an explicit declared type (from `TypeContext`), compare LHS type vs RHS metadata and mark sentinel coercion on mismatch.
- Preserve existing resource tracking and alias behavior.

### Acceptance Criteria
- Tests show metadata is preserved across aliasing assignments.
- Tests show sentinel coercion is marked when assigning sentinel value into non-sentinel type.
- `just test` passes.

## Step 15: Define deferred value semantics and invalidation rules

### Status Quo
- Deferred actions store only an action, not a value.
- Reassignments and alias rebindings do not invalidate deferred metadata.

### Objectives
Capture deferred values soundly and invalidate them on reassignment or alias rebinding to avoid stale metadata.

### Tech Notes
- When recording a deferred free/close, store the best-known value **at the defer site**.
- If the LHS variable is later reassigned, drop the stored deferred value to `.unknown` (conservative).
- If an alias is rebound, clear **both** the alias's deferred value and the original region's stored deferred value.
- This prevents stale deferred metadata from being treated as exact.

### Acceptance Criteria
- Deferred metadata is cleared on reassignment and alias rebinding and does not produce unsound positives.
- `just test` passes.

## Step 16: Track return values in ProgramState

### Status Quo
- `ProgramState` does not store return values.
- `transferFunction` inspects return expressions for error-state changes only.

### Objectives
Store return metadata in `ProgramState` so it can be merged into summaries later.

### Tech Notes
- Add `ProgramState.return_value: ?AbstractValue`.
- In `.ret`, evaluate the return expression via `evaluateExprValue` and store it in `state.return_value`.
- Update `ProgramState.eql`, `computeHash`, `clone`, and `widen` to include `return_value`.

### Acceptance Criteria
- Unit tests validate `ProgramState` equality/hash/widen with return values.
- `just test` passes.

## Step 17: Add recursion guard for summary computation

### Status Quo
- Summary computation can re-enter itself via recursive calls, with no guard.

### Objectives
Prevent infinite recursion during summary computation.

### Tech Notes
- Add a recursion guard (summary-in-progress set) to `AnalysisEngine` or `SummaryCache`.
- If a summary is already in progress, return `null` (caller falls back to `TypeContext`).

### Acceptance Criteria
- Recursion guard prevents infinite summary computation.
- `just test` passes.

## Step 18: Run dedicated engine for summary computation

### Status Quo
- `computeSummary` scans CFG only and never runs the engine.

### Objectives
Derive return metadata from engine runs for precise, reusable summaries.

### Tech Notes
- In `computeSummary`, run a dedicated `AnalysisEngine` on the callee CFG.
- Disable summary reuse for this run.
- Reuse the caller's limits/config (`TypeContext`, config, analysis limits, build metadata).

### Acceptance Criteria
- Summary engine runs complete without using other summaries.
- `just test` passes.

## Step 19: Merge summary return metadata from engine states

### Status Quo
- `FunctionSummary.return_value` is always `.unknown`.

### Objectives
Collect and merge return values from engine states into `summary.return_value`.

### Tech Notes
- Collect `return_value` from all states at return nodes and merge/widen into `summary.return_value`.
- If no return values are observed, keep `.unknown`.
- Add unit tests for multiple return statements with distinct return values.

### Acceptance Criteria
- Summary return values are derived from engine runs and merged across return paths.
- Unit tests validate summary return metadata for multiple return statements.
- `just test` passes.

## Step 20: Use summary return metadata at call sites (single path)

### Status Quo
- Call evaluation ignores `FunctionSummary.return_value`.
- Summary application only updates constraints and error behavior.

### Objectives
Propagate summary-derived metadata to call sites without duplicating paths.

### Tech Notes
- In `evaluateExprValue` for calls, use `summary.return_value` when an applicable summary exists; otherwise fallback to `TypeContext`.
- **Do not** separately update call sites inside `handleCallNode`; the assignment path (var_decl/assign) will consume `evaluateExprValue`.
- Add tests that verify call sites receive summary metadata through var_decl/assign.

### Acceptance Criteria
- Tests confirm call sites use summary return metadata when available.
- No duplicate or conflicting return-value propagation.
- `just test` passes.

## Step 21: Plumb value metadata into Store.free tracking

### Status Quo
- `Store.markFreed` has no value metadata.

### Objectives
Allow store tracking to receive an optional `AbstractValue` at free sites.

### Tech Notes
- Update `Store.markFreed(region, call_token, value: ?AbstractValue)` signature.
- Thread the value through direct free call paths (no new violations yet).

### Acceptance Criteria
- Existing store tests still pass.
- `just test` passes.

## Step 22: Extend deferred/errdefer storage to include values

### Status Quo
- Deferred frees store only an action.

### Objectives
Store values at defer sites and propagate them into free tracking.

### Tech Notes
- Extend deferred/errdefer maps to store `{ action, value: ?AbstractValue }`.
- When applying deferred frees, pass stored value into `markFreed` (using the semantics from Step 15).

### Acceptance Criteria
- Deferred free tracking passes values through to store logic.
- `just test` passes.

## Step 23: Add sentinel_coercion_free violation and diagnostics

### Status Quo
- `StoreViolationKind` has no sentinel coercion entry.

### Objectives
Detect sentinel-coercion frees (including defer/errdefer) in a sound way and surface them as engine diagnostics.

### Tech Notes
- Add `StoreViolationKind.sentinel_coercion_free`.
- In `Store.markFreed`, inspect metadata and record `sentinel_coercion_free` as needed.
- Update diagnostics in `store_violations_engine`.

### Acceptance Criteria
- Unit tests show `sentinel_coercion_free` for direct and deferred frees.
- Existing store tests still pass.
- `just test` passes.

## Step 24: Require TypeContext in store-violations-engine

### Status Quo
- `store_violations_engine` constructs its own `TypeContext`.
- Tests pass `type_context = null`.

### Objectives
Make the checker participate in per-checker typed IR gating and use analyzer-provided `TypeContext` consistently.

### Tech Notes
- Mark checker `type_requirement = .required`.
- Use `context.type_context.?` and pass into `CfgBuilder.initWithTypes`.
- Remove per-checker `TypeContext` creation.
- Update checker tests to supply `TypeContext` or run through analyzer with typed IR gating.

### Acceptance Criteria
- `store_violations_engine` only runs when `TypeContext` is available.
- Tests updated accordingly and pass.
- `just test` passes.

## Step 25: Add store_violations_engine fixtures for sentinel coercion

### Status Quo
- Store violation fixtures exist, but none are sentinel-coercion specific.

### Objectives
Validate sentinel-coercion behavior in realistic engine fixtures to catch regressions.

### Tech Notes
Create `test/fixtures/store_violations_engine/sentinel_*`:
- `coercion_on_decl.zig`
- `coercion_on_assign.zig`
- `through_alias.zig`
- `inferred_type.zig` (should error, sound)
- `preserved_sentinel.zig` (no error)
- `no_free.zig` (no error)
Expected `sentinel_coercion_free` in relevant cases.

### Acceptance Criteria
- Fixture tests pass with expected diagnostics.
- `just test` passes.

## Step 26: Demote AST sentinel_alloc rule and update docs

### Status Quo
- `sentinel_alloc` rule emits warnings unconditionally.
- Docs do not mention engine-based sentinel coercion or typed IR gating.

### Objectives
Keep the AST rule as a heuristic signal and document the engine-based detection and typed IR requirements clearly for users.

### Tech Notes
- Change `sentinel_alloc` severity to `.info`.
- Update fixtures for new severity expectations.
- Update docs/README to mention:
  - `sentinel_coercion_free` violation
  - Typed IR is required for specific engine checkers and those checkers are skipped if typed IR is unavailable
  - Parsing failures become diagnostics and do not halt other files

### Acceptance Criteria
- AST rule fixtures updated and pass.
- Docs mention new violation, typed IR requirement, and parse diagnostic behavior.
- `just test` and `just lint` pass.

## Step 27: End-to-end verification

### Status Quo
- All code and fixtures updated.

### Objectives
Validate correctness, soundness, and regressions across unit tests, fixtures, and a real-world repro.

### Tech Notes
- Run `just test` and `just lint`.
- Run analyzer on `../architect` to confirm the original bug is detected.

### Acceptance Criteria
- `just test` passes.
- `just lint` passes.
- `zig build run -- ../architect` detects the sentinel coercion bug.
- No false positives on preserved sentinel types (except acceptable sound cases).
