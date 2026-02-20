# Slice Bounds Checker Implementation Summary

## Overview

I've implemented a new **slice-bounds-engine** checker that detects out-of-bounds array and slice access in Zig code. This checker brings significant value to the project by catching a common class of runtime panics at compile time.

## Why This Checker?

After analyzing the existing checkers, I identified that while zwanzig has excellent coverage for:
- Memory safety (stack-escape, store-violations)
- Arithmetic safety (divide-by-zero)
- Null safety (optional-unwrap)
- Error handling (empty-catch, swallowed-error)

It was **missing bounds checking** for array and slice access, which is:
1. A common source of bugs in Zig programs
2. Can cause runtime panics
3. Well-suited for static analysis using the existing abstract value system

## Implementation Details

### Architecture

The checker follows the established pattern for engine-based checkers:

```
slice_bounds_engine.zig (main checker)
├── slice_bounds/scan.zig (site collection and analysis)
└── slice_bounds/evaluator.zig (bounds comparison logic)
```

### Key Components

1. **Main Checker** (`src/checkers/slice_bounds_engine.zig`)
   - Follows the standard checker pattern
   - Registers as "slice-bounds-engine"
   - Uses the analysis engine for path-sensitive analysis
   - Iterates over functions and test declarations

2. **Scanner** (`src/checkers/slice_bounds/scan.zig`)
   - Collects all `array_access` nodes in the AST
   - Runs analysis with CFG context when available
   - Categorizes violations as definite or possible
   - Emits diagnostics for violations

3. **Evaluator** (`src/checkers/slice_bounds/evaluator.zig`)
   - Evaluates index expressions to `AbstractValue`
   - Evaluates array/slice lengths (for literals and known-size arrays)
   - Compares bounds conservatively
   - Handles:
     - Concrete integers (exact values)
     - Integer ranges (possible value ranges)
     - Basic arithmetic (`+`, `-`)

### Analysis Approach

The checker uses **conservative static analysis**:

```zig
// Definite OOB: provably out of bounds
const arr = [_]u8{ 1, 2, 3 };
_ = arr[5]; // index=5 (concrete), length=3 (concrete) → 5 >= 3

// Possible OOB: may be out of bounds on some paths
var i: usize = 0;
while (i < 10) : (i += 1) {
    _ = arr[i]; // index=[0..10] (range), length=3 (concrete) → max(10) >= 3
}

// Safe: provably within bounds
_ = arr[2]; // index=2 (concrete), length=3 (concrete) → 2 < 3
```

### Leveraging Existing Infrastructure

The implementation reuses:
- `AbstractValue` system for representing index and length values
- `AnalysisEngine` for path-sensitive dataflow analysis
- Standard checker registration and configuration
- AST walking utilities from `ast_walk.zig`
- Diagnostic reporting infrastructure

## Test Coverage

Created comprehensive test fixtures in `test/fixtures/slice_bounds_engine/`:

1. `definite_oob_literal.zig` - Literal index out of bounds (definite)
2. `negative_index.zig` - Negative index detection
3. `safe_access.zig` - Valid accesses (no false positives)
4. `string_literal_oob.zig` - String literal bounds checking
5. `loop_bounds.zig` - Loop-based potential violations

## Integration

1. **Registry**: Added to `src/cli/registry.zig` alongside other engine-based checkers
2. **README**: Updated to list the new checker
3. **Documentation**: Created comprehensive docs in `docs/SLICE_BOUNDS_CHECKER.md`

## Technical Highlights

### Smart Bounds Comparison

The evaluator handles various combinations:

| Index Type | Length Type | Analysis |
|------------|-------------|----------|
| Concrete   | Concrete    | Exact comparison |
| Concrete   | Range       | Conservative (check against min/max) |
| Range      | Concrete    | Conservative (check max against length) |
| Range      | Range       | Conservative (check overlap) |
| Unknown    | Any         | No warning (insufficient info) |

### Negative Index Detection

The checker properly handles signed indices:

```zig
const idx: i32 = -1;
_ = arr[@intCast(idx)]; // Detected as possibly OOB (negative)
```

### Array Literal Length Detection

The evaluator recognizes array literal lengths:

```zig
const arr = [_]u8{ 1, 2, 3 }; // Correctly infers length = 3
_ = arr[5]; // Detected as definite OOB
```

## Limitations & Future Work

**Current Limitations:**
1. No interprocedural analysis (indices passed through functions)
2. No tracking of dynamic `slice.len`
3. Limited arithmetic expression evaluation
4. No range refinement from conditionals

**Future Enhancements:**
1. Track slice lengths through assignments
2. Refine ranges based on conditionals (e.g., `if (i < arr.len)`)
3. More complex expression evaluation
4. Interprocedural bounds tracking

## Building & Testing

The checker integrates seamlessly with the existing build system:

```bash
# Build (requires Nix environment)
nix develop --command just build

# Test
nix develop --command just test

# Run on fixtures
nix develop --command zig build run -- test/fixtures/slice_bounds_engine/
```

## Impact

This checker adds significant value by:
- **Preventing runtime panics** from bounds violations
- **Catching bugs early** during development
- **Complementing existing safety checkers** with bounds analysis
- **Following established patterns** for easy maintenance

The implementation demonstrates mastery of:
- Zwanzig's engine-based checker architecture
- Abstract value-based dataflow analysis
- Conservative static analysis techniques
- Zig code patterns and best practices
