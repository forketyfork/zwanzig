# Zwanzig Vision Plan (Stepcat Format)

This plan starts after the Adjustment Plan is complete. Its goal is to achieve the full Clang‑style static analysis vision: typed IR + CFG + path‑sensitive abstract interpretation + rich checker ecosystem with interprocedural scalability.

Each step is scoped to be completed in a single agent session (target: < ~1000 LOC change per step).

---

## Completed Steps

### ✅ Step 1: Typed IR Integration (COMPLETED)

Typed IR is now a first-class input for analysis. Key implementations:

- **ZirBridge** (`src/zir_bridge.zig`): Generates ZIR from source and extracts typed information
- **TypeInfo/TypeKind**: Type representation with 16+ type categories (int, pointer, error_union, etc.)
- **TypeContext** (`src/type_context.zig`): Unified interface for type queries with caching
- **IrNode type_info field**: IR nodes carry optional `TypeInfo` for type-aware analysis
- **CfgBuilder integration**: CFG builder annotates nodes with types during construction
- **CheckerContext**: Checkers receive type context for type-aware analysis

Type information is used by:
- `identifier-style` rule for type-aware naming convention enforcement
- `unused-decl` rule for distinguishing types from values

---

## Remaining Steps

## Step 1: Region/Store Model (Heap + Resources)

### Status Quo
ProgramState only tracks environment and constraints; heap/resources are not modeled.

### Objectives
Introduce a region/store abstraction for ownership and resource tracking.

### Tech Notes
- Add a Store mapping regions to abstract resource states (allocated, freed, open, closed).
- Connect store updates to IR nodes for alloc/free/open/close.
- Ensure the store is part of ProgramState equality and hashing.

### Acceptance Criteria
- ProgramState includes a store model.
- At least one resource checker uses it.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 2: Richer Abstract Domains

### Status Quo
Abstract values are minimal and lack expression support (arithmetic, slices, ownership).

### Objectives
Improve value precision to support real‑world bug detection.

### Tech Notes
- Add symbolic values for expressions.
- Extend integer ranges with arithmetic and joins/meets.
- Represent slice length and pointer nullability with dedicated domains.

### Acceptance Criteria
- Range propagation works across basic arithmetic.
- Tests cover range refinement and joins.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 3: Constraint Solver Upgrade

### Status Quo
ConstraintManager is a simple consistency checker without a solver backend.

### Objectives
Introduce a modular constraint solver capable of pruning infeasible paths.

### Tech Notes
- Add a solver interface with a default integer/bitvector backend.
- Use solver results to prune paths and refine values.

### Acceptance Criteria
- Constraints prune infeasible paths beyond trivial cases.
- Tests cover solver decisions with mixed constraints.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 4: Interprocedural Summaries (Pre/Post Conditions)

### Status Quo
Summaries exist but are coarse and heuristic.

### Objectives
Compute meaningful pre/postconditions and return constraints for functions.

### Tech Notes
- Track parameter constraints and return relations in summaries.
- Apply summaries by refining caller state and constraints.
- Integrate with store/region model for side effects.

### Acceptance Criteria
- Summaries propagate meaningful constraints across calls.
- Tests cover summary reuse with different caller states.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 5: Cross-File Analysis Integration

### Status Quo
Analysis is single‑file; calls across files are treated as external.

### Objectives
Enable cross‑file analysis using build metadata or compilation database.

### Tech Notes
- Add module discovery and a compilation unit model.
- Extend function indexing across files.
- Ensure summaries can be cached across modules.

### Acceptance Criteria
- Cross‑file calls are resolved and summarized/inlined.
- Tests include multi‑file fixtures.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 6: Checker API Parity (Bug Reports + Path Notes)

### Status Quo
Checkers can emit diagnostics but cannot attach path context.

### Objectives
Add path reporting mechanisms similar to Clang SA.

### Tech Notes
- Introduce a bug report builder with path notes and ranges.
- Allow checkers to attach notes per ProgramPoint.

### Acceptance Criteria
- At least one checker emits a path‑annotated report.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 7: Comptime + Target‑Aware Semantics

### Status Quo
Target metadata exists but is not used; comptime code is not modeled.

### Objectives
Model comptime boundaries and target‑specific constraints.

### Tech Notes
- Treat comptime code as a separate execution domain or summary.
- Use target metadata for pointer size/ABI‑sensitive checks.

### Acceptance Criteria
- At least one checker uses target metadata.
- Comptime code is handled conservatively without crashes.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 8: Expanded Checker Suite

### Status Quo
Checkers cover a small set of error‑handling patterns only.

### Objectives
Deliver practical, high‑value checkers aligned with Zig usage.

### Tech Notes
- Add checkers for resource leaks, double free, and OOB slice access.
- Use the store/region and typed IR to reduce false positives.

### Acceptance Criteria
- New checkers produce actionable diagnostics on fixtures.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 9: Documentation Updates (Vision Scope)

### Status Quo
Docs do not reflect the full analysis pipeline and advanced features.

### Objectives
Document the complete architecture and checker API.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` and `README.md`.
- Add a “checker authoring” section with path notes and summaries.

### Acceptance Criteria
- Docs reflect the full analysis pipeline and APIs.
- `zig build` succeeds.
- `zig build test` succeeds.
