# CFG support for switch expressions

Status: Approved (2026-05-26)

## Problem

Zwanzig's CFG builder (`src/cfg/builder.zig`) dispatches on AST tag in
`processNode` and has no case for `.@"switch"` / `.switch_comma`. Both fall
through to `processGenericExpr`, which produces a single opaque `.expr` IR
node. The engine's worklist then never visits the arm bodies, so any
`.call`, `.try_expr`, `.defer_stmt`, or assignment inside a switch arm is
invisible to engine analyses (double-free detection, use-after-free, the
new `defer-frees-escapee` check in `store-violations-engine`, etc.).

The AST rule `defer-frees-escapee` (`src/rules/defer_frees_escapee.zig`)
was introduced specifically as a workaround for this engine gap. Once the
engine sees switch arms, the AST rule becomes redundant.

## Scope

In scope:

1. Structural CFG support for switch expressions (statement and inline-RHS
   positions). All arm bodies become reachable CFG sub-graphs.
2. Engine-level test coverage proving switch-arm patterns now fire
   (`defer-frees-escapee` and double-free).
3. Retirement of the AST rule `defer-frees-escapee` after engine parity is
   verified.

Out of scope (deliberate, separate follow-ups):

- Path constraints from prong patterns (tag-aware path-sensitive analysis).
- Labeled-switch continue semantics introduced in Zig 0.14+ (`continue :sw
  .other_tag`). v1 treats labeled and unlabeled switch identically; the
  continue edge is not modeled.
- New `EdgeKind` variants for arms (e.g., `branch_arm`). v1 uses `.normal`
  edges from branch to each arm; can be added later without disturbing
  consumers.

## Architecture

### New file

`src/cfg/builder/switch_flow.zig` — a mixin following the existing
`control_flow.zig` / `error_flow.zig` / `statements.zig` pattern. Exposes
`processSwitch(self, cfg, source, ast_node, prev_node) → ProcessResult`.

### Algorithm

`processSwitch` mirrors `processIf` generalized to N arms:

1. Build a `.branch` IR node from the switch condition (`full_switch.ast.condition`).
2. Add edge `prev_node → branch_node`.
3. Create a `.nop` merge node.
4. For each `case_node` in `full_switch.ast.cases`:
   - `full_case = tree.fullSwitchCase(case_node)`; skip if `null` (malformed).
   - `target = full_case.ast.target_expr` (the arm body — may be a block,
     expression, or `unreachable`).
   - Recursively `self.processNode(target, branch_node)`.
   - If the result terminates, do not connect to merge.
   - Otherwise, connect `result.last → merge_node`. If the arm produced no
     CFG nodes of its own (e.g. empty block body), connect
     `branch_node → merge_node` directly.
5. If every arm terminated, return `{ .last = branch_node, .terminates = true }`.
6. If `full_switch.ast.cases` is empty (legal but rare — no arms), return
   `{ .last = branch_node, .terminates = false }` without using the merge node.
7. Otherwise, return `{ .last = merge_node, .terminates = false }`.

### Dispatch wiring

`src/cfg/builder.zig:183` switch is extended:

```zig
.@"switch", .switch_comma => try switch_flow.processSwitch(self, cfg, source, ast_node, prev_node),
```

A `pub const switch_flow = builder_switch_flow.mixin(@This());` declaration
is added next to the existing mixin declarations.

### Inline switch as RHS

`processVarDecl`, `processAssign`, and `processReturn` in
`src/cfg/builder/statements.zig` already special-case `try`/`catch`
in their init / RHS / return-expression positions. The same shape is
extended to `.@"switch"` / `.switch_comma`:

- `processVarDecl`: if the init expression is a switch, route through a new
  helper that runs `processSwitch` and then materializes the `.var_decl` IR
  node downstream of the merge.
- `processAssign`: same pattern for the RHS.
- `processReturn`: same pattern for the return expression.

The helpers live in `switch_flow.zig` and mirror
`error_flow.processVarDeclWithTry` etc. The downstream node connects from
the switch's merge so that all arm bodies' side effects are visited before
the assignment / return is recorded.

### Multi-target prongs and ranges

`full_case.ast.values` may contain multiple values (`.a, .b => body`) or
ranges (`.a...c => body`). v1 ignores the values; the arm body is processed
once, with a single edge from the branch to it. This matches the
conservative "every arm is reachable" semantics.

### Payload captures

`full_case.payload_token` introduces a captured name visible inside the arm
body. The CFG builder does not need to materialize a `.var_decl` for the
payload — `engine/var_resolver.zig` already resolves it via
`addPayloadName` at scope push, and the engine's existing payload tracking
(`engine/analysis/payloads.zig`) handles propagation. v1 does not add new
payload-related IR nodes; if a follow-up shows the engine misses payload
typing through switch arms, that becomes a separate change.

## Engine impact

No engine changes are required. The engine's worklist iterates over CFG
successors and processes `IrTag` values it already understands. Once
switch arms produce real CFG nodes, the existing analyses pick them up:

- `defer_scan.applyDeferredReleases` is invoked at `.defer_stmt` nodes —
  defers inside arms register a pending release with `scope_node` set to
  their enclosing block (which is now the arm body's block, correctly).
- `ownership.markEscapedInExpr` is invoked at call nodes —
  `append`/`appendSlice`/etc. calls inside arms trigger the existing
  `checkDeferFreesEscapeeIntoContainer` check.
- `store.markFreed` / `markClosed` etc. fire on calls inside arms,
  catching double-free and double-close patterns in switch arms.

## Retirement of the AST rule

After CFG support lands and engine tests confirm parity:

1. Delete `src/rules/defer_frees_escapee.zig` (self-contained, 8 colocated
   tests; no separate fixture directory).
2. Remove the import + `analyzer.registerRule(&DeferFreesEscapeeRule.rule)`
   from `src/cli/registry.zig:14,40`.
3. Update `docs/RULES.md`:
   - Delete the `### defer-frees-escapee` rule section (line ~308).
   - Replace the "**Note:** the engine's CFG builder does not currently
     visit `switch`-arm bodies, so the AST-level `defer-frees-escapee` rule
     remains in place" paragraph (line ~704) with a sentence noting that
     the engine now visits switch arms and the AST rule has been retired.
4. Verify `just lint` (which runs zwanzig on its own source) still passes —
   the removed rule must not be referenced by any remaining check.

### Parity gate

Before deletion, run each scenario covered by
`src/rules/defer_frees_escapee.zig`'s 8 colocated tests against the engine
checker as a sanity check. If any case fires under the AST rule but not
under the engine, do not delete the rule in this PR; either extend the
engine first or keep the rule with a `// TODO` note documenting the
remaining gap.

## Tests

### CFG-level (colocated in `src/cfg/builder.zig`)

1. **simple switch statement** — three arms, all single-call bodies; expect
   `nodeCount` increases by at least branch + 3 call nodes + merge.
2. **switch with all-terminating arms** — every arm returns; expect
   `ProcessResult.terminates == true`, no merge node created (or merge has
   no incoming edges).
3. **switch with payload capture** — `.foo => |x| consume(x)`; expect arm
   body's call node present, no crash.
4. **inline switch as var_decl init** — `const v = switch (x) { .a =>
   compute(), .b => other(), };`; expect both `compute` and `other` call
   nodes in the CFG.
5. **empty arm body** — `.foo => {}`; expect branch → merge edge with no
   crash.

### Engine-level (colocated in `src/checkers/store_violations_engine.zig`)

1. **switch arm: defer frees escapee** — reproduces the architect-crash
   pattern (`switch (kind) { .heading => { const spaces = try
   allocator.alloc(...); defer allocator.free(spaces); try
   run_inputs.append(allocator, .{ .text = spaces }); }, ... }`); expect
   `defer_frees_escapee` diagnostic.
2. **switch arm: double free** — `switch (k) { .a => { const p = try
   alloc(); allocator.free(p); allocator.free(p); }, ... }`; expect
   `double_free` diagnostic.
3. **no regression** — every existing fixture under
   `test/fixtures/store_violations_engine/` continues to pass with no new
   diagnostics.

### Verification commands

```bash
just test       # all tests
just lint       # zig fmt --check + zwanzig on self + shellcheck
just ci         # full build + test + lint
```

## File-touch summary

Modified:
- `src/cfg/builder.zig` — new mixin declaration + dispatch case
- `src/cfg/builder/statements.zig` — inline-switch RHS detection
- `src/checkers/store_violations_engine.zig` — new tests
- `src/cli/registry.zig` — drop AST rule registration
- `docs/RULES.md` — drop AST rule section, update engine note

New:
- `src/cfg/builder/switch_flow.zig` — `processSwitch` + inline RHS helpers

Deleted:
- `src/rules/defer_frees_escapee.zig`

## Open questions

None — all scope choices recorded above.
