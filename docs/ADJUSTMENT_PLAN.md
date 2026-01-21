# Zwanzig Adjustment Plan (Stepcat Format)

This plan focuses on correctness fixes and minimal analysis improvements that make the linter practically useful. It incorporates the chosen decisions:
- **Diagnostics**: Option A (Diagnostic always owns message strings)
- **Cache**: Option 3 (Cache intermediate artifacts: typed IR/CFG/summaries), not diagnostics

Each step is designed for a single agent session (target: < ~1000 LOC change per step).

## Step 1: Diagnostic Ownership (Always Owned)

### Status Quo
Diagnostics are freed unconditionally, but messages are a mix of owned and borrowed strings, causing invalid frees.

### Objectives
Make `Diagnostic` always own its message and enforce allocation at creation sites.

### Tech Notes
- Update `Diagnostic.init` and `Diagnostic.initAtLocation` to accept an allocator and duplicate the message.
- Remove manual message duplication in rules/checkers to avoid double allocations.
- Keep `Analyzer.deinit` as the single owner that frees messages.

### Acceptance Criteria
- All diagnostics own their messages.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 2: Diagnostic API Migration + Tests

### Status Quo
Rules/checkers allocate message strings inconsistently; tests do not cover ownership safety.

### Objectives
Normalize all diagnostic creation and add regression tests for message ownership.

### Tech Notes
- Update all call sites to the new `Diagnostic` API.
- Add a test that creates diagnostics from string literals and verifies `Analyzer.deinit` safety.

### Acceptance Criteria
- No manual message free remains in rules/checkers.
- Tests cover literal messages + analyzer deinit.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 3: Variable Identity (VarId) Unification

### Status Quo
Decls, assignments, and branch constraints use different AST node IDs, so ProgramState does not propagate values or constraints.

### Objectives
Introduce a stable VarId mapping for locals and use it consistently.

### Tech Notes
- Implement a VarId resolver for function scope (conservative AST‑based mapping).
- Provide a helper (e.g., `VarIdMap.resolve(node)`) used by CFG builder and engine.

### Acceptance Criteria
- Decl/assign/branch constraints resolve to the same VarId.
- Tests cover end‑to‑end var propagation within a function.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 4: CFG/IR VarId Integration

### Status Quo
IR nodes store raw AST indices; engine assumes those are VarIds.

### Objectives
Embed VarId in IR/CFG to align state updates and constraints.

### Tech Notes
- Extend `IrNode` with VarId fields for assignments and branch conditions.
- Populate VarIds in the CFG builder for `.var_decl`, `.assign`, and `.branch`.
- Update engine to use VarId fields instead of AST node indices.

### Acceptance Criteria
- ProgramState uses canonical VarIds.
- Constraints refer to existing environment bindings.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 5: Constraint Extraction (Minimal Semantics)

### Status Quo
Branch constraint extraction is a placeholder and does not reflect actual conditions.

### Objectives
Extract simple constraints from conditions (`x == 0`, `x != 0`, `x < N`, `x == null`, `x != null`).

### Tech Notes
- Parse the branch condition AST for simple binary ops and null checks.
- Encode comparison info in IR or an auxiliary condition struct.
- Apply constraints on `branch_true`/`branch_false` edges and prune infeasible paths.

### Acceptance Criteria
- Constraints are applied on true/false edges for simple conditions.
- Tests cover int and null constraints + pruning.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 6: Summary Error-Path Correctness

### Status Quo
Summaries may drop error paths; error behavior detection is limited to `try_expr`.

### Objectives
Ensure summaries conservatively preserve error behavior.

### Tech Notes
- Detect explicit error returns in CFG (e.g., `return error.X` / error union returns).
- Track `may_return_error` in summaries and apply it in `applyToState` by forking or marking error paths.
- If summary applicability is unclear, fall back to inlining.

### Acceptance Criteria
- Summary usage preserves error paths for error‑returning functions.
- Tests cover summary correctness for explicit error returns.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 7: Unreachable Code via CFG/Engine

### Status Quo
`unreachable-code` is AST‑based and misses path‑sensitive unreachable cases.

### Objectives
Use CFG + exploded graph reachability for unreachable detection.

### Tech Notes
- Report CFG nodes that have no feasible exploded nodes reaching them.
- Keep conservative: report only when no feasible paths exist.

### Acceptance Criteria
- Detects unreachable after returns and fully‑terminating branches.
- Tests cover loops and branching cases.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 8: Intermediate Artifact Cache (Typed IR/CFG/Summaries)

### Status Quo
Cache stores an empty blob and skips analysis on hit, dropping diagnostics.

### Objectives
Cache intermediate artifacts only, never diagnostics; analysis always runs.

### Tech Notes
- Remove early return on cache hit in `Analyzer.analyzeFile`.
- Persist typed IR, CFGs, and summaries when available.
- Load cached artifacts when valid; rebuild if missing.

### Acceptance Criteria
- Cache hits reuse artifacts but do not skip analysis.
- Tests cover cache hit/miss for artifacts.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 9: Cache Key Expansion and Invalidation

### Status Quo
Cache key includes only file hash + target, which is insufficient.

### Objectives
Ensure cached artifacts invalidate across config/version changes.

### Tech Notes
- Include file hash, target config, cache schema version, Zwanzig version, and config hash.
- Add a schema/version constant for cache compatibility.

### Acceptance Criteria
- Cache invalidates on target/config/version changes.
- Cache keys are deterministic across runs.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 10: Documentation Update (Adjustment Scope)

### Status Quo
Docs do not reflect the diagnostic ownership model or the artifact cache.

### Objectives
Update docs to reflect the adjustment changes.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` and `README.md` with new ownership and cache behavior.
- Document VarId mapping and constraint extraction basics.

### Acceptance Criteria
- Docs accurately describe the adjusted architecture.
- `zig build` succeeds.
- `zig build test` succeeds.
