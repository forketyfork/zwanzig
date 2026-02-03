# Configuration

Create `.zwanzig.json` for persistent settings. It loads automatically from the current directory, or specify a path with `--config`.

## Example `.zwanzig.json`

```json
{
  "enabled_rules": ["empty-catch-engine", "dupe-import", "todo"],
  "max_worklist_steps": 200000,
  "max_states_per_point": 50
}
```

Or to disable specific rules:

```json
{
  "disabled_rules": ["todo", "unused-decl"],
  "max_worklist_steps": 200000,
  "max_states_per_point": 50
}
```

## Configuration precedence

1. CLI flags (`--do` and `--skip`) always override config file settings
2. If no CLI flags are provided, config file settings are used (if present)
3. If no config file exists and no CLI flags are provided, the default blocklist applies (`sentinel-alloc`)
4. If a config file exists but does not include `enabled_rules`/`disabled_rules`, all rules and checkers run

## Using a custom config file

```bash
zwanzig --config path/to/custom.json src/
```

## Override limits via CLI

```bash
zwanzig --max-steps 300000 --max-states-per-point 100 src/
```

## Enable loop-header widening

```bash
zwanzig --use-widening src/
```

Widening is on by default. Use `--use-widening` to force it on from the CLI (overriding config), or set `use_widening: false` in config to disable it. Widening helps convergence on loops by applying sound approximations at loop headers. The per-point state cap (`--max-states-per-point`) remains as a safety net.

## Config file format

- `enabled_rules`: Array of rule names to run (allowlist mode)
- `disabled_rules`: Array of rule names to skip (blocklist mode)
- `max_worklist_steps`: Maximum worklist steps per engine run (positive integer)
- `max_states_per_point`: Maximum unique states per CFG point (positive integer)
- `use_widening`: Enable loop-header widening for convergence (boolean, default: true)
- `resource_models`: Array of custom resource model definitions (see below)
- `escape_models`: Array of escape model definitions for `stack-escape-engine` (see below)
- `escape_max_depth`: Max helper-call depth for stack escape tracking (positive integer, default: 3)
- `enabled_rules` and `disabled_rules` are mutually exclusive - only one can be present

Sample config: [docs/zwanzig.sample.json](zwanzig.sample.json)

## Custom resource models

Define custom resource acquisition/release patterns for `store-violations-engine`. Useful for project-specific APIs or third-party libraries.

### Example `.zwanzig.json` with resource models

```json
{
  "resource_models": [
    {
      "kind": "open",
      "method_name": "acquire",
      "return_type": "MyResource"
    },
    {
      "kind": "close",
      "method_name": "release",
      "receiver_type": "MyResource"
    },
    {
      "kind": "alloc",
      "fqn": "my_pool.allocate"
    },
    {
      "kind": "free",
      "fqn": "my_pool.deallocate"
    },
    {
      "kind": "free_owned",
      "method_name": "deinit",
      "receiver_type": "*MyType"
    }
  ]
}
```

### Resource model fields

| Field | Description |
|-------|-------------|
| `kind` | Resource operation type: `alloc`, `free`, `free_owned`, `open`, or `close` |
| `method_name` | Method name to match (e.g., `"acquire"`) |
| `receiver_type` | Type of the receiver object (e.g., `"MyResource"`) |
| `return_type` | Return type of the function (e.g., `"FileHandle"`) |
| `fqn` | Fully-qualified name pattern (e.g., `"my_module.create"`) |

### Match precedence

1. Config-defined models (checked first, in order)
2. Built-in patterns (`alloc`/`free`, `create`/`destroy`, `open`/`close`)
3. Type-based detection (return types like `File`, `Dir`, etc.)

### `free_owned`

Use `free_owned` for APIs like `deinit` that free resources *owned by* a value but do not free the value itself. For example, `std.ArrayList.deinit` frees its buffer but not the list struct.

## Stack escape models

Define escape/capture rules for `stack-escape-engine`.
`resource_models` entries with `kind: "alloc"` are also used to classify heap-backed values.

### Example `.zwanzig.json` with escape models

```json
{
  "escape_max_depth": 3,
  "escape_models": [
    {
      "fqn": "std.process.Child.init",
      "param_indices": [0],
      "captures_into": "return"
    },
    {
      "method_name": "append",
      "receiver_type": "std.ArrayList",
      "param_indices": [0],
      "captures_into": "receiver"
    }
  ]
}
```

### Escape model fields

| Field | Description |
|-------|-------------|
| `fqn` | Fully-qualified name pattern (e.g., `"std.process.Child.init"`) |
| `method_name` | Method name to match (e.g., `"append"`) |
| `receiver_type` | Type of the receiver object (e.g., `"std.ArrayList"`) |
| `param_indices` | Indices of arguments that are captured (0-based) |
| `captures_into` | Where the capture escapes: `return`, `receiver`, `global`, or `thread` |
