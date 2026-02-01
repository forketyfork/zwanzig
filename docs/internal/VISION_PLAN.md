# Feature: Clang-Style Static Analysis for Zwanzig

Overview: The typed IR integration and region/store model are in place. The remaining work focuses on richer abstract domains, stronger constraint solving, deeper interprocedural modeling, cross-file analysis, and a more expressive checker API.

## Step 1: Richer Abstract Domains

### Status Quo
- `AbstractValue` supports unknown/null/non-null and integer ranges.
- No symbolic values or arithmetic propagation.
- Slice length and pointer nullability lack dedicated domains.

### Objectives
Increase value precision to enable real-world bug detection (arithmetic, symbolic relationships, and slice tracking).

### Tech Notes
- Add symbolic values for expressions (e.g., `x + 1`).
- Extend integer ranges with arithmetic operations and joins/meets.
- Track slice length and pointer nullability explicitly.
- Add or refine widening strategies for loops.

### Acceptance Criteria
- `just test` passes with abstract-domain tests.
- Example: `var x: i32 = 5; x = x + 1;` yields a precise range or symbolic value.
- Slice length tracking is validated by tests.
- `just lint` passes.

## Step 2: Constraint Solver Upgrade

### Status Quo
- `ConstraintManager` is a lightweight consistency checker.
- Path pruning is limited to simple constraints.

### Objectives
Introduce a modular constraint solver capable of pruning infeasible paths with mixed constraints.

### Tech Notes
- Add a solver interface with an interval/bitvector backend initially.
- Use solver results to prune paths and refine values.
- Consider incremental solving for performance.

### Acceptance Criteria
- `just test` passes with solver tests.
- `if (x > 10 && x < 5)` prunes the impossible branch.
- `just lint` passes.

## Step 3: Interprocedural Summaries (Pre/Post Conditions)

### Status Quo
- Summaries exist but are coarse and heuristic.
- Parameter constraints and store side effects are not tracked.

### Objectives
Compute meaningful pre/postconditions and return relations to improve interprocedural precision.

### Tech Notes
- Track parameter constraints (e.g., non-null requirements).
- Track return relations and store/region side effects.
- Apply summaries by refining caller states and constraints.

### Acceptance Criteria
- `just test` passes with summary pre/postcondition tests.
- Caller states are refined by summary constraints.
- `just lint` passes.

## Step 4: Cross-File Analysis Integration

### Status Quo
- Analysis is single-file; cross-file calls are treated as external.
- Build metadata exists but is not used for cross-file indexing.

### Objectives
Enable cross-file analysis, sharing summaries across modules.

### Tech Notes
- Add module discovery and a compilation unit model.
- Resolve imports and index functions across files.
- Cache and reuse summaries across files.

### Acceptance Criteria
- `just test` passes with cross-file fixtures.
- A two-file fixture uses summaries from imported functions.
- `just lint` passes.

## Step 5: Checker API Parity (Bug Reports + Path Notes)

### Status Quo
- Diagnostics are point-in-time; no path notes are attached.
- JSON/SARIF output does not include path context.

### Objectives
Provide Clang-style bug reports with path notes and structured context.

### Tech Notes
- Introduce a `DiagnosticPath` or bug report builder.
- Allow checkers to attach notes per ProgramPoint.
- Extend JSON/SARIF output to include notes.

### Acceptance Criteria
- `just test` passes with path-annotated diagnostic tests.
- Diagnostics include ordered path notes in JSON/SARIF output.
- `just lint` passes.

## Step 6: Comptime + Target-Aware Semantics

### Status Quo
- Target metadata exists (`BuildMetadata`), but is not used.
- Comptime execution is not distinguished from runtime.

### Objectives
Model comptime boundaries and target-specific constraints for platform-aware analysis.

### Tech Notes
- Treat comptime code as a separate execution domain or summarize it.
- Use target metadata for ABI- and pointer-size-sensitive checks.
- Avoid false positives from comptime-only paths.

### Acceptance Criteria
- `just test` passes with target-aware tests.
- Comptime blocks do not produce runtime diagnostics.
- `just lint` passes.

## Step 7: Expanded Checker Suite (OOB Slice)

### Status Quo
- Existing checkers cover store violations and error handling patterns.
- No checker for out-of-bounds slice access.

### Objectives
Add OOB slice detection based on slice length tracking from Step 1.

### Tech Notes
- Implement an `oob-slice` checker using slice length metadata.
- Detect `slice[i]` when `i >= slice.len` is provable.

### Acceptance Criteria
- `just test` passes with `oob-slice` fixtures.
- Proven OOB accesses are reported without false positives.
- `just lint` passes.

## Step 8: Documentation Updates (Vision Scope)

### Status Quo
- Documentation reflects the current pipeline, not the expanded vision features.
- No checker authoring guide exists for path notes or summaries.

### Objectives
Document the complete architecture and checker authoring workflow once the above steps land.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` with the full analysis pipeline.
- Update `README.md` and `docs/RULES.md` with new checkers.
- Add a checker authoring guide with examples of path notes and summaries.

### Acceptance Criteria
- Documentation reflects the completed vision features.
- New checkers are listed in `README.md` and `docs/RULES.md`.
- `just lint` passes.
