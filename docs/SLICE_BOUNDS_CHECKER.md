# Slice Bounds Checker

## Overview

The `slice-bounds-engine` checker detects potential array and slice out-of-bounds access at compile time. It uses path-sensitive analysis with abstract values to track index ranges and array/slice lengths, catching both definite and possible bounds violations.

## Capabilities

### What it detects

1. **Definite out-of-bounds access** - Index is provably outside valid range
   ```zig
   const arr = [_]u8{ 1, 2, 3 };
   _ = arr[5]; // Definite: index 5 is >= length 3
   ```

2. **Negative indices** - Attempting to index with negative values
   ```zig
   const arr = [_]u8{ 1, 2, 3, 4, 5 };
   const idx: i32 = -1;
   _ = arr[@intCast(idx)]; // May be out of bounds (negative)
   ```

3. **String literal bounds** - Out-of-bounds on string literals
   ```zig
   const str = "hello";
   _ = str[10]; // Definite: index 10 is >= length 5
   ```

4. **Loop bounds violations** - Potential OOB in loops
   ```zig
   const arr = [_]u8{ 1, 2, 3 };
   var i: usize = 0;
   while (i < 10) : (i += 1) {
       _ = arr[i]; // May be OOB when i >= 3
   }
   ```

### How it works

The checker:

1. **Collects access sites** - Finds all `array_access` nodes in the AST
2. **Runs dataflow analysis** - Uses the analysis engine to track abstract values
3. **Evaluates bounds** - Compares index values against array/slice lengths:
   - Literal indices and lengths are evaluated precisely
   - Variable indices use abstract values (concrete ints, ranges, or unknown)
   - Conservative analysis: reports when bounds *may* be violated

4. **Categorizes violations**:
   - **Definite OOB**: Index is provably out of bounds on all paths
   - **Possible OOB**: Index may be out of bounds on some paths

### Abstract Value Analysis

The checker leverages the engine's `AbstractValue` system:

- **Concrete integers**: Exact values (e.g., `5`, `-1`)
- **Integer ranges**: Possible value ranges (e.g., `[0..10]`)
- **Unknown**: No information available

Examples:
```zig
const arr = [_]u8{ 1, 2, 3 }; // length = 3 (concrete)

_ = arr[2];  // index = 2 (concrete) → Safe: 2 < 3
_ = arr[5];  // index = 5 (concrete) → Definite OOB: 5 >= 3

var i: usize = 0;
while (i < 10) : (i += 1) {
    // i has range [0..10]
    _ = arr[i]; // Possible OOB: max(i) = 10 >= 3
}
```

## Configuration

The checker is enabled by default. To disable:

```bash
zig build run -- --skip slice-bounds-engine src/
```

Or in `.zwanzig.json`:
```json
{
  "skip_rules": ["slice-bounds-engine"]
}
```

## Limitations

1. **Limited to direct array access** - Does not track bounds through function calls
2. **Conservative analysis** - May report false positives when actual bounds are guaranteed by complex logic
3. **No slice.len tracking** - Currently doesn't track dynamic slice lengths from runtime operations
4. **Simple arithmetic only** - Handles basic `+` and `-` on indices, not complex expressions

## Future Enhancements

- Track `slice.len` dynamically
- Interprocedural bounds tracking
- More sophisticated arithmetic expression evaluation
- Range refinement from conditionals (e.g., `if (i < arr.len)` refines `i` range)

## Test Fixtures

See `test/fixtures/slice_bounds_engine/` for comprehensive test cases:

- `definite_oob_literal.zig` - Literal index out of bounds
- `negative_index.zig` - Negative index detection
- `safe_access.zig` - Safe accesses (no violations)
- `string_literal_oob.zig` - String literal bounds
- `loop_bounds.zig` - Loop-based potential violations

## Implementation

- Main checker: [src/checkers/slice_bounds_engine.zig](../src/checkers/slice_bounds_engine.zig)
- Scan logic: [src/checkers/slice_bounds/scan.zig](../src/checkers/slice_bounds/scan.zig)
- Evaluator: [src/checkers/slice_bounds/evaluator.zig](../src/checkers/slice_bounds/evaluator.zig)
