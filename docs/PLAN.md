# Zwanzig Implementation Plan (Stepcat Format)

This plan is a linear sequence of steps to move from the current linter MVP to a full static analysis architecture. Each step is sized to be completed by a single coding agent session (target: under ~1000 LOC change per step).

## Step 1: Source Parsing Cache

### Status Quo

Zwanzig reads source bytes per file and rules operate on raw text. There is no shared token or AST cache.

### Objectives

Introduce a `Source` abstraction that lazily provides tokens and AST, and pass it to rules.

### Tech Notes

- Add a `Source` type with `tokens()` and `ast()` methods using `std.zig.Tokenizer` and `std.zig.Ast.parse`.
- Construct `Source` once per file in the analyzer and pass it to all rules.
- Keep existing rule API working by providing a compatibility adapter if needed.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Analyzer constructs a `Source` per file and rules can access tokens/AST.
- Documentation updated to describe the parsing cache (README.md, IMPLEMENTATION.md).
- Tests cover token/AST cache reuse behavior.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 2: Rule Selection Flags

### Status Quo

All rules run unconditionally; CLI only supports positional file arguments.

### Objectives

Add CLI flags to select rules by allowlist or blocklist.

### Tech Notes

- Add `--do` (allowlist) and `--skip` (blocklist) flags.
- Ensure `--do` and `--skip` are mutually exclusive.
- Keep positional file arguments working.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Rules can be enabled/disabled via CLI flags.
- Documentation updated with rule selection usage (README.md).
- Tests cover `--do` and `--skip` behavior.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 3: File Discovery and Filtering

### Status Quo

Zwanzig analyzes only explicitly passed file paths.

### Objectives

Add recursive file discovery and standard ignore filters.

### Tech Notes

- Add a `--file` repeatable flag; if no files are passed, walk the current directory.
- Ignore `zig-cache/`, `zig-out/`, `.zigmod/`, `.gyro/`.
- Keep positional file arguments supported for backward compatibility.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Analyzer can discover `.zig` files by walking directories.
- Ignore list is enforced.
- Documentation updated to describe file discovery (README.md).
- Tests cover traversal and ignore behavior.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 4: Diagnostics Model

### Status Quo

Rules emit `Violation` records with line/column only; output formatting is ad hoc.

### Objectives

Introduce a structured diagnostic model with ranges and severity, and update reporting.

### Tech Notes

- Add `Diagnostic` with rule id, severity, message, and primary source range.
- Add helpers to map token/byte locations to line/column.
- Update output formatting to use diagnostics.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Diagnostics are structured and used for output.
- Documentation updated to describe diagnostics format (README.md, IMPLEMENTATION.md).
- Tests cover diagnostic formatting and location mapping.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 5: AST-Based Empty Catch Rule

### Status Quo

`empty_catch` is implemented via text scanning.

### Objectives

Re-implement `empty_catch` using AST traversal and the diagnostics model.

### Tech Notes

- Locate `catch` nodes via AST tags.
- Check the catch block body length to determine emptiness.
- Emit diagnostics with correct ranges.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `empty_catch` uses AST traversal and diagnostics.
- Documentation updated to describe the rule behavior (README.md).
- Tests cover AST-based empty catch detection.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 6: Rule - Duplicate Imports

### Status Quo

Only `empty_catch` exists.

### Objectives

Implement `dupe_import` rule.

### Tech Notes

- Scan tokens for `@import("...")` patterns.
- Track duplicate import strings and emit diagnostics.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `dupe_import` rule is available and documented.
- Tests cover duplicate and non-duplicate cases.
- Documentation updated to list the rule (README.md, IMPLEMENTATION.md).
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 7: Rule - TODO Comments

### Status Quo

Only `empty_catch` and `dupe_import` exist.

### Objectives

Implement `todo` rule.

### Tech Notes

- Scan source lines for `// TODO`.
- Emit diagnostics with line/column and message.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `todo` rule is available and documented.
- Tests cover TODO detection and location accuracy.
- Documentation updated to list the rule (README.md, IMPLEMENTATION.md).
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 8: Rule - File Name vs Top-Level Fields

### Status Quo

Only basic lint rules exist.

### Objectives

Implement `file_as_struct` rule.

### Tech Notes

- Use AST root decls to detect top-level fields.
- If fields exist, require capitalized file name; otherwise require lowercase.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `file_as_struct` rule is available and documented.
- Tests cover both capitalization cases.
- Documentation updated to list the rule (README.md, IMPLEMENTATION.md).
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 9: Rule - Unused Declarations

### Status Quo

Only basic lint rules exist.

### Objectives

Implement `unused_decl` rule for container-level const/var and functions.

### Tech Notes

- Traverse AST to find non-exported container-level declarations.
- Search for identifier usage across container scope.
- Keep initial behavior conservative (avoid deep semantic resolution).

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `unused_decl` rule is available and documented.
- Tests cover unused and used declarations.
- Documentation updated to list the rule (README.md, IMPLEMENTATION.md).
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 10: IR + CFG Types

### Status Quo

Rules are syntax-only; no IR or CFG exists.

### Objectives

Define minimal IR and CFG types and build CFG for simple blocks.

### Tech Notes

- Define IR nodes for statements/expressions.
- Define CFG node/edge types and per-function graphs.
- Build CFG for: block, return, simple statements.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- CFG builder produces graphs for simple functions.
- CFG nodes map to source ranges.
- Documentation updated to describe IR/CFG types (IMPLEMENTATION.md).
- Tests cover CFG shape for simple cases.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 11: CFG Builder - Branching

### Status Quo

CFG supports only simple blocks and returns.

### Objectives

Add CFG support for `if/else` and basic branching.

### Tech Notes

- Add branch nodes for condition evaluation.
- Create explicit edges for then/else paths.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- CFG correctly represents `if/else` structures.
- Documentation updated to describe branching CFG (IMPLEMENTATION.md).
- Tests cover CFG for `if/else` constructs.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 12: Checker Interface + Rule Adapter

### Status Quo

Rules are invoked directly by the analyzer and are tightly coupled to the current AST-only pipeline.

### Objectives

Introduce a checker interface and manager, plus an adapter so existing rules continue to work unchanged.

### Tech Notes

- Add a minimal `Checker` interface with a small set of hooks (start with AST-only hooks).
- Add a `CheckerManager` that owns checker registration and dispatch.
- Provide a compatibility adapter that wraps existing `Rule` implementations as checkers.
- Keep rule selection flags working with the new manager.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Existing rules still run and emit identical diagnostics.
- New checker API is documented (IMPLEMENTATION.md).
- Tests cover checker registration and adapter behavior.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 13: CFG Builder - Termination and Fallthrough

### Status Quo

CFG may incorrectly allow fallthrough after statements that terminate control flow (e.g., fully-terminating `if/else`).

### Objectives

Model termination explicitly and prevent fallthrough edges after paths that must return.

### Tech Notes

- Propagate termination status through CFG builder traversal.
- Stop block processing after a terminating statement or fully-terminating branch.
- Ensure no extra edges are added from terminating statements or branches to merge/exit nodes.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- CFG does not include fallthrough edges after terminating `if/else`.
- Tests cover if/else termination and unreachable trailing statements.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 14: CFG Builder - Loops and Defers

### Status Quo

CFG has branching but no loops or defer handling.

### Objectives

Add CFG support for loops and defer/errdefer ordering.

### Tech Notes

- Add loop back-edges for `while`/`for`.
- Represent defer/errdefer execution order in CFG.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- CFG correctly represents loops and defer/errdefer edges.
- Documentation updated to describe loop/defer CFG (IMPLEMENTATION.md).
- Tests cover loop and defer CFG behavior.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 15: CFG Builder - Try/Catch Edges

### Status Quo

CFG lacks explicit error-handling edges.

### Objectives

Add CFG support for `try`/`catch` control-flow edges.

### Tech Notes

- Add edges for error vs success paths at `try`.
- Represent catch blocks explicitly in CFG.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- CFG represents `try/catch` control flow.
- Documentation updated to describe error-flow CFG (IMPLEMENTATION.md).
- Tests cover CFG for `try/catch` constructs.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 16: Typed IR Bridge (Single Module)

### Status Quo

Analysis relies on syntax AST without typed information.

### Objectives

Add a front-end bridge that loads typed IR for a single module.

### Tech Notes

- Use Zig tooling outputs (e.g., ZIR/AIR) to obtain typed info.
- Map typed IR to internal IR/CFG for a small test module.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Analyzer can load typed IR for a single test module.
- Documentation updated to describe typed IR integration.
- Tests cover typed IR ingestion for a small fixture.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 17: ProgramPoint + ProgramState Skeleton

### Status Quo

CFG exists but there is no analysis engine.

### Objectives

Implement ProgramPoint, ProgramState placeholders, and a worklist traversal.

### Tech Notes

- ProgramPoint identifies CFG node + pre/post state.
- ProgramState stores placeholder env/store/constraints.
- ExplodedGraph nodes are keyed by (ProgramPoint, ProgramState).
- Implement a worklist traversal with deduping.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Engine traverses CFG and builds an exploded graph.
- Deduping works for identical point/state.
- Documentation updated to describe ProgramPoint/State (IMPLEMENTATION.md).
- Tests cover worklist traversal and deduping.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 18: Abstract Values + Basic Evaluation

### Status Quo

Engine traverses CFG but does not interpret semantics.

### Objectives

Add abstract values and evaluation for literals/assignments.

### Tech Notes

- Abstract values: Unknown, Null, NonNull, IntRange.
- Environment mapping for locals.
- Evaluate literals and assignments.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- ProgramState propagates values through assignments.
- Documentation updated to describe abstract values (IMPLEMENTATION.md).
- Tests cover value propagation.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 19: Branch Constraints and Pruning

### Status Quo

Interpreter evaluates assignments but ignores branch constraints.

### Objectives

Introduce a simple constraint manager and branch pruning.

### Tech Notes

- Add constraints for comparisons on integers and nullness.
- Fork state on `if` conditions and prune impossible paths.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Constraints refine state across branches.
- Infeasible paths are pruned.
- Documentation updated to describe constraint handling (IMPLEMENTATION.md).
- Tests cover constraint refinement.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 20: Easy CFG-Based Rules

### Status Quo

Engine exists but only lint rules are implemented.

### Objectives

Add simple CFG-based rules: `unreachable_code`, `empty_defer`, `empty_errdefer`.

### Tech Notes

- `unreachable_code`: report CFG nodes with no incoming feasible edges.
- `empty_defer` / `empty_errdefer`: detect empty defer bodies using CFG/AST mapping.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- New CFG-based rules emit diagnostics.
- Documentation updated to list new rules (README.md, IMPLEMENTATION.md).
- Tests cover all new rules.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 21: Error Semantics

### Status Quo

Interpreter does not model error unions or try/catch semantics.

### Objectives

Model error flow in ProgramState for `try`, `catch`, and error unions.

### Tech Notes

- Track error state in ProgramState (success vs error).
- Model `try` as a branch on error vs success.
- Model `catch` as an error-handling branch in the interpreter.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Error state propagates through `try/catch` paths.
- Documentation updated to describe error semantics (IMPLEMENTATION.md).
- Tests cover error propagation.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 22: Error-Handling Checkers

### Status Quo

Error flow exists but no error-handling rules use it.

### Objectives

Move `empty_catch` into the engine and add `swallowed_error` checker.

### Tech Notes

- Implement engine-level `empty_catch` checker using CFG/ProgramState.
- Add `swallowed_error` checker for catch blocks that ignore errors without rethrow/log/return.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- `empty_catch` and `swallowed_error` are engine-based checkers.
- Documentation updated to describe error-handling rules (README.md, IMPLEMENTATION.md).
- Tests cover both rules in engine context.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 23: Interprocedural Inlining

### Status Quo

Analysis is intra-procedural only.

### Objectives

Add limited inlining for function calls.

### Tech Notes

- Inline functions up to a configurable depth.
- Treat external calls as unknown effects.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Calls are analyzed via inlining up to a depth limit.
- Documentation updated to describe inlining behavior.
- Tests cover inlined call paths.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 24: Function Summaries and Cache

### Status Quo

Inlining exists but no summary cache is available.

### Objectives

Implement function summaries and caching to avoid re-analysis.

### Tech Notes

- Summaries store preconditions, postconditions, and error behavior.
- Cache summaries per function and reuse across call sites.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Summary cache is used across call sites.
- Documentation updated to describe summary strategy.
- Tests cover summary generation and reuse.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 25: Build Metadata Integration

### Status Quo

Analyzer does not integrate with build configuration or target data.

### Objectives

Integrate build metadata and target configuration into analysis.

### Tech Notes

- Add CLI support to read build metadata (build.zig or compilation metadata).
- Propagate target triple/config into ProgramState.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Analyzer uses target configuration in analysis.
- Documentation updated to describe build integration.
- Tests cover target-specific configuration paths.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 26: Configuration File Support

### Status Quo

No configuration file is supported.

### Objectives

Add a configuration file to enable/disable rules and set thresholds.

### Tech Notes

- Add `.zwanzig.json` with rule toggles and options.
- Merge CLI flags with config file (CLI overrides).

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Config file is parsed and applied.
- Documentation updated to describe configuration (README.md).
- Tests cover config parsing and precedence.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 27: JSON Output

### Status Quo

Only text output is supported.

### Objectives

Add JSON output format for diagnostics.

### Tech Notes

- Implement a JSON emitter for diagnostics.
- Add CLI flag `--format json`.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- JSON output is supported and documented.
- Tests cover JSON output structure.
- Documentation updated to describe output formats.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 28: SARIF Output

### Status Quo

Only text and JSON output are supported.

### Objectives

Add SARIF output format for diagnostics.

### Tech Notes

- Implement a SARIF emitter for diagnostics.
- Add CLI flag `--format sarif`.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- SARIF output is supported and documented.
- Tests cover SARIF output structure.
- Documentation updated to describe output formats.
- `zig build` succeeds.
- `zig build test` succeeds.

## Step 29: Incremental Cache

### Status Quo

No caching exists for IR or summaries.

### Objectives

Add incremental caching for IR and summaries keyed by file hash and target.

### Tech Notes

- Cache typed IR and summaries on disk.
- Invalidate cache when file hash or target changes.

### Scope Guard

- Do not implement features from later steps.
- Keep net new/changed code under ~1000 LOC for this step.
- Limit changes to the files directly needed for this step; avoid broad refactors.

### Acceptance Criteria

- Cache is used on repeated runs and invalidates correctly.
- Documentation updated to describe caching (IMPLEMENTATION.md).
- Tests cover cache hit/miss behavior.
- `zig build` succeeds.
- `zig build test` succeeds.
