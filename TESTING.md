# Manual Test Simulation

This document demonstrates the expected behavior of the zwanzig static analyzer.

## Test Case 1: Bad Example (examples/bad_example.zig)

**Input File:**
```zig
const std = @import("std");

pub fn main() !void {
    // This is a bad example - empty catch blocks
    const file = std.fs.cwd().openFile("test.txt", .{}) catch {}; // Violation!
    _ = file;

    // Another bad example with error capture
    const data = readData() catch |err| {}; // Violation!
    _ = data;

    // This is also bad
    processFile("myfile.txt") catch {}; // Violation!
}

fn readData() ![]const u8 {
    return error.NotImplemented;
}

fn processFile(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}
```

**Expected Output:**
```
Found 3 violation(s):
examples/bad_example.zig:5:48: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
examples/bad_example.zig:9:29: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
examples/bad_example.zig:13:33: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
```

**Exit Code:** 1 (violations found)

## Test Case 2: Good Example (examples/good_example.zig)

**Input File:**
```zig
const std = @import("std");

pub fn main() !void {
    // Good example - properly handling errors
    const file = std.fs.cwd().openFile("test.txt", .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return err;
    };
    defer file.close();

    // Good example - returning the error
    const data = readData() catch |err| {
        return err;
    };
    _ = data;

    // Good example - providing fallback value
    processFile("myfile.txt") catch |err| {
        std.debug.print("Error processing file: {}\n", .{err});
        return;
    };

    // Good example - using unreachable for truly impossible errors
    const result = getValue() catch unreachable;
    _ = result;
}

fn readData() ![]const u8 {
    return error.NotImplemented;
}

fn processFile(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}

fn getValue() !u32 {
    return 42;
}
```

**Expected Output:**
```
No violations found.
```

**Exit Code:** 0 (no violations)

## Unit Test Results

The `empty_catch.zig` file includes comprehensive unit tests:

1. **Test: Empty catch block** - Detects `catch {}`
2. **Test: Non-empty catch block** - Does not flag catch blocks with code
3. **Test: Catch with error capture but empty body** - Detects `catch |err| {}`
4. **Test: Multiple catches** - Correctly counts multiple violations in one file

All tests are expected to pass when run with `zig build test`.

## Architecture Validation

The implementation follows the extensible architecture requirements:

1. **Core Analyzer** (`src/analyzer.zig`):
   - File reading and parsing
   - Rule registry system
   - Violation collection and reporting

2. **Rule Interface** (`src/rule.zig`):
   - Defines the `Rule` struct with function pointer for checks
   - Defines the `Violation` struct for reporting issues
   - Allows any module to implement rules

3. **Extensibility**:
   - New rules can be added by creating files in `src/rules/`
   - Rules implement the `Rule` interface
   - Rules are registered in `main.zig` before analysis

4. **CLI Interface** (`src/main.zig`):
   - Takes file paths as arguments
   - Initializes analyzer and registers rules
   - Reports results and exits with appropriate code

## How to Add a New Rule

1. Create `src/rules/my_rule.zig`:
```zig
const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Violation = @import("../rule.zig").Violation;

pub const MyRule = struct {
    pub const rule: Rule = Rule{
        .name = "my-rule",
        .checkFn = check,
    };

    fn check(source: []const u8, file_path: []const u8, violations: *std.ArrayList(Violation)) !void {
        // Implementation here
    }
};
```

2. Register in `src/main.zig`:
```zig
const MyRule = @import("rules/my_rule.zig").MyRule;
// ...
try analyzer.registerRule(&MyRule.rule);
```

This demonstrates the sound, extensible architecture requested in the requirements.
