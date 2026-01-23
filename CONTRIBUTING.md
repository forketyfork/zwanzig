# Contributing to Zwanzig

## Getting started

You'll need Zig 0.11.0 or later and Git.

```bash
git clone https://github.com/forketyfork/zwanzig.git
cd zwanzig
zig build
zig build test
```

## Project layout

```
zwanzig/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── analyzer.zig       # Analysis engine
│   ├── rule.zig           # Rule interface
│   └── rules/             # Rule implementations
├── examples/
│   ├── bad_example.zig
│   └── good_example.zig
├── build.zig
└── README.md
```

## Adding a new rule

### 1. Create the rule file

Create `src/rules/my_rule.zig`:

```zig
const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Violation = @import("../rule.zig").Violation;

pub const MyRule = struct {
    pub const rule: Rule = Rule{
        .name = "my-rule-name",
        .checkFn = check,
    };

    fn check(
        source: []const u8,
        file_path: []const u8,
        violations: *std.ArrayList(Violation)
    ) !void {
        // Parse source and detect problems

        try violations.append(Violation{
            .file_path = file_path,
            .line = 10,
            .column = 5,
            .rule_name = "my-rule-name",
            .message = "Description of what's wrong",
        });
    }
};

test "my rule detects violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var violations = std.ArrayList(Violation).init(allocator);
    defer violations.deinit();

    const code = "// test code here";
    try MyRule.rule.check(code, "test.zig", &violations);

    try testing.expectEqual(@as(usize, 1), violations.items.len);
}
```

### 2. Register the rule

In `src/main.zig`:

```zig
const MyRule = @import("rules/my_rule.zig").MyRule;

// In main(), after analyzer init:
try analyzer.registerRule(&MyRule.rule);
```

### 3. Add tests

Cover these cases:
- Code that should trigger violations
- Code that should pass
- Edge cases (empty files, malformed code)

### 4. Add examples

Create files in `examples/` showing bad patterns your rule catches and the corrected versions.

### 5. Update the README

Document what your rule checks, why it matters, and show before/after examples.

## Code style

- Run `zig fmt` before committing
- Write self-documenting code; use comments sparingly
- Keep functions small and focused

## Testing

All rules need tests. Put them in the same file as the rule implementation using Zig's `test` blocks.

## Pull requests

1. Fork the repo
2. Create a branch (`git checkout -b feature/my-rule`)
3. Make changes
4. Run `zig build test` and `zig fmt src/`
5. Commit with a clear message
6. Open a PR

## What makes a good rule

- Low false positive rate
- Clear, actionable error messages
- Detects real problems, not style preferences
- Fast enough to run on every file

## Questions

Open an issue on GitHub.

## License

Contributions are MIT-licensed.
