# Release procedure

1. Update `build.zig.zon` to the target version (e.g. `0.3.0`).
2. Update version-pinned examples in `README.md` and `docs/USAGE.md`. Regular CI checks tagged source URLs and `ZWANZIG_VERSION` against `build.zig.zon`.
3. Run the scripted checklist:

   ```bash
   just release-check v0.3.0
   ```

   If `just` is not available:

   ```bash
   ./scripts/release-check.sh v0.3.0
   ```

4. Tag and publish the release from the checked commit.
