# Test scenarios

## Bad example (examples/bad_example.zig)

Input:
```zig
const std = @import("std");

pub fn main() !void {
    const file = std.fs.cwd().openFile("test.txt", .{}) catch {};
    _ = file;

    const data = readData() catch |err| {};
    _ = data;

    processFile("myfile.txt") catch {};
}

fn readData() ![]const u8 {
    return error.NotImplemented;
}

fn processFile(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}
```

Expected output:
```
Found 3 violation(s):
examples/bad_example.zig:5:48: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
examples/bad_example.zig:9:29: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
examples/bad_example.zig:13:33: empty-catch: Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.
```

Exit code: 1

## Good example (examples/good_example.zig)

Input:
```zig
const std = @import("std");

pub fn main() !void {
    const file = std.fs.cwd().openFile("test.txt", .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return err;
    };
    defer file.close();

    const data = readData() catch |err| {
        return err;
    };
    _ = data;

    processFile("myfile.txt") catch |err| {
        std.debug.print("Error processing file: {}\n", .{err});
        return;
    };

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

Expected output:
```
No violations found.
```

Exit code: 0

## Unit tests

Run with `zig build test`.

## Adding a rule

To verify your rule works:

1. Create `src/rules/my_rule.zig` with embedded tests
2. Add example files in `examples/` (both passing and failing cases)
3. Register the rule in `main.zig`
4. Run `zig build test`
5. Run `zig build run -- examples/my_bad_example.zig` and check output
