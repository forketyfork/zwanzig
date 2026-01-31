  # Feature: Engine Type Metadata Tracking

  Extend the Zwanzig analysis engine to track type metadata through dataflow, enabling detection of type coercions that lose important information. The sentinel-alloc engine
  checker will be the first concrete use case.

  ## Problem Statement

  When a sentinel-terminated allocation (`[:0]u8`) is assigned to a non-sentinel variable (`[]u8`), the type information is lost. If that variable is later freed, the allocator
  receives incorrect size information (len vs len+1), causing memory corruption.

  **Current gap**: The engine tracks resource state (allocated/freed) but not type properties. Type information exists in IR nodes but stops flowing at assignment boundaries.

  ## Step 1: Extend TypeInfo with Sentinel Metadata

  ### Status Quo
  - `TypeInfo` in `src/zir_bridge.zig` has `kind` and `type_str` fields
  - AST has `.slice_sentinel`, `.ptr_type_sentinel`, `.array_type_sentinel` tags but they collapse to generic slice/pointer during extraction
  - No sentinel information is preserved in the type system

  ### Objectives
  Add sentinel tracking to `TypeInfo` so that sentinel-terminated types can be distinguished from non-sentinel types throughout the analysis.

  ### Tech Notes
  **File**: `src/zir_bridge.zig`

  Add to `TypeInfo`:
  ```zig
  pub const TypeInfo = struct {
  // ... existing fields ...
  sentinel: ?SentinelInfo = null,

  pub const SentinelInfo = struct {
  value: i64,  // e.g., 0 for [:0]u8
  };

  pub fn hasSentinel(self: TypeInfo) bool {
  return self.sentinel != null;
  }
  };
  ```

  Update `extractTypeFromAstNode()` to populate sentinel info when encountering `.slice_sentinel`, `.ptr_type_sentinel`, `.array_type_sentinel` AST nodes.

  ### Acceptance Criteria
  - `just test` passes
  - Unit test verifies `TypeInfo.hasSentinel()` returns true for `[:0]u8` type
  - Unit test verifies `TypeInfo.hasSentinel()` returns false for `[]u8` type

  ## Step 2: Extend AbstractValue with Type Metadata

  ### Status Quo
  - `AbstractValue` in `src/engine/value.zig` is a union with variants: `unknown`, `null_val`, `non_null`, `int_range`, `concrete_int`
  - No mechanism to attach type metadata to values
  - `widen()` function handles value merging at join points

  ### Objectives
  Add a new variant to carry type metadata through dataflow analysis, enabling the engine to track type properties across assignments.

  ### Tech Notes
  **File**: `src/engine/value.zig`

  ```zig
  pub const AbstractValue = union(enum) {
  unknown,
  null_val,
  non_null,
  int_range: IntRange,
  concrete_int: i64,
  typed: TypedValue,  // NEW

  pub const TypedValue = struct {
  base: BaseValue,
  type_meta: TypeMetadata,
  };

  pub const BaseValue = enum { unknown, null_val, non_null };

  pub const TypeMetadata = struct {
  kind: TypeKind,
  has_sentinel: bool = false,
  sentinel_value: ?i64 = null,
  sentinel_coerced: bool = false,

  pub fn coerced(self: TypeMetadata) TypeMetadata {
  var result = self;
  if (self.has_sentinel) result.sentinel_coerced = true;
  return result;
  }
  };

  pub fn withTypeMeta(self: AbstractValue, meta: TypeMetadata) AbstractValue;
  pub fn getTypeMeta(self: AbstractValue) ?TypeMetadata;
  pub fn hasSentinelCoercion(self: AbstractValue) bool;
  };
  ```

  Update `widen()` to handle `typed` variant conservatively: lose metadata if types differ.

  ### Acceptance Criteria
  - `just test` passes
  - Unit test creates `AbstractValue.typed` and retrieves metadata
  - Unit test verifies `widen()` of two identical typed values preserves metadata
  - Unit test verifies `widen()` of different typed values results in `unknown`

  ## Step 3: Add Violation Kind for Sentinel Coercion

  ### Status Quo
  - `StoreViolationKind` in `src/engine/store.zig` has existing violations: `use_after_free`, `double_free`, `leaked_resource`, `use_before_init`, `uninit_read`,
  `use_while_borrowed`, `file_use_after_close`, `file_double_close`, `file_leaked`
  - `Store.markFreed()` records violations when freeing already-freed resources
  - No tracking of type-related violations

  ### Objectives
  Add a new violation kind to track when a sentinel allocation is freed after losing its type information via coercion.

  ### Tech Notes
  **File**: `src/engine/store.zig`

  ```zig
  pub const StoreViolationKind = enum {
  // ... existing kinds ...
  sentinel_coercion_free,
  };
  ```

  Update `markFreed()` signature to accept optional value:
  ```zig
  pub fn markFreed(self: *Store, region: VarId, call_token: ?u32, value: ?AbstractValue) !void {
  if (value) |v| {
  if (v.hasSentinelCoercion()) {
  try self.recordViolation(self.canonical(region), .sentinel_coercion_free, call_token);
  }
  }
  // ... existing logic ...
  }
  ```

  ### Acceptance Criteria
  - `just test` passes
  - Existing store tests still pass (no regression)
  - `StoreViolationKind.sentinel_coercion_free` exists and can be used

  ## Step 4: Propagate Type Metadata in Analysis Engine

  ### Status Quo
  - `AnalysisEngine` in `src/engine/analysis.zig` processes IR nodes via `transferFunction`
  - `.var_decl` case (around line 1900) creates variables and tracks allocations
  - `.assign` case (around line 1958) handles assignments
  - Variables are set to `.unknown` without consulting type information
  - `trackFree` in state doesn't pass the variable's value

  ### Objectives
  Detect sentinel allocations, track type coercions, and propagate type metadata through variable assignments so that violations can be detected at free sites.

  ### Tech Notes
  **File**: `src/engine/analysis.zig`

  Add helper functions:
  ```zig
  fn detectSentinelAllocation(self: *AnalysisEngine, expr_node: u32) ?i64 {
  // Detect: allocSentinel, dupeZ, allocPrintSentinel
  // Also: allocWithOptions/readToEndAllocOptions with non-null sentinel param
  }

  fn detectsSentinelCoercion(
  self: *AnalysisEngine,
  value_type: ?TypeInfo,
  decl_type: ?TypeInfo,
  ) bool {
  const val_has_sentinel = if (value_type) |vt| vt.hasSentinel() else false;
  const decl_has_sentinel = if (decl_type) |dt| dt.hasSentinel() else true;
  return val_has_sentinel and !decl_has_sentinel;
  }
  ```

  Update `.var_decl` case to:
  1. Check if initializer is a sentinel allocation
  2. Check for coercion via explicit type annotation
  3. Set variable value with type metadata

  Update `.assign` case similarly.

  **File**: `src/engine/state.zig`

  Update `trackFree` to pass value to `store.markFreed()`.

  ### Acceptance Criteria
  - `just test` passes
  - `just lint` passes (zwanzig on its own code)
  - Debug print shows type metadata flowing through assignments (temporary verification)

  ## Step 5: Create Engine-Based Checker

  ### Status Quo
  - Existing checkers in `src/checkers/` follow the `Checker` interface
  - Checkers use `CheckerContext` with optional `TypeContext`
  - CFG building and analysis engine are available

  ### Objectives
  Create a new engine-based checker that uses the type metadata tracking to detect sentinel coercion issues with precision (no false positives).

  ### Tech Notes
  **File**: `src/checkers/sentinel_alloc_engine.zig` (new file)

  ```zig
  pub const SentinelAllocEngineChecker = struct {
  pub const checker: Checker = .{
  .name = "sentinel-alloc-engine",
  .default_severity = .err,
  .checkAstFn = checkAst,
  };

  fn checkAst(
  src: *Source,
  ast_allocator: std.mem.Allocator,
  diagnostics: *std.ArrayList(Diagnostic),
  context: *CheckerContext,
  ) CheckerError!void {
  // For each function:
  // 1. Build CFG
  // 2. Run analysis engine
  // 3. Collect sentinel_coercion_free violations
  // 4. Emit diagnostics
  }
  };
  ```

  ### Acceptance Criteria
  - `just test` passes
  - New checker detects `const x: []u8 = allocSentinel(...)` pattern
  - New checker does NOT flag `const x: [:0]u8 = allocSentinel(...)`
  - New checker does NOT flag `const x = allocSentinel(...)` (inferred type)

  ## Step 6: Create Test Fixtures

  ### Status Quo
  - Test fixtures exist in `test/fixtures/` directory
  - `test/fixture_tests.zig` runs fixture-based tests
  - Existing `test/fixtures/sentinel_alloc/` has AST-based rule tests

  ### Objectives
  Create comprehensive test fixtures for the engine-based checker covering all coercion scenarios.

  ### Tech Notes
  **Directory**: `test/fixtures/sentinel_alloc_engine/`

  | Fixture | Description | Expected |
  |---------|-------------|----------|
  | `coercion_on_decl.zig` | `const x: []u8 = allocSentinel(...)` | Error |
  | `coercion_on_assign.zig` | `var x: []u8 = undefined; x = allocSentinel(...)` | Error |
  | `preserved_sentinel.zig` | `const x: [:0]u8 = allocSentinel(...)` | No error |
  | `inferred_type.zig` | `const x = allocSentinel(...)` | No error |
  | `through_alias.zig` | `const a = allocSentinel(...); const b: []u8 = a;` | Error at b |
  | `no_free.zig` | Coercion without free | No error (not freeing) |

  ### Acceptance Criteria
  - `just test` passes with all new fixtures
  - Each fixture has correct `// EXPECT:` comment matching actual behavior

  ## Step 7: Update Existing AST-Based Rule

  ### Status Quo
  - `src/rules/sentinel_alloc.zig` emits warnings for all sentinel allocations
  - This produces false positives when type is preserved or inferred

  ### Objectives
  Demote the AST-based rule to informational severity since the engine-based checker provides precise detection. The AST rule becomes a fast heuristic.

  ### Tech Notes
  **File**: `src/rules/sentinel_alloc.zig`

  Change severity from `warning` to `info` or consider removing if redundant.

  Update test fixtures in `test/fixtures/sentinel_alloc/` to expect `severity=info`.

  ### Acceptance Criteria
  - `just test` passes
  - AST rule no longer causes CI failures for sentinel allocations
  - Engine checker is the authoritative source for sentinel coercion errors

  ## Step 8: Registration and Integration

  ### Status Quo
  - Rules are registered in `src/main.zig`
  - Exports are in `src/lib.zig`

  ### Objectives
  Register the new engine-based checker and export for library users.

  ### Tech Notes
  **File**: `src/main.zig`
  ```zig
  const sentinel_alloc_engine = @import("checkers/sentinel_alloc_engine.zig");
  // ...
  try analyzer.registerChecker(&sentinel_alloc_engine.SentinelAllocEngineChecker.checker);
  ```

  **File**: `src/lib.zig`
  ```zig
  pub const sentinel_alloc_engine = @import("checkers/sentinel_alloc_engine.zig");
  ```

  ### Acceptance Criteria
  - `just test` passes
  - `just lint` passes
  - `zig build run -- ../architect` detects the original bug without false positives

  ## Verification

  After full implementation:

  1. `just test` - All existing and new tests pass
  2. `just lint` - Zwanzig passes on its own code
  3. Run on user's project (`../architect`) - Should detect the original sentinel coercion bug
  4. New fixtures pass with expected diagnostics
  5. No false positives on preserved sentinel types or inferred types

  ## Critical Files

  | File | Changes |
  |------|---------|
  | `src/zir_bridge.zig` | Add `SentinelInfo` to `TypeInfo` |
  | `src/engine/value.zig` | Add `typed` variant with `TypeMetadata` |
  | `src/engine/store.zig` | Add `sentinel_coercion_free` violation |
  | `src/engine/analysis.zig` | Propagate type metadata, detect coercions |
  | `src/engine/state.zig` | Update `trackFree` to pass value |
  | `src/checkers/sentinel_alloc_engine.zig` | New checker |
  | `src/rules/sentinel_alloc.zig` | Demote to info severity |
  | `src/main.zig` | Register new checker |
  | `src/lib.zig` | Export new checker |
  | `test/fixture_tests.zig` | Add fixture test |

  ## Future Extensions

  This infrastructure enables:
  - Tracking other type properties (optionality, error union unwrapping)
  - Detecting null pointer dereference after optional unwrap
  - Tracking const/mut through assignments
  - Cross-function type flow analysis
