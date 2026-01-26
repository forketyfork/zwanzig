# Task: Zwanzig Correctness Fixes and Analysis Improvements

This plan focuses on correctness fixes and minimal analysis improvements that make the linter practically useful. It incorporates the chosen decisions:
- **Diagnostics**: Option A (Diagnostic always owns message strings)
- **Cache**: Option 3 (Cache intermediate artifacts: typed IR/CFG/summaries), not diagnostics

Each step is designed for a single agent session (target: < ~1000 LOC change per step).

---

## Completed Steps

### ✅ Step 1-2: Diagnostic Ownership (COMPLETED)

Diagnostics now always own their message strings. `Diagnostic.init` and `Diagnostic.initAtLocation` accept an allocator and duplicate the message. `Analyzer.deinit` is the single owner that frees messages. All call sites have been migrated and tests cover ownership safety.

---

## Remaining Steps

## Step 3: Variable Identity (VarId) Unification

### Status Quo
- Decls, assignments, and branch constraints use different AST node IDs
- ProgramState does not propagate values or constraints correctly across these different representations
- The engine exists with basic traversal but variable tracking is inconsistent

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

## Step 4: CFG/IR VarId Integration

### Status Quo
- VarId resolver exists from Step 3
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

## Step 5: Constraint Extraction (Minimal Semantics)

### Status Quo
- VarId is integrated into IR/CFG from Step 4
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

## Step 6: Summary Error-Path Correctness

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

## Step 7: Unreachable Code via CFG/Engine

### Status Quo
- `unreachable-code` rule exists in `src/rules/unreachable_code.zig`
- Current implementation is AST-based
- Misses path-sensitive unreachable cases (e.g., after conditions that are always true)

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

## Step 8: Intermediate Artifact Cache (Typed IR/CFG/Summaries)

### Status Quo
- Cache exists in `src/cache.zig`
- Cache stores an empty blob and skips analysis on hit, dropping diagnostics
- This causes false negatives when cache is warm

### Objectives
Cache intermediate artifacts only, never diagnostics. Analysis always runs but can reuse cached artifacts.

### Tech Notes
- Remove early return on cache hit in `Analyzer.analyzeFile`
- Persist typed IR, CFGs, and summaries when available
- Load cached artifacts when valid; rebuild if missing

### Acceptance Criteria
- `just test` passes with artifact caching tests
- Verify: modify a file, run twice, second run recomputes diagnostics (not cached)
- Verify: unchanged file uses cached CFG/summaries but still runs checkers
- `just lint` passes

## Step 9: Cache Key Expansion and Invalidation

### Status Quo
- Cache from Step 8 stores intermediate artifacts
- Cache key includes only file hash + target
- This is insufficient: config changes or version upgrades should invalidate

### Objectives
Ensure cached artifacts invalidate across config/version changes.

### Tech Notes
- Include file hash, target config, cache schema version, Zwanzig version, and config hash in cache key
- Add a schema/version constant for cache compatibility
- Consider using `build_options.version` for Zwanzig version

### Acceptance Criteria
- `just test` passes with cache invalidation tests
- Test: change config file, verify cache miss
- Test: bump schema version constant, verify cache miss
- `just lint` passes

## Step 10: Documentation Update (Adjustment Scope)

### Status Quo
- Steps 3-9 have been completed
- `docs/IMPLEMENTATION.md` and `README.md` do not reflect the diagnostic ownership model or the artifact cache
- VarId mapping and constraint extraction are undocumented

### Objectives
Update documentation to reflect all adjustment changes.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` with diagnostic ownership, VarId mapping, constraint extraction, and cache behavior
- Update `README.md` with any user-facing changes (cache flags, etc.)

### Acceptance Criteria
- `docs/IMPLEMENTATION.md` describes diagnostic ownership model
- `docs/IMPLEMENTATION.md` describes VarId and constraint extraction
- `docs/IMPLEMENTATION.md` describes artifact caching strategy
- `just lint` passes
