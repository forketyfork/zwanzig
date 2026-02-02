# Output formats

Use `--format` to choose the output style.

## Text (default)

```bash
zwanzig --format text src/
# or simply
zwanzig src/
```

Output example:
```
Found 2 issue(s):
src/main.zig:10:5: error: [empty-catch] Empty catch block detected
src/utils.zig:23:1: warning: [unused-decl] Unused declaration: helper
```

## JSON

```bash
zwanzig --format json src/
```

Example:
```json
{
  "diagnostics": [
    {
      "file": "src/main.zig",
      "rule": "empty-catch",
      "severity": "error",
      "message": "Empty catch block detected",
      "location": {
        "start": {"line": 10, "column": 5},
        "end": {"line": 10, "column": 20}
      }
    },
    {
      "file": "src/utils.zig",
      "rule": "unused-decl",
      "severity": "warning",
      "message": "Unused declaration: helper",
      "location": {
        "start": {"line": 23, "column": 1},
        "end": {"line": 23, "column": 25}
      }
    }
  ],
  "total": 2
}
```

JSON works well with CI pipelines and editor integrations.

## SARIF

```bash
zwanzig --format sarif src/
```

[SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html) format, supported by GitHub code scanning, VS Code's SARIF extension, and SonarQube.
