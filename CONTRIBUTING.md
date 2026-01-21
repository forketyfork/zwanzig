# Contributing to Zwanzig

Thank you for your interest in contributing to Zwanzig, a static analyzer for Zig code!

## Getting Started

### Prerequisites

- Zig 0.11.0 or later
- Git

### Building

```bash
git clone https://github.com/forketyfork/zwanzig.git
cd zwanzig
zig build
```

### Running Tests

```bash
zig build test
```

### Project Structure

```
zwanzig/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── analyzer.zig       # Core analyzer engine
│   ├── rule.zig           # Rule interface
│   └── rules/
│       └── empty_catch.zig # Empty catch block rule
├── examples/
│   ├── bad_example.zig    # Code with violations
│   └── good_example.zig   # Proper error handling
├── build.zig              # Build configuration
└── README.md
```

## Adding a New Rule

Follow these steps to add a new linting rule:

### 1. Create the Rule File

Create a new file in `src/rules/` (e.g., `src/rules/my_rule.zig`):

```zig
const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Violation = @import("../rule.zig").Violation;

/// Description of what your rule checks
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
        // Your rule implementation here
        // Parse the source code and detect violations
        
        // Example: Report a violation
        try violations.append(Violation{
            .file_path = file_path,
            .line = 10,
            .column = 5,
            .rule_name = "my-rule-name",
            .message = "Description of what's wrong",
        });
    }
};

// Add unit tests
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

### 2. Register the Rule

Update `src/main.zig` to import and register your rule:

```zig
const MyRule = @import("rules/my_rule.zig").MyRule;

// In main() function, after analyzer initialization:
try analyzer.registerRule(&MyRule.rule);
```

### 3. Add Tests

Make sure your rule includes comprehensive unit tests covering:
- Cases that should trigger violations
- Cases that should NOT trigger violations
- Edge cases

### 4. Add Examples

Create example files in the `examples/` directory showing:
- Bad patterns your rule detects
- Good patterns that avoid violations

### 5. Update Documentation

Update the README.md to document your new rule:
- What it checks for
- Why it matters
- Bad example
- Good example

## Code Style

- Follow standard Zig formatting (`zig fmt`)
- Write clear, descriptive comments
- Include doc comments for public functions
- Keep functions focused and single-purpose

## Testing Guidelines

- All rules must have unit tests
- Test both positive and negative cases
- Use descriptive test names
- Clean up resources properly

## Pull Request Process

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-rule`)
3. Make your changes
4. Run tests (`zig build test`)
5. Format code (`zig fmt src/`)
6. Commit with clear messages
7. Push to your fork
8. Open a Pull Request

## Rule Design Principles

Good rules should be:

1. **Actionable**: Clearly explain what's wrong and how to fix it
2. **Accurate**: Minimize false positives
3. **Performant**: Analyze efficiently
4. **Well-documented**: Include examples and rationale
5. **Testable**: Have comprehensive test coverage

## Questions?

Open an issue on GitHub or start a discussion.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
