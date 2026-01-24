# Release procedure

1. Update `build.zig.zon` to the target version (e.g. `0.2.1`).
2. Update any README tag references (e.g. the `zig fetch` example).
3. Run the scripted checklist:

   ```bash
   just release-check TAG=v0.2.1
   ```

   If `just` is not available:

   ```bash
   ./scripts/release-check.sh v0.2.1
   ```

4. Tag and publish the release from the checked commit.
