# Junior Dev Task: Implement the `no-print` Rule

## Context

Zwanzig is a static analyzer for Zig. It already ships a handful of rules
(`todo`, `dupe-import`, `empty-block`, etc.) and several engine-based checkers,
all driven by an `Analyzer` that walks files, runs each enabled rule/checker,
and emits `Diagnostic`s.

The team has a parity roadmap in `docs/PARITY_PLAN.md` listing rules that
should still be implemented. The `no-print` rule (parity rule #5) is a
self-contained, well-scoped AST/token task that exercises the full rule
pipeline (rule struct → AST walk → diagnostic → registry → fixtures → docs)
without needing the analysis engine or type-inference infrastructure. It is
the right size for a junior developer: meaty enough to learn the codebase end
to end, but bounded enough to finish and review cleanly.

**Goal:** detect `std.debug.print(...)` and its common aliases in
non-test code, with sensible exceptions, mirroring the spec at
`docs/PARITY_PLAN.md:281-339`.

## What the rule should do

Flag calls to `std.debug.print` that appear in production code. The full spec
lives at `docs/PARITY_PLAN.md:281-339`; the highlights are below.

**Flag** call expressions whose callee resolves to:
1. `std.debug.print(...)` — full path field-access chain.
2. `debug.print(...)` where `debug` is bound to `std.debug` via
   `const debug = std.debug;` at file scope.
3. `print(...)` where `print` is bound to `std.debug.print` via
   `const print = std.debug.print;` at file scope.

**Do not flag** when:
1. The call is inside a `test { ... }` block (AST tag `.test_decl`).
2. The file's name ends with `test.zig` (e.g. `foo_test.zig`). Use
   `src.getFilePath()` and `std.mem.endsWith`.
3. A `fn print(...)` is defined in the same file. If a local `print`
   function exists, the alias case (3) above must not fire. The
   fully-qualified `std.debug.print` case still fires.

Severity: `.warning`. Default: enabled.

Out of scope for this task (defer with a TODO comment, not implementation):
- Per-rule configuration (e.g. an `allow_tests = false` flag). The repo
  does not yet support per-rule options — see "Open questions" below.

## Background reading (do this first, in order)

1. **Codebase entry points**
   - `CLAUDE.md` — house rules. Read it. Key items:
     - Run `just test` and `just lint` for any change.
     - All new rules must have test fixtures.
     - Format with `zig fmt`.
     - Use Zig 0.15.2 `ArrayList.empty` pattern, not the legacy
       `.init(allocator)` pattern.
   - `docs/IMPLEMENTATION.md` and `docs/RULES.md` — architecture and the
     user-facing rule docs format.

2. **Rule infrastructure**
   - `src/rule.zig:16-33` — the `Rule` struct. Fields: `name`,
     `default_severity` (defaults to `.err`), `checkFn` with signature
     `fn (*Source, std.mem.Allocator, *std.ArrayList(Diagnostic)) RuleError!void`.
   - `src/diagnostic.zig:54-99, 128-130` — `Diagnostic` shape. `init`
     duplicates the message; `deinit` frees it. The `ArrayList` of
     diagnostics owns each `Diagnostic` after `append`.
   - `src/source.zig` — `Source` helpers:
     - `ast()` returns the cached `*const std.zig.Ast` (line 59).
     - `tokens()` returns the token slice (line 54).
     - `getContent()` / `getFilePath()` (lines 46, 50).
     - `byteToLocation(byte_offset)` / `byteRangeToSourceRange(start, end)`
       (lines 74, 79) — convert byte offsets to 1-based line/column.
     - `tokenLocation(token_index)` (line 84).
   - `src/cli/registry.zig:26-50` — every rule is registered here with
     `try analyzer.registerRule(&MyRule.rule);`. You'll add one line.

3. **Worked examples to imitate**
   - `src/rules/dupe_import.zig` — token-walking rule with helpers and full
     ownership story. Good for: AST/token boundary, fully-qualified name
     building, allocator hygiene, `defer` patterns.
   - `src/rules/todo_comment.zig` — token-based detection, byte-offset →
     `SourceRange`, `Diagnostic.init` call pattern.
   - `src/rules/empty_defer.zig` — minimal AST-tag-driven rule; shows the
     simplest possible `check` function.

4. **AST helpers**
   - `src/ast_walk.zig` — generic AST walking. Useful helpers:
     - `collectNodesByTag(allocator, tree, root, tag, out)` (line 616).
     - `fillParentMap(tree, root, parent_map)` / `isAncestor(...)`
       (lines 400, 742) — when you need "is node X inside any `.test_decl`?".
   - `src/analysis/call_utils.zig`:
     - `isCallNode(tag)` (line 4) — matches all four call tag variants.
     - `constructFqn(tree, base_node, method_name, buffer)` (line 18) — given
       the callee subtree of a `.call*` node, builds the dotted name like
       `"std.debug.print"` into a stack buffer. **Use this** — do not
       hand-roll field-access traversal.

5. **Where rules already skip `test` blocks** (study the existing patterns):
   - `src/rules/return_local_pointer.zig:158` — top-level filter on
     `.fn_decl` / `.test_decl`.
   - `src/rules/deinit_lifecycle.zig:75, 99` — explicit `.test_decl` handling.
   - `src/rules/sentinel_alloc.zig:67` — list-based skip.

6. **Fixture format** (this is how the rule is tested):
   - `test/fixtures/dupe_import/multiple_same_module.zig` — shows the format:

     ```zig
     // EXPECT: line=4 rule=dupe-import
     // EXPECT: line=5 rule=dupe-import
     const std1 = @import("std");
     const std2 = @import("std");
     ```

   - `test/fixture_runner.zig:22-66` — parses `// EXPECT:` headers and
     matches against produced diagnostics. Headers support `line=N`,
     `col=M`, `rule=name`, `severity=level`, `message=substring`.
   - A fixture with no `// EXPECT:` headers asserts "no diagnostics".

7. **External references (Zig AST)**
   - `std.zig.Ast` API docs:
     <https://ziglang.org/documentation/master/std/#std.zig.Ast> — read
     the `Node.Tag` enum to understand call/field-access/variable-decl
     node shapes.
   - Zig language reference, "test declarations":
     <https://ziglang.org/documentation/master/#Tests> — relevant because
     `.test_decl` is a top-level container member.
   - Zig language reference, "@import":
     <https://ziglang.org/documentation/master/#import> — context for how
     `std` gets bound.

## Implementation plan

### Step 1: Skeleton rule

Create `src/rules/no_print.zig` modeled on `src/rules/dupe_import.zig`. The
skeleton should:

- Import `Rule`, `RuleError`, `Diagnostic`, `Source`, and a scoped logger.
- Expose `pub const NoPrintRule = struct { pub const rule: Rule = .{ .name = "no-print", .default_severity = .warning, .checkFn = check }; ... };`.
- Define `fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void` that initially does nothing.

Then register it in `src/cli/registry.zig` next to the other rules with
`try analyzer.registerRule(&NoPrintRule.rule);` (compare lines 26-50).

Confirm `just build` succeeds before moving on.

### Step 2: First pass — scan calls and match `std.debug.print`

Inside `check`:

1. `const tree = try src.ast();`
2. Iterate over `tree.nodes.items(.tag)` indexed by node id `i`.
3. For each `i` where `call_utils.isCallNode(tag)` is true:
   a. Get the callee node id. For `.call_one` / `.call_one_comma` it's
      `tree.nodes.items(.data)[i].node_and_node[0]`; for `.call` /
      `.call_comma` it's the first node in
      `tree.extraData(data.lhs, Ast.Node.SubRange)`. Look at
      `std.zig.Ast` source / `Ast.fullCall` for the canonical way to
      extract this — prefer `tree.fullCall(&buffer, i)` if it exists in
      0.15.2 (check `std.zig.Ast` in the stdlib you can `zig env`).
   b. Pass the callee node into `call_utils.constructFqn` with a method
      name pulled from the last field (or pass the empty string and have
      `constructFqn` produce just the chain). Read the function carefully
      — its current contract appends a trailing `method_name` segment, so
      you'll want to pass the *field* name as `method_name` and the
      *base* node (the LHS of the final field access) as `base_node`.
   c. If the resulting FQN equals `"std.debug.print"`, record a violation
      at the byte location of the callee's main token (use
      `tree.firstToken(i)` and `src.tokenLocation(token_idx)` →
      `SourceRange`).

4. Build the diagnostic:
   ```zig
   const msg = "Avoid std.debug.print in production code; use std.log instead.";
   const diag = try Diagnostic.init(allocator, src.getFilePath(), "no-print", .warning, msg, range);
   try diagnostics.append(allocator, diag);
   ```
   (No `defer diag.deinit` — the list owns it; `Analyzer.deinit` frees it.)

### Step 3: Detect file-scope aliases for `debug` and `print`

Before the call scan, do one pass over the AST's container-level decls to
build:

- `var debug_aliased_to_std_debug: bool = false;`
- `var print_aliased_to_std_debug_print: bool = false;`
- `var has_local_print_fn: bool = false;`

How:

- Iterate `tree.rootDecls()` (top-level node ids).
- For each tag `.simple_var_decl` / `.local_var_decl` / `.global_var_decl`
  (use `tree.fullVarDecl(node)`):
  - Read the lhs identifier token. If it's `debug`, walk the RHS and check
    whether the FQN is `"std.debug"`.
  - If it's `print`, check whether the FQN is `"std.debug.print"`.
- For each tag `.fn_decl`, get the name token (via
  `tree.fullFnProto(&buf, node)?.name_token`) and compare to `"print"`.
  Set `has_local_print_fn = true` if it matches.

Reuse `constructFqn` for the RHS chain wherever possible. The RHS of a
`simple_var_decl` is `tree.fullVarDecl(node).?.ast.init_node` — pass that as
`base_node` with `method_name = ""` (or, more robustly, peel off the last
field token yourself).

### Step 4: Match aliased calls

Back in the call scan, also flag a call when:

- The callee is a `.field_access` whose chain is `debug.print` **and**
  `debug_aliased_to_std_debug` is true.
- The callee is a single `.identifier` named `print` **and**
  `print_aliased_to_std_debug_print` is true **and**
  `has_local_print_fn` is false.

For the single-identifier case, read the identifier token via
`tree.nodes.items(.main_token)[callee_node]` then `tree.tokenSlice(...)`.

### Step 5: Skip test blocks and test files

Two filters:

1. **Test files:** at the top of `check`, do
   `if (std.mem.endsWith(u8, src.getFilePath(), "test.zig")) return;`
   No diagnostics for those.

2. **Test blocks:** when you find a candidate call at node `i`, decide
   whether any ancestor is a `.test_decl`. Two ways:

   - **Simple but O(n) per call:** walk upward via a parent map. Use
     `ast_walk.fillParentMap` to compute a `node_id → parent_id` map once,
     then for each candidate walk up to root, checking `tags[ancestor]`.
   - **Cheaper:** do a single descent from each `.test_decl` collecting
     descendant node ids into a `std.AutoHashMap(u32, void)`, then skip any
     candidate in that set.

   Pick whichever is clearer — call counts in real files are small. The
   parent-map approach is closer to existing rule patterns
   (`src/rules/return_local_pointer.zig` follows a similar idea).

### Step 6: Fixtures

Create `test/fixtures/no_print/` with at least these files. The fixture
runner picks them up automatically (`test/fixture_runner.zig:22-66`).

Required positives (each `// EXPECT:` must point to the correct line):

- `direct_call.zig` — `std.debug.print("hi\n", .{});` in a normal `fn main`.
- `aliased_debug.zig` — `const debug = std.debug;` then `debug.print(...)`.
- `aliased_print.zig` — `const print = std.debug.print;` then `print(...)`.
- `multiple_calls.zig` — three calls in one function, three EXPECTs.

Required negatives (no EXPECT lines → expect zero diagnostics):

- `in_test_block.zig` — `test "x" { std.debug.print(...); }`.
- `in_test_file_test.zig` — same content as `direct_call.zig`; filename
  ends with `test.zig`.
- `local_print_fn.zig` — defines `fn print(...)` and calls `print(...)`.
  The local-print case should also include a separate `std.debug.print`
  call to prove that fully-qualified calls still fire (so move that to a
  third file `local_print_fn_with_fq.zig` with one EXPECT).
- `unrelated_call.zig` — calls something else entirely.

Add 1–2 inline unit tests inside `src/rules/no_print.zig` that exercise the
alias-detection helper in isolation, following the `test { ... }` blocks
already present elsewhere in `src/`.

### Step 7: Docs

Add a section for `no-print` to `docs/RULES.md`. Match the format used by
existing entries (heading, short description, **Bad** + **Good** Zig
fences). The PARITY_PLAN entry at lines 281-339 has ready-to-paste
examples.

Optionally update `README.md` if it has a "rules" table — check whether
existing recent rules appear there and follow suit.

### Step 8: Lint and self-check

`just lint` runs zwanzig on its own source. Make sure the new file is
clean (no `todo` comments left over, no unused decls, `zig fmt` clean,
etc.). If a self-warning appears that you intentionally left, mention it
in the PR description.

## Files you will touch

- `src/rules/no_print.zig` *(new)*
- `src/cli/registry.zig` — one new `registerRule` line.
- `test/fixtures/no_print/*.zig` *(new directory)*
- `docs/RULES.md` — one new section.
- Possibly `README.md` if it lists rules.

## Verification

Run, in order:

1. `just build` — compiles cleanly.
2. `zig fmt src` — no diff.
3. `just test` — all tests pass, including the new fixtures.
4. `just lint` — passes (zig fmt check + zwanzig self-lint + shellcheck).

Sanity-check on a real Zig file:

```bash
echo 'const std = @import("std"); pub fn main() void { std.debug.print("x\n", .{}); }' > .tmp/np.zig
zig build run -- .tmp/np.zig
```

Expect a `no-print` warning at line 1 (or wherever the call sits).

## Open questions to confirm with the reviewer before starting

1. **Test-file detection** — should `*_test.zig` and `*Test.zig` also be
   exempt, or only `test.zig` suffix? PARITY_PLAN says "files ending with
   `test.zig`", which is the conservative reading. Match the spec unless
   told otherwise.
2. **`@import("std").debug.print(...)` inline form** — should this
   be flagged? The spec doesn't mention it, but it's the same effect.
   Recommendation: yes, treat it as the FQN case via `constructFqn`. If
   that's too involved, skip it and leave a `// TODO:` referencing this
   note.
3. **Configurability** — defer the `allow_tests` config option. The
   codebase has no per-rule options today (see `src/config.zig:215-394`,
   `src/rule.zig:16-33`). Adding that infrastructure is its own task.
   The rule should hardcode `allow_tests = true` behavior.

## Estimated size

~250–400 lines of Zig in `src/rules/no_print.zig`, ~6–8 fixture files
totaling another ~80 lines, ~30 lines of docs. About a 1–2 day task for
someone new to the codebase, half of which is reading.
