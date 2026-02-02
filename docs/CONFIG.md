# Configuration

Create `.zwanzig.json` for persistent settings. It's loaded automatically from the current directory, or specify a path with `--config`.

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

Widening is enabled by default. Use `--use-widening` to force it on from the CLI (overriding config), or set `use_widening: false` in the config file to disable it. Widening improves convergence of the analysis engine on loops by applying sound approximations at loop headers. The per-point state cap (`--max-states-per-point`) remains as a safety net.

## Config file format

- `enabled_rules`: Array of rule names to run (allowlist mode)
- `disabled_rules`: Array of rule names to skip (blocklist mode)
- `max_worklist_steps`: Maximum worklist steps per engine run (positive integer)
- `max_states_per_point`: Maximum unique states per CFG point (positive integer)
- `use_widening`: Enable loop-header widening for convergence (boolean, default: true)
- `resource_models`: Array of custom resource model definitions (see below)
- `enabled_rules` and `disabled_rules` are mutually exclusive - only one can be present

Sample config: [docs/zwanzig.sample.json](zwanzig.sample.json)

## Custom resource models

The `resource_models` configuration allows defining custom resource acquisition/release patterns for the `store-violations-engine` checker. This is useful for project-specific APIs or third-party libraries.

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
    }
  ]
}
```

### Resource model fields

| Field | Description |
|-------|-------------|
| `kind` | Resource operation type: `alloc`, `free`, `open`, or `close` |
| `method_name` | Method name to match (e.g., `"acquire"`) |
| `receiver_type` | Type of the receiver object (e.g., `"MyResource"`) |
| `return_type` | Return type of the function (e.g., `"FileHandle"`) |
| `fqn` | Fully-qualified name pattern (e.g., `"my_module.create"`) |

### Match precedence

1. Config-defined models (checked first, in order)
2. Built-in patterns (`alloc`/`free`, `create`/`destroy`, `open`/`close`)
3. Type-based detection (return types like `File`, `Dir`, etc.)
