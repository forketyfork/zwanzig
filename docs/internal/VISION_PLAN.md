# Feature: Clang-Style Static Analysis for Zwanzig

This plan starts after the Adjustment Plan is complete. Its goal is to achieve the full Clang-style static analysis vision: typed IR + CFG + path-sensitive abstract interpretation + rich checker ecosystem with interprocedural scalability.

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

## ✅ Step 2: Region/Store Model (Heap + Resources) (COMPLETED)

### Status Quo
- ProgramState in `src/engine/state.zig` tracks environment (locals) and constraints
- Heap allocations and resources (files, sockets) are not modeled
- Cannot detect resource leaks or double-free bugs

### Objectives
Introduce a region/store abstraction for ownership and resource tracking, enabling resource leak and use-after-free detection.

### Tech Notes
- Add a Store mapping regions to abstract resource states (allocated, freed, open, closed)
- Connect store updates to IR nodes for alloc/free/open/close patterns
- Ensure the store is part of ProgramState equality and hashing for proper deduplication
- Consider Zig's allocator patterns: `allocator.alloc()`, `allocator.free()`, etc.

### Acceptance Criteria
- `just test` passes with store model tests
- Test fixture: `var ptr = allocator.alloc(...); allocator.free(ptr);` tracks allocated→freed transition
- Test fixture: double-free produces a diagnostic
- `just lint` passes

## Step 3: Richer Abstract Domains

### Status Quo
- Abstract values in `src/engine/value.zig` are minimal (Unknown, Null, NonNull, IntRange)
- No support for symbolic values or arithmetic propagation
- Slice lengths and pointer nullability lack dedicated domains

### Objectives
Improve value precision to support real-world bug detection with symbolic values, arithmetic, and slice tracking.

### Tech Notes
- Add symbolic values for expressions (e.g., `x + 1` as a symbolic reference to x)
- Extend integer ranges with arithmetic operations and joins/meets
- Represent slice length and pointer nullability with dedicated domains
- Consider widening strategies for loop convergence

### Acceptance Criteria
- `just test` passes with abstract domain tests
- Test: `var x: i32 = 5; x = x + 1;` results in range [6, 6] or symbolic x+1
- Test: slice length tracking across `slice[0..n]` operations
- `just lint` passes

## Step 4: Constraint Solver Upgrade

### Status Quo
- ConstraintManager in `src/engine/constraints.zig` is a simple consistency checker
- No solver backend for complex constraint reasoning
- Limited path pruning capabilities

### Objectives
Introduce a modular constraint solver capable of pruning infeasible paths with mixed integer/boolean constraints.

### Tech Notes
- Add a solver interface with a default integer/bitvector backend
- Use solver results to prune paths and refine values
- Consider incremental solving for performance
- May use a simple interval-based solver initially, with option to integrate Z3/SMT later

### Acceptance Criteria
- `just test` passes with constraint solver tests
- Test: `if (x > 10 && x < 5) { /* unreachable */ }` prunes the impossible branch
- Test: `if (x > 0) { if (x < 0) { /* unreachable */ } }` detects nested contradiction
- `just lint` passes

## Step 5: Interprocedural Summaries (Pre/Post Conditions)

### Status Quo
- Summaries exist in `src/engine/summary.zig` but are coarse and heuristic
- Parameter constraints and return relations are not tracked
- Store/region side effects are not part of summaries

### Objectives
Compute meaningful pre/postconditions and return constraints for functions, enabling precise interprocedural analysis.

### Tech Notes
- Track parameter constraints (e.g., "param0 must be non-null") in summaries
- Track return value relations (e.g., "returns param0 + 1")
- Apply summaries by refining caller state and constraints
- Integrate with store/region model for side effects (e.g., "allocates memory")

### Acceptance Criteria
- `just test` passes with summary pre/postcondition tests
- Test: function with `if (x == null) return error.NullPtr;` summary captures null check
- Test: caller uses summary to refine x as non-null after successful call
- `just lint` passes

## Step 6: Cross-File Analysis Integration

### Status Quo
- Analysis is single-file; calls across files are treated as external
- Build metadata exists in `src/build_metadata.zig` but is not used for multi-file analysis
- Summaries cannot be shared across files

### Objectives
Enable cross-file analysis using build metadata or compilation database, resolving imports and sharing summaries.

### Tech Notes
- Add module discovery and a compilation unit model
- Extend function indexing across files (use import paths)
- Ensure summaries can be cached and loaded across modules
- Consider lazy loading of cross-file summaries

### Acceptance Criteria
- `just test` passes with cross-file analysis tests
- Test fixture: two files where `a.zig` imports and calls `b.zig` function, summary is used
- Test: cross-file error propagation is detected
- `just lint` passes

## Step 7: Checker API Parity (Bug Reports + Path Notes)

### Status Quo
- Checkers can emit diagnostics via the Diagnostic type
- No mechanism to attach path context (e.g., "null assigned here", "dereferenced here")
- Diagnostics are point-in-time, not path-aware

### Objectives
Add path reporting mechanisms similar to Clang Static Analyzer, allowing checkers to attach notes showing the path to the bug.

### Tech Notes
- Introduce a bug report builder with path notes and ranges
- Allow checkers to attach notes per ProgramPoint on the path
- Consider a `DiagnosticPath` type with ordered notes
- Path notes should reference source locations

### Acceptance Criteria
- `just test` passes with path-annotated diagnostic tests
- Test: null-deref checker emits diagnostic with note "null assigned at line X" and "dereferenced at line Y"
- Verify path notes appear in JSON/SARIF output
- `just lint` passes

## Step 8: Comptime + Target-Aware Semantics

### Status Quo
- Target metadata exists in `src/build_metadata.zig` (TargetConfig with pointer size, endianness)
- Target info is not used in analysis
- Comptime code is not distinguished from runtime code

### Objectives
Model comptime boundaries and target-specific constraints for platform-aware analysis.

### Tech Notes
- Treat comptime code as a separate execution domain or summarize it
- Use target metadata for pointer size/ABI-sensitive checks (e.g., `@sizeOf` results)
- Consider marking comptime-only paths to avoid false positives

### Acceptance Criteria
- `just test` passes with target-aware tests
- Test: checker uses `target.pointer_size` to validate pointer arithmetic
- Test: comptime block does not produce runtime diagnostics
- `just lint` passes

## Step 9: Expanded Checker Suite (OOB Slice)

### Status Quo
- Checkers cover error-handling patterns: `empty-catch`, `swallowed-error`
- `store-violations-engine` checker (from Step 2) already detects: resource leaks, double-free, free-without-alloc, use-after-free, close-without-open
- No checker for OOB slice access (requires slice length tracking from Step 3)

### Objectives
Add out-of-bounds slice access detection using richer abstract domains.

### Tech Notes
- Add `oob-slice` checker using slice length tracking from Step 3
- Track slice lengths through `slice[0..n]` operations
- Detect `slice[i]` where `i >= slice.len` is provable

### Acceptance Criteria
- `just test` passes with new checker tests
- Test: `oob-slice` detects `slice[n]` where n >= slice.len
- `just lint` passes

## Step 10: Documentation Updates (Vision Scope)

### Status Quo
- Steps 2-9 have been completed
- Documentation does not reflect the full analysis pipeline
- No checker authoring guide exists

### Objectives
Document the complete architecture, checker API, and advanced features for contributors.

### Tech Notes
- Update `docs/IMPLEMENTATION.md` with store model, abstract domains, solver, and cross-file analysis
- Update `README.md` with new checker descriptions
- Add a "Checker Authoring Guide" section covering path notes, summaries, and type context usage

### Acceptance Criteria
- `docs/IMPLEMENTATION.md` describes the complete analysis pipeline
- `docs/IMPLEMENTATION.md` includes checker authoring guide with examples
- All new checkers are documented in `README.md`
- `just lint` passes
