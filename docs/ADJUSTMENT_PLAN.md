# Zwanzig Adjustment Plan (Stepcat Format)

This plan focuses on correctness fixes and minimal analysis improvements that make the linter practically useful.

Each step is designed for a single agent session (target: < ~1000 LOC change per step).

---

## Step 1: Unreachable Code via CFG/Engine

### Status Quo
`unreachable-code` rule (`src/rules/unreachable_code.zig`) is AST-based and misses path-sensitive unreachable cases (e.g., `if (false)`, `while (0)`).

### Objectives
Use CFG + exploded graph reachability for unreachable detection.

### Tech Notes
- Create a new checker in `src/checkers/unreachable_code_checker.zig` that uses the analysis engine.
- Report CFG nodes that have no feasible exploded nodes reaching them.
- Keep conservative: report only when no feasible paths exist.
- Consider keeping the AST-based rule for simple structural cases and adding the CFG-based checker for path-sensitive cases.

### Acceptance Criteria
- Detects unreachable after returns and fully-terminating branches.
- Detects path-sensitive unreachable code (e.g., `if (false)` body).
- Tests cover loops and branching cases.
- `just ci` succeeds.

---

## Step 2: Intermediate Artifact Cache (Typed IR/CFG/Summaries)

### Status Quo
Cache stores an empty blob and returns early on cache hit (`src/analyzer.zig:152-156`), skipping analysis entirely. This means diagnostics are not reported on cache hits.

### Objectives
Cache intermediate artifacts only, never skip analysis; analysis always runs and produces diagnostics.

### Tech Notes
- Remove early return on cache hit in `Analyzer.analyzeFile` (line 155).
- Design what to cache: CFGs per function, function summaries.
- Persist typed IR, CFGs, and summaries when available.
- Load cached artifacts when valid; rebuild if missing.
- The cache value (currently empty string on line 170) should contain serialized artifacts.

### Acceptance Criteria
- Cache hits reuse artifacts but do not skip analysis.
- Diagnostics are always produced regardless of cache state.
- Tests cover cache hit/miss for artifacts.
- `just ci` succeeds.

---

## Step 3: Cache Key Expansion and Invalidation

### Status Quo
Cache key (`src/cache.zig:16-39`) includes only file hash + target hash. This is insufficient for invalidation across Zwanzig version changes or config changes.

### Objectives
Ensure cached artifacts invalidate across config/version changes.

### Tech Notes
- Add Zwanzig version to cache key computation (from build metadata or compile-time constant).
- Add enabled rules/checkers hash to cache key (config affects what's cached).
- The existing `CACHE_VERSION` (line 13) handles cache format changes, but not semantic changes.
- Consider adding a schema version for cached artifact format.

### Acceptance Criteria
- Cache invalidates on Zwanzig version changes.
- Cache invalidates on enabled rules/config changes.
- Cache keys are deterministic across runs.
- `just ci` succeeds.

---

## Step 4: Documentation Update (Adjustment Scope)

### Status Quo
Docs may not fully reflect the current ownership model, artifact cache behavior, or analysis architecture.

### Objectives
Update docs to reflect the current state and any changes made in this plan.

### Tech Notes
- Review and update `docs/IMPLEMENTATION.md` with current architecture.
- Update `README.md` if needed.
- Document VarId mapping and constraint system.
- Document cache behavior (what's cached, invalidation).

### Acceptance Criteria
- Docs accurately describe the architecture.
- `just ci` succeeds.
