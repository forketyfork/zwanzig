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

## Frontend artifacts

The release workflow builds one archive per supported platform for each
embedded frontend: Zig 0.15.2 and Zig 0.16.0. The frontend is part of every
archive name (`zig-0.15.2` or `zig-0.16.0`), and the workflow validates both
frontends before publishing any assets.

The Zig 0.15.2 artifact is maintained through v0.17.x. v0.18.0 is the first
planned release that drops it; users who still analyze Zig 0.15.2 projects
should remain on the latest v0.17.x release.
