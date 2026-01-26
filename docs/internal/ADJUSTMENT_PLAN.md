# Task: Zwanzig Correctness Fixes and Analysis Improvements

This plan focuses on correctness fixes and minimal analysis improvements that make the linter practically useful. It incorporates the chosen decisions:
- **Diagnostics**: Option A (Diagnostic always owns message strings)
- **Cache**: Option 3 (Cache intermediate artifacts: typed IR/CFG/summaries), not diagnostics

Each step is designed for a single agent session (target: < ~1000 LOC change per step).

---

## Step 1: Variable Identity (VarId) Unification

### Status Quo
- VarId exists in `src/ids.zig`, but uses raw AST indices as identifiers
- Decls, assignments, and branch constraints use different AST node IDs
- ProgramState does not propagate values or constraints correctly across these different representations

### Objectives
Introduce a stable VarId mapping for locals and use it consistently across the CFG builder and engine, enabling correct value and constraint propagation.

### Tech Notes
- Implement a VarId resolver for function scope (conservative AST-based mapping)
- Provide a helper (e.g., `VarIdMap.resolve(node)`) used by CFG builder and engine
- Consider using `src/ids.zig` as the location for VarId types

### Acceptance Criteria
- `just test` passes with new VarId propagation tests
- Create a test fixture with `var x = 1; x = 2; if (x == 2) {}` and verify the constraint applies to the same VarId
- `just lint` passes

## Step 2: CFG/IR VarId Integration

### Status Quo
- VarId resolver exists from Step 1
- IR nodes in `src/ir.zig` store raw AST indices
- Engine assumes those are VarIds but they are not canonical

### Objectives
Embed VarId in IR/CFG to align state updates and constraints, ensuring ProgramState uses canonical identifiers.

### Tech Notes
- Extend `IrNode` with VarId fields for assignments and branch conditions
- Populate VarIds in the CFG builder for `.var_decl`, `.assign`, and `.branch`
- Update engine to use VarId fields instead of AST node indices

### Acceptance Criteria
- `just test` passes with IR/CFG VarId tests
- Verify with a test that `env.get(var_id)` returns the expected value after assignment
- `just lint` passes

## Step 3: Constraint Extraction (Minimal Semantics)

### Status Quo
- VarId is integrated into IR/CFG from Step 2
- Branch constraint extraction in the engine is a placeholder
- Constraints do not reflect actual conditions like `x == 0` or `x != null`

### Objectives
Extract simple constraints from conditions (`x == 0`, `x != 0`, `x < N`, `x == null`, `x != null`) and apply them on branch edges.

### Tech Notes
- Parse the branch condition AST for simple binary ops and null checks
- Encode comparison info in IR or an auxiliary condition struct
- Apply constraints on `branch_true`/`branch_false` edges and prune infeasible paths

### Acceptance Criteria
- `just test` passes with constraint extraction tests
- Test fixture: `if (x == null) { /* x is null here */ } else { /* x is non-null here */ }` verifies correct constraint application
- Test fixture with `if (x < 0) { return; } // x >= 0 here` verifies integer constraints
- `just lint` passes

## Step 4: Summary Error-Path Correctness

### Status Quo
- Function summaries exist in `src/engine/summary.zig`
- Summaries may drop error paths
- Error behavior detection is limited to `try_expr`

### Objectives
Ensure summaries conservatively preserve error behavior for functions that can return errors.

### Tech Notes
- Detect explicit error returns in CFG (e.g., `return error.X` / error union returns)
- Track `may_return_error` in summaries and apply it in `applyToState` by forking or marking error paths
- If summary applicability is unclear, fall back to inlining

### Acceptance Criteria
- `just test` passes with summary error-path tests
- Test fixture: function returning `error.Foo` has `may_return_error = true` in its summary
- Test fixture: caller of error-returning function has error path in exploded graph
- `just lint` passes

## Step 5: Unreachable Code via CFG/Engine

### Status Quo
- `unreachable-code` rule exists in `src/rules/unreachable_code.zig` and is AST-based
- `unreachable-code-engine` checker only detects constant `true`/`false` conditions
- CFG/exploded-graph reachability is not used for unreachable detection

### Objectives
Use CFG + exploded graph reachability for more precise unreachable code detection.

### Tech Notes
- Report CFG nodes that have no feasible exploded nodes reaching them
- Keep conservative: report only when no feasible paths exist
- May need to add a checker interface for engine-based unreachable detection

### Acceptance Criteria
- `just test` passes with engine-based unreachable code tests
- Test fixture: `if (true) { return; } doSomething();` detects `doSomething()` as unreachable
- Test fixture: loop with guaranteed early return detects trailing code as unreachable
- `just lint` passes

## Step 6: Intermediate Artifact Cache (Typed IR/CFG/Summaries)

### Status Quo
- Cache exists in `src/cache.zig` and no longer skips analysis on cache hits
- Cache keys include file hash, target, tool version, and enabled rules
- `CachedArtifacts` serialization exists but analyzer does not store or reuse CFGs/summaries yet

### Objectives
Cache intermediate artifacts only, never diagnostics. Analysis always runs but can reuse cached artifacts.

### Tech Notes
- Persist typed IR, CFGs, and summaries when available
- Load cached artifacts when valid; rebuild if missing
- Ensure cached artifacts are actually used to skip recomputation where safe

### Acceptance Criteria
- `just test` passes with artifact caching tests
- Verify: modify a file, run twice, second run recomputes diagnostics (not cached)
- Verify: unchanged file uses cached CFG/summaries but still runs checkers
- `just lint` passes

## Step 7: Documentation Update (Adjustment Scope)

### Status Quo
- `docs/IMPLEMENTATION.md` and `README.md` were partially updated
- VarId mapping, constraint extraction, and CFG-based unreachable detection are not documented
- Cache docs do not yet cover actual CFG reuse once implemented

### Objectives
Update documentation to reflect all adjustment changes once Steps 1-6 are complete.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` with diagnostic ownership, VarId mapping, constraint extraction, and cache behavior
- Update `README.md` with any user-facing changes (cache flags, new checker behavior)

### Acceptance Criteria
- `docs/IMPLEMENTATION.md` describes diagnostic ownership model
- `docs/IMPLEMENTATION.md` describes VarId and constraint extraction
- `docs/IMPLEMENTATION.md` describes artifact caching strategy and actual reuse
- `just lint` passes
