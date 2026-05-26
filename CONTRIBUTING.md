# Contributing to Zwanzig

## Getting started

You'll need Zig 0.15.2 and Git.

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

## Changelog

For any user-visible change, add a short entry to the `## [Unreleased]` section of `CHANGELOG.md` under `### Added`, `### Changed`, `### Fixed`, or `### Removed` as appropriate. Keep entries user-focused and include the issue or PR number, e.g. `(#42)`. Skip the entry for purely internal changes (refactors, test-only changes, CI tweaks) that a user would not notice. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## Pull requests

1. Fork the repo
2. Create a branch (`git checkout -b feature/my-rule`)
3. Make changes
4. Run `zig build test` and `zig fmt src/`
5. Update `CHANGELOG.md` if your change is user-visible
6. Commit with a clear message
7. Open a PR

## What makes a good rule

- Low false positive rate
- Clear, actionable error messages
- Detects real problems, not style preferences
- Fast enough to run on every file

## Questions

Open an issue on GitHub.

## License

Contributions are MIT-licensed.
