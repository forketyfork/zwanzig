# Zig 0.16.0 Migration Breakage Inventory

Status: completed 2026-08-21 against the Phase 0 merge at `5d53c55`.

This inventory records the first compile and test pass with Zig 0.16.0. It is
the sizing input for the compat seams in Phase 2; no 0.16-specific source
patches from the spike are part of this change.

## Method and environment

- The default shell remained pinned to Zig 0.15.2.
- `nix develop .#zig016 -c zig version` reported `0.16.0`.
- The 0.16 shell was tested on `aarch64-darwin` without the 0.15.2 macOS SDK
  workaround. After throwaway source patches unblocked the compiler,
  `zig build` completed successfully, so the workaround is not required by
  the 0.16 linker on this host.
- Zig caches were redirected into `.tmp/` because the default sandbox cache
  locations are read-only.
- The negative gate probe was run before any spike patches. It did not reach
  `src/compat.zig`: Zig 0.16 stopped first at `build.zig:87` and `build.zig:132`
  because `std.fs.cwd()` no longer exists. This is the known limitation that
  the migration plan anticipated for a gate in `src/`.

The first project compile after the minimal spike-only build-script/gate
unblocking reported 16 errors for the main test target and 8 for the fixture
test target. The external estimate of 19 main and 7 fixture errors was
therefore not reproduced. After the remaining blocking errors were removed
with throwaway patches, the main test binary compiled and ran 425 of 430
tests; the five failures were caused by spike stubs or the intentionally
version-sensitive `@Int` mismatch test. The fixture test target passed, and
`zig build test-fixtures` passed.

`zig build check-fixtures` reported 15 failures under both Zig 0.15.2 and
0.16.0. The paths and diagnostics were identical, so these are pre-existing
fixture-compilation failures rather than 0.16 regressions. They should not be
used as the Phase 2 compatibility count.

## Inventory

### Build script and I/O

Zig 0.16 requires an `Io` argument for filesystem operations. The build-script
idiom verified against Zig's own `std.Build` is:

```zig
const cwd = std.Io.Dir.cwd();
const contents = try cwd.readFileAllocOptions(
    b.graph.io,
    path,
    b.allocator,
    std.Io.Limit.limited(1024 * 1024),
    .of(u8),
    0,
);
```

Directory iteration uses `cwd.openDir(b.graph.io, path, .{ .iterate = true })`,
`iter.next(b.graph.io)`, and `dir.close(b.graph.io)`. The real Phase 2 change
must select this spelling at compile time while retaining the 0.15.2 spelling.

The operational filesystem sites requiring an I/O context are spread across:

- `src/analyzer.zig`, `src/cache.zig`, `src/cli/config_merge.zig`,
  `src/cli/run.zig`, `src/config.zig`, `src/dot_helpers.zig`,
  `src/file_discovery.zig`, `src/formatters/console.zig`, and
  `src/project_unused_decl.zig`;
- `test/fixture_runner.zig` and filesystem-heavy unit tests; and
- `build.zig`, which cannot import the project compat module.

The `std.fs.path` helpers and `std.fs.max_path_bytes` usages are path-only
operations and did not produce 0.16 errors in this pass. The migration should
keep them in the shared layer unless a later compiler check proves otherwise.

Other I/O spelling changes observed:

- `std.fs.File` becomes `std.Io.File`; file readers and writers are created
  with an `Io` instance.
- `std.fs.openFileAbsolute` becomes `std.Io.Dir.openFileAbsolute`.
- `Dir.realpath` becomes `Dir.realPath` for a directory handle and
  `Dir.realPathFile` for a path inside it.
- `Dir.writeFile`, `Dir.createFile`, `Dir.deleteTree`, and related methods gain
  the `Io` parameter.
- `std.time.timestamp()` is gone; timestamp acquisition must use the 0.16 time
  API through the compat layer.

### Concurrency and process setup

`src/cli/run.zig` uses `std.Thread.Pool`, `std.Thread.WaitGroup`, and the
worker-wrapper pattern at lines 46–77. `std.Thread.Pool` is absent in 0.16;
the replacement surface is `std.Io.Threaded` plus `std.Io.Group`.

`src/cache.zig` uses `std.Thread.Mutex`. The 0.16 replacement is
`std.Io.Mutex`, whose `lock` and `unlock` operations also receive the `Io`
instance. The executor and cache mutex should be handled by the same compat
context so `--threads` retains its current semantics.

The application entry point also needs a setup change: Zig 0.16 removes
`std.heap.GeneralPurposeAllocator` and `std.process.argsAlloc`. A 0.16 entry
point receives `std.process.Init`, which supplies the allocator and I/O context;
arguments are consumed through `std.process.Args.Iterator`. This is an
additional breakage outside the initial filesystem error batch.

### Writer and formatting remnants

Phase 0 removed the lowercase `std.io` spelling, but Zig 0.16 also removes the
`std.ArrayList(u8).writer(allocator)` helper. Remaining sites found by the
spike are:

- `src/cfg/dot.zig`;
- the three DOT generators in `src/engine/dot.zig`;
- the analyzer SARIF test in `src/analyzer.zig`; and
- the two SARIF formatter tests in `src/formatters/sarif.zig`.

They should use `std.Io.Writer.Allocating` or the shared writer adapter. No
`std.io` references remain in the project source or build script.

### ZIR decoding

The first 0.16 compiler diagnostic is `src/zir/bridge.zig:308`:
`Zir.declIterator` no longer exists. The second call site is the nested
declaration traversal at `src/zir/bridge.zig:329`.

Zig 0.16 exposes `typeDecls`, `getStructDecl`, `getUnionDecl`, `getEnumDecl`,
and `getSwitchBlock` instead. The remaining bridge instruction and payload
accesses did not produce an additional compiler diagnostic after the
declaration traversal was isolated in the spike, but they must be moved behind
the version-specific ZIR adapter before claiming typed-analysis equivalence.

The existing `Zir.hasCompileErrors()` guard remains present in both versions.
The Phase 0 test uses `@Int`, which is rejected by the 0.15.2 frontend but is
valid in 0.16. The dual-version test matrix therefore needs the inverse
0.15-only fixture using `@Type`; the explicit `AstGenFailed` behavior is still
the correct mismatch contract.

### Build metadata parsing

The 0.16 `std.zon.parse.fromSlice` API requires the result type to contain no
allocator-owned pointers. `build.zig`'s `PackageMetadata.version: []const u8`
therefore needs `std.zon.parse.fromSliceAlloc` on 0.16, while 0.15.2 retains
the existing call. This is another compile-time branch required in the build
script.

### Fixture and rule compatibility

The fixture runner compiled and executed under Zig 0.16 after adding the
required I/O arguments. The independent fixture compiler showed no new
0.16-only failures: all 15 failures also occur under Zig 0.15.2. This supports
keeping AST/token rules shared, while the test matrix must exclude or
version-gate fixtures that are intentionally invalid as standalone modules.

## Phase 2 implications

The implementation order should be:

1. Add the `build.zig` version branch for directory handles and ZON parsing.
2. Introduce a shared application I/O context and thread it through file,
   cache, config, discovery, formatter, and DOT operations.
3. Add executor and mutex adapters for `std.Thread.Pool`/`WaitGroup` versus
   `std.Io.Threaded`/`Group`/`Mutex`.
4. Move declaration traversal and ZIR decoding into the two version-specific
   adapters.
5. Finish the residual allocating-writer sites, then add the dual-version
   fixture and cache-equivalence tests described by Phase 3.
