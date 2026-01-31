# Feature: Proper Widening in Analysis Engine

Introduce loop-header widening to replace the current per-point state drop strategy, while preserving soundness and providing convergence guarantees.

## Step 1: Align widening points with current CFG semantics

### Status Quo
- CFG builder emits `.loop_header` nodes and `EdgeKind.loop_back` edges.
- Exploded graph only enforces a per-point state cap (`max_states_per_point`).
- No widening operators exist.

### Objectives
Define where widening should occur in the current CFG model and ensure it respects interprocedural context.

### Tech Notes
- Widen only on traversal of `.loop_back` edges into the loop header **pre-state**.
- Avoid widening on the first entry edge into the loop header.
- Loop header identity must include calling context (inline depth + call stack) to avoid merging unrelated contexts.
- Add a `ProgramState.contextHash()` helper and use `LoopHeaderKey { point_hash, context_hash }`.

### Implementation Notes

**Widening Trigger Conditions:**
- Widening must ONLY occur when traversing a `.loop_back` edge into a `.loop_header` node's pre-state.
- The first entry edge into a loop header (non-loop_back edge) must NOT trigger widening.
- The widening decision is made in the engine when processing successor edges.

**`LoopHeaderKey` Definition (implemented in `src/engine/state.zig`):**
```zig
pub const LoopHeaderKey = struct {
    /// Hash of the ProgramPoint (loop header node + CFG + pre/post)
    point_hash: u64,
    /// Hash of the calling context (inline depth + call stack)
    context_hash: u64,

    pub fn init(point: ProgramPoint, state: *const ProgramState) LoopHeaderKey;
    pub fn eql(self: LoopHeaderKey, other: LoopHeaderKey) bool;
    pub fn hash(self: LoopHeaderKey) u64;
    pub const HashContext = struct { ... };  // For use with std.HashMap
};
```

**`ProgramState.contextHash()` (implemented in `src/engine/state.zig`):**
```zig
pub fn contextHash(self: *const ProgramState) u64 {
    // Hashes inline_depth and call_stack entries
    // Call stack entries include: call_node, return_node, caller_cfg pointer
}
```

This ensures that loop header states from different interprocedural calling contexts are never merged during widening.

### Acceptance Criteria
- Design review notes confirm widening triggers only on `.loop_back` into `.loop_header` pre-state.
- `LoopHeaderKey` definition is documented in this plan and matches ProgramState context needs.

## Step 2: Define widening operators for all abstract domains

### Status Quo
- `AbstractValue` supports `unknown`, `null_val`, `non_null`, `int_range`, `concrete_int`.
- `ConstraintManager` maintains `constraints`, `per_var_constraints`, and `has_contradiction`.
- `Store` tracks resource states, aliases, defers, and violations.

### Objectives
Provide widening operators for each domain so ProgramState widening is well-defined and sound.

### Tech Notes
- `AbstractValue.widen(a, b)`:
  - If either is `unknown`, result is `unknown`.
  - `null_val` vs `non_null` -> `unknown`.
  - `concrete_int` vs `concrete_int` -> same if equal; else widen to range or unknown.
  - `int_range` widening should force convergence.
- Preferred numeric widening: change `IntRange` to `{ low: ?i64, high: ?i64 }` with null = infinity.
  - If bounds expand, set to infinity on that side.
  - If this change is too invasive, fall back to widening to `unknown` on expansion.
- `Environment.widen`:
  - Union of variables; missing side becomes `unknown`.
- `ConstraintManager.widen`:
  - Intersection of constraints; rebuild via `addConstraint` to keep invariants.
  - If performance is a concern, drop all constraints at loop headers (sound but less precise).
- `Store.widen`:
  - Resources: keep only if both agree, else set to `unknown`.
  - Aliases/owners/deferred/errdeferred: keep only if both agree, else drop.
  - Violations: union with dedup (never lose observed violations).

### Acceptance Criteria
- Widening operators are specified for AbstractValue, Environment, ConstraintManager, Store, and ProgramState.
- Numeric widening policy is explicitly chosen (unbounded bounds or widen-to-unknown).

## Step 3: Add ProgramState widening

### Status Quo
- ProgramState includes env, constraints, store, error_state, inline_depth, call_stack, cached_hash.
- No widening exists; dedup relies on full state hashes.

### Objectives
Define a `ProgramState.widen` that composes domain widenings and remains conservative.

### Tech Notes
- Only widen states with the same loop-header key (same ProgramPoint + same context).
- Combine:
  - `env = env.widen(...)`
  - `constraints = constraints.widen(...)`
  - `store = store.widen(...)`
- `error_state` join: if equal keep; if different, set to `.error_active`.
- Preserve `inline_depth` and `call_stack` from the loop-header key context.
- Clear `cached_hash` after widening.

### Acceptance Criteria
- ProgramState widening rules are fully specified and include error_state join behavior.
- Cached hash invalidation is explicitly required after widening.

## Step 4: Integrate widening into ExplodedGraph

### Status Quo
- `ExplodedGraph` tracks `node_map`, `point_state_counts`, and `max_states_per_point`.
- Excess states per point are dropped and counted.

### Objectives
Store loop-header states, apply widening at loop back-edges, and preserve the per-point cap as a fallback.

### Tech Notes
- Add to `ExplodedGraph`:
  - `loop_header_states: std.AutoHashMap(LoopHeaderKey, ProgramState)`
  - `loop_header_visits: std.AutoHashMap(LoopHeaderKey, u32)` (for delayed widening)
- Extend `getOrCreateNode` to accept `widen_at_header` and optional `LoopHeaderKey`.
- Flow:
  1. Deduplicate by `(point, state)` hash as today.
  2. If `widen_at_header`:
     - If first visit: store clone and continue.
     - Else widen with stored state and check for convergence.
  3. Apply `max_states_per_point` **after** widening as safety net.
- Add stats: `widened_nodes`, `widening_converged`, keep `dropped_state_count`.

### Acceptance Criteria
- Graph-level widening logic is defined with clear ordering and fallback cap.
- Stats list includes widened count and convergence count.

## Step 5: Wire widening in AnalysisEngine

### Status Quo
- Worklist items carry `edge_kind`.
- `processNode` creates successor states and calls `graph.getOrCreateNode`.

### Objectives
Trigger widening only on loop-back edges and only for loop header pre-states.

### Tech Notes
- When processing post-state successors, detect `edge.kind == .loop_back`.
- Confirm successor CFG node tag is `.loop_header` and successor ProgramPoint is pre-state.
- Provide `LoopHeaderKey` based on successor ProgramPoint + ProgramState context.
- Optional: add a `widening_delay` counter in the graph and skip widening until N visits.

### Acceptance Criteria
- Widening trigger conditions are explicit and avoid first-entry edges.
- Loop-header key uses both point hash and context hash.

## Step 6: Tests and regression coverage

### Status Quo
- No widening tests exist.
- Existing engine tests only validate dedup and traversal behavior.

### Objectives
Add unit and integration tests that prove convergence and soundness.

### Tech Notes
- Unit tests:
  - AbstractValue.widen combinations
  - Environment.widen with overlapping/disjoint vars
  - ConstraintManager.widen (intersection)
  - Store.widen (agreement vs conflict)
  - ProgramState.widen (error_state join + cache invalidation)
- Integration tests:
  - Simple loop with incrementing counter: converges without drops.
  - Nested loops: widen per header.
  - Branching loop: constraints preserved conservatively.
  - Error path in loop: error_state remains sound.
- Regression: reuse fixtures that previously hit `max_states_per_point` and verify convergence.

### Acceptance Criteria
- `zig test` passes for touched files.
- `just test` and `just lint` pass after all code changes.
- At least one loop-based integration test demonstrates convergence without dropped states.

## Step 7: Rollout and configuration

### Status Quo
- CLI supports `--max-states-per-point`.
- No widening flag exists.

### Objectives
Provide a controlled rollout path for widening and maintain a safety net.

### Tech Notes
- Add a `--use-widening` flag (or config option) to gate the new behavior.
- Keep `--max-states-per-point` as a fallback when widening is enabled.
- Log widening stats alongside dropped-state stats.

### Acceptance Criteria
- CLI/config flag is documented and functional.
- Logging includes widening statistics when enabled.
- Per-point cap remains enforceable.

