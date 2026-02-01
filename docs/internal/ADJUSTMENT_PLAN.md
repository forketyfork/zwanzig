# Task: Zwanzig Correctness Fixes and Analysis Improvements

Overview: Finish the remaining correctness work after VarId mapping and basic engine infrastructure landed. The focus now is on real constraint extraction, accurate error-path summaries, CFG-based unreachable detection, artifact caching, and documentation updates.

## Step 1: Implement branch constraint extraction

### Status Quo
- VarId mapping and scope-aware resolution are in place.
- `AnalysisEngine.extractBranchConstraint` only handles literal booleans and a placeholder operand encoding.
- `CfgBuilder` does not encode comparison details, so conditions like `x == 0` or `x != null` do not yield constraints.

### Objectives
Extract simple, sound constraints from branch conditions and apply them on branch edges to enable path pruning and refined states.

### Tech Notes
- Parse the condition AST directly for binary comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`) and null checks.
- Map identifiers to canonical VarIds using the existing resolver.
- Emit `Constraint.intCompare` for integer literals and `Constraint.nullCheck` for optional comparisons.
- Keep boolean checks for `if (flag)` and literal conditions.
- Do not invent constraints for complex expressions; return null when uncertain.

### Acceptance Criteria
- `just test` passes with new constraint extraction tests.
- Fixture: `if (x == null) {}` applies a null constraint to `x` on the true branch.
- Fixture: `if (x < 0) {}` applies an integer constraint on the true branch.
- `just lint` passes.

## Step 2: Fix summary error-path correctness

### Status Quo
- Summary computation only detects `try`/`try_error` edges.
- Explicit error returns (`return error.Foo`) and error-union returns are not reflected in summaries.
- `FunctionSummary.applyToState` only marks error state for `always_returns_error`.

### Objectives
Ensure summaries conservatively preserve error behavior so callers see error paths when a callee can return errors.

### Tech Notes
- Inspect return expressions in `computeSummary` to detect explicit error values.
- When `TypeContext` is available, treat error-union return types as `may_return_error`.
- If summary applicability is unclear (missing types or ambiguous control flow), fall back to inlining.
- Apply `may_return_error` by forking or marking error paths in `applyToState` (keep conservative).

### Acceptance Criteria
- `just test` passes with summary error-path tests.
- Fixture: function returning `error.Foo` sets `may_return_error` in its summary.
- Fixture: caller of error-returning function shows an error path in the exploded graph.
- `just lint` passes.

## Step 3: Use CFG/exploded graph reachability for unreachable code

### Status Quo
- The AST rule handles obvious unreachable code after returns.
- `unreachable-code-engine` only reports constant conditions via AST evaluation.
- The exploded graph is not used to detect unreachable CFG nodes.

### Objectives
Report unreachable code based on CFG reachability and path feasibility, not just constant conditions.

### Tech Notes
- Add or extend an engine-based checker to scan CFG nodes with no reachable exploded states.
- Report only when **no** feasible states reach a node (conservative).
- Map unreachable CFG nodes back to source ranges for diagnostics.

### Acceptance Criteria
- `just test` passes with engine-based unreachable code tests.
- Fixture: `if (true) { return; } doSomething();` marks `doSomething()` as unreachable.
- Fixture: loop with guaranteed early return marks trailing code unreachable.
- `just lint` passes.

## Step 4: Cache intermediate artifacts (typed IR/CFG/summaries)

### Status Quo
- Cache infrastructure and `CachedArtifacts` exist, but only minimal metadata is stored.
- CFGs, summaries, and typed IR are rebuilt on every run even with `--cache`.

### Objectives
Persist and reuse intermediate artifacts while still recomputing diagnostics on every run.

### Tech Notes
- Serialize CFGs and summaries into `CachedArtifacts` after analysis.
- On cache hit, load artifacts and reuse them where safe (no diagnostics caching).
- Guard reuse by cache version and build metadata; fall back to recomputation when missing.

### Acceptance Criteria
- `just test` passes with artifact caching tests.
- Running the analyzer twice on unchanged input reuses cached CFG/summaries but still produces diagnostics.
- `just lint` passes.

## Step 5: Update documentation for adjustments

### Status Quo
- `docs/IMPLEMENTATION.md` documents VarId mapping and current cache behavior.
- Diagnostic ownership, constraint extraction semantics, and CFG-based unreachable detection are not documented.

### Objectives
Update internal and user-facing docs to reflect the completed adjustments.

### Tech Notes
- Document diagnostic ownership (messages are owned by `Diagnostic`).
- Document branch constraint extraction and summary error-path behavior.
- Update cache documentation to reflect artifact reuse once implemented.
- Add a note about CFG/exploded-graph-based unreachable detection.

### Acceptance Criteria
- `docs/IMPLEMENTATION.md` covers diagnostic ownership, constraint extraction, summary error paths, and artifact caching.
- `README.md` (and/or `docs/RULES.md`) mentions CFG-based unreachable detection if user-facing.
- `just lint` passes.
