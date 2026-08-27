# Zig 0.16.0 Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship zwanzig as two engine binaries built from one source tree — one embedding the Zig 0.15.2 frontend (for analyzing 0.15.2 projects) and one embedding the Zig 0.16.0 frontend (for 0.16.0 projects) — with explicit failure on frontend/language mismatch.

**Architecture:** Zwanzig embeds `std.zig` (parser, AstGen, Zir) from the toolchain that compiles it, and each frontend accepts a different language version, so one binary cannot do typed/ZIR analysis for both. Version-specific code (I/O context, thread executor, ZIR decoding) is isolated behind `src/compat/` adapters selected at `comptime` on `builtin.zig_version`; the analyzer, CFG, engine, and rules stay shared. A compile-time gate rejects untested toolchains.

**Tech Stack:** Zig 0.15.2 and 0.16.0, Nix flakes (mitchellh/zig-overlay), just, GitHub Actions.

**Spec:** The "Verified findings" section below — every claim in it was verified against this repository and against the `0.15.2`/`0.16.0` tags of ziglang/zig on 2026-08-21.

## Global Constraints

- Default dev toolchain stays **exactly Zig 0.15.2** (`flake.nix` devShell `default`); `build.zig.zon` keeps `.minimum_zig_version = "0.15.2"`. The upper/exact support boundary is enforced by `src/compat.zig`, not by `build.zig.zon`.
- Every task ends with `just test` and `just lint` green under the default (0.15.2) shell. `just lint` runs zwanzig on its own source.
- All code formatted with `zig fmt` from Zig 0.15.2, the sole canonical formatter; the 0.16.0 CI leg validates the remaining lint checks and analyzer behavior.
- ArrayList init uses `.empty`, allocator passed to methods (Zig 0.15.2 style, see CLAUDE.md).
- No silent degradation: a frontend/language mismatch must produce an explicit failure, never incomplete type information (project rule: no speculative fallbacks).
- User-visible changes get a `CHANGELOG.md` entry under `## [Unreleased]`.
- Once dual support lands (Phase 2+), all zwanzig source must stay within the syntax subset parseable by **both** embedded frontends.
- Temporary files go to `.tmp/` in the project root, never `/tmp`.

## Verified findings

Facts this plan is built on. "Verified" means checked against the actual repo code and/or the actual Zig source at tags `0.15.2` and `0.16.0` (Codeberg).

1. **ZIR generation is in-process** at `src/zir/bridge.zig:69` (`AstGen.generate`); declaration traversal uses `zir.declIterator` at `src/zir/bridge.zig:302` and `:322`. (`src/zir_bridge.zig` is only a re-export shim.)
2. **`AstGen.generate` returns only `Allocator.Error`** in both 0.15.2 and 0.16.0 (`pub fn generate(gpa: Allocator, tree: Ast) Allocator.Error!Zir`). Language errors are recorded *inside* the returned Zir and only visible via `zir.hasCompileErrors()`. The bridge never calls it, so unsupported syntax currently yields silently incomplete type info. Reproduced locally: `zig ast-check` under 0.15.2 rejects `@Int` ("invalid builtin function") while `@Type` passes.
3. **`Ast.parse` and `AstGen.generate` signatures are unchanged** between 0.15.2 and 0.16.0 — the bridge entry points are stable.
4. **Zir decoding API changed**: 0.16.0 removed `declIterator` and added `typeDecls`, `getStructDecl`, `getUnionDecl`, `getEnumDecl`, `getSwitchBlock` (verified by diffing `lib/std/zig/Zir.zig` between tags). `hasCompileErrors` exists in both.
5. **`@Type` was replaced** in 0.16 by 8 builtins including `@Int` (proposal #10710) — so each frontend rejects the other's metaprogramming syntax at AstGen time.
6. **0.16 I/O**: all fs/process/time APIs require a `std.Io` instance; `std.fs.cwd()` → `std.Io.Dir.cwd()`; `std.Thread.Pool` is removed in favor of `std.Io.Group`/`Io.async`/`Io.Mutex` with `std.Io.Threaded` as the threaded backend (verified in 0.16.0 release notes and `lib/std/Io.zig`).
7. **The lowercase `std.io` alias exists in 0.15.2 (`pub const io = Io`) and is gone in 0.16.0.** The new `std.Io.Writer` API is available in 0.15.2, so writer modernization can land now and stay shared.
8. **Repo footprint**: `std.fs` is used across ~15 files (heaviest: `src/cache.zig`, `src/cli/run.zig`); `std.Thread.Pool`/`WaitGroup` in `src/cli/run.zig:45–75`; `std.io.*` at 8 sites (all listed in Task 2); legacy-style `format` methods at `src/types/type_info.zig:91` and `src/cache.zig:60`.
9. **Cache key** (`src/cache.zig`) hashes only the zwanzig `tool_version`; `builtin.zig_version` appears nowhere in the codebase. Two zwanzig binaries with different embedded frontends would share `.zwanzig-cache` entries.
10. **Toolchain pins**: `flake.nix:35` (0.15.2 + macOS 26.x SDK workaround for [ziglang/zig#31756](https://codeberg.org/ziglang/zig/issues/31756)), `.github/workflows/release.yml:20`/`48` (0.15.2), single CI build environment.
11. **`build.zig` itself uses `std.fs.cwd()`** at lines 87 and 132 and is compiled by whichever toolchain builds the project — it must compile under both, via `comptime` branches, and cannot live behind `src/compat/`.
12. **Unverified (to be settled by Task 6):** the exact 0.16 compile-error inventory (an external probe reported 19 main-test + 7 fixture-test errors — plausible, not reproduced) and the assumption that AST/token rules need no per-version changes.

Sources: [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html), [0.16.0 announcement](https://ziglang.org/news/0.16.0-released/), `Zir.zig`/`AstGen.zig`/`Ast.zig`/`std.zig`/`Io.zig` at tags [0.15.2](https://codeberg.org/ziglang/zig/src/tag/0.15.2/lib/std) and [0.16.0](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std).

## Plan structure

- **Phase 0 (Tasks 1–4):** hardening that is correct and shippable on 0.15.2 alone, independent of the migration schedule.
- **Phase 1 (Tasks 5–6):** 0.16 toolchain availability and a definitive breakage inventory.
- **Checkpoint (Task 7):** expand Phases 2–4 into a detailed follow-up plan *from the inventory* — Tasks 8–11 below are that expansion; they were deliberately not written before the inventory existed, because writing 0.16-specific code first would have been guesswork.
- **Phases 2–4 (Tasks 8–11):** the detailed follow-up produced at the Task 7 checkpoint — frontend fixture matrix, dual-frontend CI, dual-frontend releases, and closing the open decisions. The compat seams (the Phase 2 core) are already implemented on `main`.

---

### Task 1: Fail explicitly when AstGen records compile errors

The bridge treats `AstGen.generate`'s error return as the failure signal, but that error set is `Allocator.Error` only — real language errors (e.g. 0.16-only syntax analyzed by a 0.15.2 binary) are recorded inside the Zir and currently ignored, producing silently incomplete type info.

**Files:**
- Modify: `src/zir/bridge.zig:69-71` (guard) and test section (~line 1205)
- Modify: `src/source.zig:116-120` (log the degradation reason)
- Modify: `CHANGELOG.md`, `CLAUDE.md` (stale `src/zir_bridge.zig` reference)

**Interfaces:**
- Consumes: `Zir.hasCompileErrors(code: Zir) bool` (exists in 0.15.2 and 0.16.0).
- Produces: `loadFromSource` now returns `error.AstGenFailed` for source the embedded frontend cannot lower; `Source.hasTypeInfo()` returns `false` for such files (existing degradation path, unchanged signature).

- [x] **Step 1: Write the failing test** in `src/zir/bridge.zig`, next to `test "ZirBridge parse error handling"` (~line 1205):

```zig
test "ZirBridge rejects source with AstGen compile errors" {
    const allocator = std.testing.allocator;

    // `@Int` is a Zig 0.16 builtin; the 0.15.2 frontend parses it fine but
    // AstGen records "invalid builtin function" inside the Zir instead of
    // returning an error. Without the hasCompileErrors guard, loadFromSource
    // would succeed with incomplete type information.
    const code: [:0]const u8 = "const T = @Int(.signed, 8);";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    const result = bridge.loadFromSource(&source);
    try std.testing.expectError(error.AstGenFailed, result);
}
```

- [x] **Step 2: Run the test to verify it fails**

Run: `nix develop -c zig build test`
Expected: FAIL — `loadFromSource` currently succeeds on this input, so `expectError` reports "expected error.AstGenFailed, found …void".

- [x] **Step 3: Implement the guard** in `loadFromSource` (`src/zir/bridge.zig:69-71`). Replace:

```zig
        const zir_result = AstGen.generate(self.allocator, tree.*);
        const zir = zir_result catch return error.AstGenFailed;
        self.zir = zir;
```

with:

```zig
        // AstGen.generate only errors on OOM; language errors are recorded
        // inside the Zir and must be checked explicitly, otherwise a frontend/
        // language mismatch yields silently incomplete type information.
        self.zir = try AstGen.generate(self.allocator, tree.*);
        if (self.zir.?.hasCompileErrors()) {
            return error.AstGenFailed;
        }
```

(Assigning `self.zir` before the check keeps ownership with the bridge, so `clear()`/`deinit()` free the Zir on the error path — the caller in `src/source.zig` calls `bridge.deinit()` on any error.)

- [x] **Step 4: Run the test to verify it passes**

Run: `nix develop -c zig build test`
Expected: PASS, including the pre-existing `"ZirBridge parse error handling"` and `"ZirBridge load simple module"` tests (proving valid source still loads).

- [x] **Step 5: Log the degradation reason** in `src/source.zig:116-120`. Replace:

```zig
        bridge.loadFromSource(self) catch {
            // ZIR generation failed - this is expected for files with parse errors
            bridge.deinit();
            return;
        };
```

with:

```zig
        bridge.loadFromSource(self) catch |err| {
            // Expected for files with parse errors or syntax this binary's
            // embedded Zig frontend does not support; typed analysis is
            // disabled for this file and AST/token rules still run.
            std.log.debug("ZIR bridge unavailable for {s}: {s}", .{ self.file_path, @errorName(err) });
            bridge.deinit();
            return;
        };
```

- [x] **Step 6: Validate, document, commit**

Run: `just test && just lint`
Update `CHANGELOG.md` under `## [Unreleased]` / `### Fixed`:

```markdown
- Typed (ZIR-based) analysis is now explicitly disabled for files the embedded Zig frontend cannot compile, instead of silently producing incomplete type information.
```

Fix the stale reference in `CLAUDE.md`: `**\`ZirBridge\`** (\`src/zir_bridge.zig\`)` → `**\`ZirBridge\`** (\`src/zir/bridge.zig\`)`.

```bash
git add src/zir/bridge.zig src/source.zig CHANGELOG.md CLAUDE.md
git commit -m "fix: reject source with AstGen compile errors in ZIR bridge"
```

---

### Task 2: Modernize writer APIs to the 0.16-compatible spelling

The lowercase `std.io` alias and the legacy `format(comptime fmt, FormatOptions, writer)` protocol are gone in 0.16. The capitalized `std.Io.Writer` API already exists in 0.15.2, so this lands now and needs no per-version code.

**Files:**
- Modify: `src/analyzer.zig:476` (alias), `:541`, `:630` (fixed streams, tests)
- Modify: `src/diagnostic.zig:432` (fixed stream, test), `:559`, `:624` (alias)
- Modify: `src/formatters/sarif.zig:29` (alias)
- Modify: `src/types/type_info.zig:91-115` (format signature), `:118-136` (test)
- Modify: `src/cache.zig:60-76` (legacy `CacheKey.format` — unused, remove)

**Interfaces:**
- Produces: `TypeInfo.format(self: TypeInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void` (new-protocol signature, also what `{f}` format specifiers expect).

- [x] **Step 1: Rename the alias sites.** In `src/analyzer.zig:476`, `src/diagnostic.zig:559`, `src/diagnostic.zig:624`, `src/formatters/sarif.zig:29`, replace `std.io.Writer.Allocating` with `std.Io.Writer.Allocating` (capitalization only — same type in 0.15.2).

- [x] **Step 2: Convert the four `fixedBufferStream` test sites.** Pattern, using `src/analyzer.zig:540-544` as the example — replace:

```zig
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try analyzer.printJsonResults(stream.writer());

    const output = stream.getWritten();
```

with:

```zig
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try analyzer.printJsonResults(&writer);

    const output = writer.buffered();
```

Apply the same shape at `src/analyzer.zig:630` (`formatter.write(&writer, ...)`), `src/diagnostic.zig:432` (`diag.format(&writer)`), and `src/types/type_info.zig:120` — where `fbs.reset()` becomes `writer.end = 0`.

- [x] **Step 3: Modernize `TypeInfo.format`.** In `src/types/type_info.zig:91`, replace the legacy signature:

```zig
    pub fn format(
        self: TypeInfo,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
```

with:

```zig
    pub fn format(self: TypeInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
```

(body unchanged), and update the test callers at lines 124/129/134 from `int_type.format("", .{}, writer)` to `int_type.format(&writer)`. Then confirm no format-string callers relied on the old protocol: `rg -n 'TypeInfo' src -g '*.zig' | rg 'print|format'` — any `writer.print("{...}", .{some_type_info})` caller must use `{f}` with the new protocol; update if found.

- [x] **Step 4: Remove dead `CacheKey.format`.** Verified: no callers (`rg -n '\.format\(' src` shows none for `CacheKey`; the cache filename is built manually at `src/cache.zig:168-181`). Delete the method at `src/cache.zig:60-76`. If a caller does turn up, modernize it to the same `(self, writer: *std.Io.Writer)` signature instead of deleting.

- [x] **Step 5: Verify no `std.io` remains**

Run: `rg -n 'std\.io\.' src build.zig`
Expected: no matches.

- [x] **Step 6: Validate and commit**

Run: `just test && just lint`
Expected: PASS. (Internal-only change — no CHANGELOG entry.)

```bash
git add src/analyzer.zig src/diagnostic.zig src/formatters/sarif.zig src/types/type_info.zig src/cache.zig
git commit -m "refactor: migrate to std.Io.Writer APIs available in both 0.15 and 0.16"
```

---

### Task 3: Include the embedded Zig frontend version in cache identity and --version

Two zwanzig binaries from the same release but different embedded frontends must not share typed-analysis cache entries, and users must be able to see which frontend a binary embeds.

**Files:**
- Modify: `src/cache.zig:47` (version hash), plus test near `src/cache.zig:330`
- Modify: `src/cli/run.zig:140-144` (`printVersion`)
- Modify: `CHANGELOG.md`; `docs/USAGE.md` if it documents `--version` output

**Interfaces:**
- Consumes: `builtin.zig_version_string` (comptime `[:0]const u8`).
- Produces: `--version` output format `zwanzig <version> (Zig frontend <zig version>)`.

- [x] **Step 1: Write the failing cache test** in `src/cache.zig` next to the existing CacheKey tests (~line 330):

```zig
test "CacheKey version hash includes the embedded Zig frontend version" {
    const rules = [_][]const u8{};
    const key = CacheKey.init("test", null, "1.0.0", false, &rules);

    // Regression guard: if version_hash were derived from the tool version
    // alone, two binaries embedding different Zig frontends would share
    // incompatible typed-analysis cache entries.
    var tool_version_only: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("1.0.0", &tool_version_only, .{});
    try std.testing.expect(!std.mem.eql(u8, &key.version_hash, &tool_version_only));
}
```

- [x] **Step 2: Run it to verify it fails**

Run: `nix develop -c zig build test`
Expected: FAIL — today `version_hash` is exactly `sha256(tool_version)`.

- [x] **Step 3: Implement.** Add `const builtin = @import("builtin");` to `src/cache.zig` imports (not currently imported). Replace line 47:

```zig
        std.crypto.hash.sha2.Sha256.hash(tool_version, &key.version_hash, .{});
```

with:

```zig
        var version_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        version_hasher.update(tool_version);
        version_hasher.update("\x00");
        version_hasher.update(builtin.zig_version_string);
        version_hasher.final(&key.version_hash);
```

- [x] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS (existing CacheKey equality/inequality tests at `src/cache.zig:322-342` still hold — the frontend string is a constant within one build).

- [x] **Step 5: Extend `--version`.** Add `const builtin = @import("builtin");` to `src/cli/run.zig` imports (not currently imported). Replace `printVersion` (`src/cli/run.zig:140-144`):

```zig
fn printVersion() !void {
    var buffer: [128]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "zwanzig {s} (Zig frontend {s})\n",
        .{ build_options.version, builtin.zig_version_string },
    );
    try std.fs.File.stdout().writeAll(message);
}
```

- [x] **Step 6: Verify manually**

Run: `nix develop -c zig build run -- --version`
Expected output: `zwanzig 0.14.0 (Zig frontend 0.15.2)` (zwanzig version as of writing; exit code 0).

- [x] **Step 7: Validate, document, commit**

Run: `just test && just lint`
Update `docs/USAGE.md` if it shows `--version` output. Add to `CHANGELOG.md` under `### Added`:

```markdown
- `--version` now reports the embedded Zig frontend version, e.g. `zwanzig 0.14.0 (Zig frontend 0.15.2)`.
```

and under `### Fixed`:

```markdown
- Analysis cache entries are no longer shared between zwanzig binaries embedding different Zig frontend versions.
```

```bash
git add src/cache.zig src/cli/run.zig CHANGELOG.md docs/USAGE.md
git commit -m "feat: include embedded Zig frontend version in cache key and --version"
```

---

### Task 4: Compile-time toolchain gate

Zwanzig depends on unstable compiler-internal APIs (`std.zig.Zir` layout), so untested toolchains — including 0.17-dev and untested patch releases — must be rejected at compile time with a clear message, not fail mysteriously at runtime.

**Files:**
- Create: `src/compat.zig`
- Modify: `src/main.zig` (reference the gate so it is semantically analyzed)

**Interfaces:**
- Produces: `src/compat.zig` — importing it anywhere enforces the gate; Phase 2 extends its `supported_zig_versions` list and adds version-selected re-exports.

- [x] **Step 1: Create `src/compat.zig`:**

```zig
//! Compile-time gate for supported Zig toolchains.
//!
//! Zwanzig embeds the std.zig frontend (parser, AstGen, Zir) of the compiler
//! that builds it, and depends on unstable compiler-internal APIs. Only the
//! exact versions listed here are tested; anything else - including dev
//! builds and untested patch releases - must fail loudly at compile time.

const std = @import("std");
const builtin = @import("builtin");

pub const supported_zig_versions = [_]std.SemanticVersion{
    .{ .major = 0, .minor = 15, .patch = 2 },
};

comptime {
    var supported = false;
    for (supported_zig_versions) |v| {
        if (builtin.zig_version.order(v) == .eq) supported = true;
    }
    if (!supported) {
        @compileError("zwanzig does not support Zig " ++ builtin.zig_version_string ++
            "; supported versions: 0.15.2 (see docs/ZIG_0_16_MIGRATION_PLAN.md)");
    }
}
```

- [x] **Step 2: Enforce it from the root.** In `src/main.zig`, add alongside the existing imports:

```zig
comptime {
    _ = @import("compat.zig");
}
```

- [x] **Step 3: Validate**

Run: `just ci`
Expected: PASS — build, tests, and lint all succeed under 0.15.2. (The negative case — the gate firing on a wrong toolchain — cannot run under the pinned shell; Task 6 Step 1 exercises it with the real 0.16.0 compiler.)

- [x] **Step 4: Commit**

```bash
git add src/compat.zig src/main.zig
git commit -m "feat: reject untested Zig toolchains at compile time"
```

---

### Task 5: Add a Zig 0.16.0 Nix dev shell

**Files:**
- Modify: `flake.nix:31-63` (add a second devShell)

**Interfaces:**
- Produces: `nix develop .#zig016` — a shell with Zig 0.16.0, `just`, and `shellcheck`, used by Task 6 and later by CI.

- [x] **Step 1: Add the shell.** In `flake.nix`, after the `devShells.default` attribute (line 63), add:

```nix
        # Zig 0.16.0 shell for the dual-frontend migration
        # (see docs/ZIG_0_16_MIGRATION_PLAN.md).
        devShells.zig016 = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            just
            shellcheck
            zig.packages.${system}."0.16.0"
          ];
        };
```

If the overlay doesn't know 0.16.0 yet, run `nix flake update zig` first (zig-overlay tracks tagged releases).

Deliberately *without* the macOS SDK workaround: it exists for a 0.15.2 linker limitation ([ziglang/zig#31756](https://codeberg.org/ziglang/zig/issues/31756)); Task 6 determines whether 0.16.0 still needs it.

- [x] **Step 2: Verify both shells**

Run: `nix develop .#zig016 -c zig version`
Expected: `0.16.0`
Run: `nix develop -c zig version`
Expected: `0.15.2` (default shell untouched).

- [x] **Step 3: Commit**

```bash
git add flake.nix flake.lock
git commit -m "build: add Zig 0.16.0 nix dev shell for migration work"
```

---

### Task 6: Produce the definitive 0.16 breakage inventory (spike)

Everything in Phases 2–4 is sized from this inventory. The spike happens on a throwaway branch (or worktree under `~/dev/worktrees/`); only the inventory document merges.

**Files:**
- Create: `docs/internal/ZIG_0_16_INVENTORY.md` (the only merged artifact)
- Throwaway branch edits: `src/compat.zig`, `build.zig`

- [x] **Step 1: Confirm the Task 4 gate fires (negative test).** On branch `spike/zig-0.16-inventory`:

Run: `nix develop .#zig016 -c zig build test 2>&1 | head -20`
Expected: compile error containing "zwanzig does not support Zig 0.16.0". Record PASS/FAIL in the inventory. (If the build instead fails earlier inside `build.zig` at the `std.fs.cwd()` calls on lines 87/132 — before `src/compat.zig` is analyzed — record that as the gate's known limitation: `build.zig` runs first, so the gate only protects `src/`.)

- [x] **Step 2: Unblock compilation minimally.** On the spike branch only: add `.{ .major = 0, .minor = 16, .patch = 0 }` to `supported_zig_versions`, and patch the two `std.fs.cwd()` calls in `build.zig` (lines 87 and 132) just enough to compile under 0.16 — per the 0.16 release notes, `fs.cwd` moved to `std.Io.Dir.cwd`; check how upstream 0.16 `init` templates and the build-system release notes obtain a directory handle in `build.zig`, and note the idiom in the inventory (it becomes the model for the real Phase 2 change).

- [x] **Step 3: Capture the full error inventory**

Run: `nix develop .#zig016 -c zig build test 2>&1 | tee .tmp/zig016-inventory.txt` (repeat with `zig build` alone if `test` stops early; iterate past blocking errors with minimal throwaway patches where needed to expose the next layer).

- [x] **Step 4: Write `docs/internal/ZIG_0_16_INVENTORY.md`** categorizing every error:
  - I/O (`std.fs`/`std.process`/`std.time` requiring `Io`) — expected across ~15 files (finding 8)
  - Concurrency (`Thread.Pool`/`WaitGroup`/`Mutex` in `src/cli/run.zig`, `src/cache.zig`)
  - ZIR decoding (`declIterator` and payload layouts in `src/zir/bridge.zig`)
  - Writer/format remnants Task 2 missed
  - Other (anything unexpected — e.g. `Ast` node/token API drift affecting rules, which would invalidate the "rules stay shared" assumption, finding 12)

  Also record: whether the macOS SDK workaround is needed for 0.16.0, the `build.zig` directory-handle idiom from Step 2, and whether the external probe's 19+7 error count was accurate.

- [x] **Step 5: Merge only the inventory**

```bash
git checkout main && git checkout spike/zig-0.16-inventory -- docs/internal/ZIG_0_16_INVENTORY.md
git add docs/internal/ZIG_0_16_INVENTORY.md
git commit -m "docs: add Zig 0.16 migration breakage inventory"
```

---

### Task 7 (checkpoint): Expand Phases 2–4 into a detailed plan

**Status: reviewed and closed.** The compat implementation is present on
`main` from the work covered by Tasks 1–6. Tasks 8 and 9 are complete. Task 10's
dual-frontend release workflow and documentation are implemented; its criteria
that require a successful release tag remain open until that release completes.

#### Status quo

- Phase 2 is implemented: `build.zig` selects the 0.15.2/0.16.0 build-script
  APIs, `src/compat.zig` selects the I/O and ZIR adapters, and the shared
  analyzer receives an explicit I/O context.
- The inventory measured 16 main-target and 8 fixture-target compile errors
  before the spike fixes. It also established that 0.16.0 does not need the
  macOS SDK workaround and that the 15 `check-fixtures` failures are pre-existing
  on both toolchains.
- The shared fixture suite, cache behavior, executor test, and `just test` /
  `just lint` checks have passed in both shells, and the fixture matrix proves
  matching and mismatching frontend syntax.
- `.github/workflows/build.yml` tests both pinned frontends, and
  `.github/workflows/release.yml` builds one named artifact per platform and
  frontend. `README.md` and `docs/USAGE.md` identify the matching artifact;
  release-tag verification is still pending.

#### Objectives

Complete the migration's remaining user-facing contract:

1. prove that shared-syntax analysis remains equivalent and that typed analysis
   succeeds only for the matching embedded frontend;
2. exercise both shells on every code change;
3. publish independently selectable 0.15.2 and 0.16.0 binaries for every
   supported platform; and
4. record the support-lifetime, formatting, and launcher decisions and keep
   them aligned with the release workflow and contributor documentation.

#### Review decisions (adopted)

1. **0.15.2 support lifetime:** retain both frontend artifacts through the
   v0.17.x release line, and make v0.18.0 the first release without a 0.15.2
   artifact. With the current v0.14.0 package as the baseline, this gives the
   first dual-frontend release and two subsequent release lines for migration.
   A fixed sunset limits the ongoing release and CI matrix while giving users a
   specific compatibility window.
2. **Canonical formatter:** keep Zig 0.15.2 as the sole `zig fmt --check`
   authority. The 0.16.0 CI leg still runs `just lint`, but its formatter check
   is skipped so formatter differences cannot redefine the repository baseline.
   This keeps formatting stable while both frontends are supported.
3. **Launcher:** defer a frontend-detecting launcher. Artifact names and the
   usage documentation select the frontend explicitly, avoiding another
   compatibility and distribution surface. Create a separate launcher plan
   only if user demand shows that filename selection is insufficient.

These decisions close the policy review for the remaining migration work.

Tasks 8–11 below are the expansion this checkpoint produces. Their acceptance
criteria use checkbox (`- [ ]`) syntax and are the tracking unit for the
remaining work.

---

### Task 8: Add the frontend fixture matrix

#### Status quo

`test/fixture_tests.zig` runs the existing rule and checker fixtures in the
current build, while `build.zig:addFixtureChecks` compiles a fixed list of
fixture directories. `src/zir/bridge.zig` has one conditional unit test for the
opposite frontend builtin, but the fixture suite does not prove the complete
matching/mismatching contract.

#### Objectives

Add a small, explicit matrix that exercises one shared fixture, one valid
0.15.2-only typed fixture using `@Type`, and one valid 0.16.0-only typed fixture
using `@Int`. In each build, the matching fixture must retain type information
and the other fixture must report unavailable type information through the
existing `Source.hasTypeInfo()` degradation path. The shared fixture must assert
the same diagnostic fields under both builds.

#### Tech Notes

- Create `test/fixtures/frontend_matrix/shared.zig`,
  `test/fixtures/frontend_matrix/zig_0_15.zig`, and
  `test/fixtures/frontend_matrix/zig_0_16.zig`. Keep the version-specific
  expressions at top level so `Source.zirBridge()` is exercised directly.
- Use the known version-specific forms from the inventory:

  ```zig
  // zig_0_15.zig — compile this fixture only with Zig 0.15.2
  const T = @Type(.{ .int = .{ .signedness = .signed, .bits = 8 } });

  // zig_0_16.zig — compile this fixture only with Zig 0.16.0
  const T = @Int(.signed, 8);
  ```

  Verify the exact `@Type` payload against the pinned 0.15.2 frontend while
  implementing; the important invariant is that it generates valid ZIR only
  under 0.15.2.
- Add a small frontend selector to `src/compat.zig`, for example a public
  `Frontend` enum and comptime `frontend` value derived from the already-gated
  `builtin.zig_version`. Use that selector in `test/fixture_tests.zig` to load
  the matching fixture and its inverse, rather than duplicating version checks
  in test code.
- Add a test helper in `test/fixture_tests.zig` that reads both files through
  `src.compat.readFileAlloc`, constructs `src.Source`, and asserts:

  ```zig
  try std.testing.expect(matching_source.hasTypeInfo());
  try std.testing.expect(!mismatching_source.hasTypeInfo());
  ```

  The mismatch assertion is the fixture-level proof of the Task 1 contract;
  the existing bridge test remains the focused `error.AstGenFailed` check.
- `build.zig:addFixtureChecks` compiles every `.zig` file in each directory it
  lists, so do not add `test/fixtures/frontend_matrix` to its `fixture_dirs` —
  that would compile the intentionally incompatible fixture and break the
  build. Instead, call the existing single-file helper `addFixtureCheck` for
  `shared.zig` and for the version-specific fixture selected by a
  `builtin.zig_version` branch, so the mismatching fixture is never a
  compilation target.
- Run the shared fixture through an existing rule (the `todo` rule, implemented
  in `src/rules/todo_comment.zig`, is sufficient — note the registered rule
  name is `todo`, not `todo-comment`) with exact expected line/rule/message
  fields. Running that same
  assertion in both shells is the parity check; do not compare platform-specific
  paths or compiler diagnostic text.

#### Acceptance criteria

- [x] `nix develop -c just test` passes, including the matching and mismatching
  frontend assertions.
- [x] `nix develop .#zig016 -c just test` passes with the inverse fixture
  selection.
- [x] `nix develop -c zig build check-fixtures` and the equivalent 0.16 command
  produce the same baseline failures recorded in
  `docs/internal/ZIG_0_16_INVENTORY.md` (15 at the time of writing) and no new
  failures; the newly added matching fixtures compile successfully. The
  baseline failures remain visible and are not silently filtered.
- [x] The shared fixture produces identical expected diagnostic fields in both
  toolchains, and `nix develop -c zig fmt --check test/fixtures/frontend_matrix`
  passes (the canonical 0.15.2 formatter parses the 0.16 fixture too — `@Int`
  fails only at AstGen, not at parse).

---

### Task 9: Make CI test both embedded frontends

#### Status quo

`.github/workflows/build.yml` has one `build-matrix` job that invokes
`nix develop --command just ci`, caches one Zig build tree, and uploads one
SARIF result. The 0.16.0 shell exists in `flake.nix` but is not used by CI.

#### Objectives

Turn the build job into a two-entry frontend matrix while preserving the
existing change filtering, Nix/Cachix setup, deterministic lint behavior, and
one canonical Code Scanning upload.

#### Tech Notes

- Modify the `build-matrix` strategy in `.github/workflows/build.yml` to carry
  both the frontend version (`0.15.2`, `0.16.0`) and the corresponding Nix shell
  (`default`, `.#zig016`). Keep the `changes` dependency so documentation-only
  changes do not spend two build slots.
- Include the frontend in the Zig cache key. A cache created by one compiler
  must not be reused by the other compiler even when the source hash is equal.
- Invoke `just ci` in both matrix legs. Task 7 keeps 0.15.2 authoritative for
  formatting, so the workflow and Justfile must make that policy explicit
  rather than allowing a formatter mismatch to become an unexplained 0.16
  failure.
- Upload SARIF from one designated frontend (the canonical 0.15.2 leg) to avoid
  duplicate findings in GitHub Code Scanning; both legs still run analyzer lint.
- Keep the aggregate `build` job's result checks correct when either matrix leg
  fails or when the code path is skipped.

#### Acceptance criteria

- [x] A code-changing pull request shows two build legs, one for each pinned
  frontend, and the aggregate job fails if either leg fails.
- [x] Both legs execute `just test` and `just lint`; the canonical leg uploads
  exactly one SARIF file.
- [x] The cache key contains the frontend identity and no 0.15.2 cache path is
  restored for a 0.16.0 job.
- [x] The workflow YAML remains valid, and the local equivalents
  `nix develop -c just ci` and `nix develop .#zig016 -c just ci` pass.

---

### Task 10: Publish release artifacts for both frontends

#### Status quo

`.github/workflows/release.yml` validates and builds both Zig 0.15.2 and Zig
0.16.0. Its platform matrix covers Linux x86_64, macOS aarch64, and Windows
x86_64, and the asset name includes the embedded frontend. The v0.15.0 release
attempt passed both validation legs but failed to link the macOS Zig 0.15.2
artifact because the release job did not apply the existing SDK workaround.

#### Objectives

Build and upload one archive for every platform/frontend pair, with names that
make the embedded language frontend unambiguous before download.

#### Tech Notes

- Extend the release matrix with a `zig_version` dimension while retaining the
  existing platform metadata. Install the matrix-selected version with
  `mlugg/setup-zig@v2`; `build.zig` already selects the matching entry point.
- Use the artifact pattern
  `zwanzig-${{ github.ref_name }}-zig-${{ matrix.zig_version }}-${{ matrix.asset_suffix }}`
  for both Unix and Windows archives. Preserve the existing archive extensions
  and include `LICENSE` and `README.md` in each archive.
- Run `scripts/release-check.sh` under both frontend versions in the validation
  job. It must continue to verify the release tag, documentation versions, and
  the full test/lint suite before any upload occurs.
- Update the platform download table in `README.md` (currently one archive per
  platform) to list both frontend artifacts, and extend the existing "Zig
  frontend compatibility" sections in `README.md` and `docs/USAGE.md` — which
  already explain matching the binary to the project's Zig version — to state
  that the frontend is encoded in the asset name (a project on Zig 0.15.2
  downloads the `zig-0.15.2` artifact, and likewise for 0.16.0). `docs/USAGE.md`
  has no download table; do not add a duplicate of the README one. Keep
  source-build instructions explicit about selecting `nix develop` versus
  `nix develop .#zig016`.
- Add a user-facing `CHANGELOG.md` entry with the issue or PR number when the
  release workflow lands. Do not add a placeholder number.

#### Acceptance criteria

- [ ] A release tag produces six uniquely named archives: three platforms times
  two frontend versions.
- [ ] Each archive's `--version` output identifies the frontend encoded in its
  filename, and the 0.15.2 and 0.16.0 artifacts do not overwrite one another.
- [ ] Both release validation legs pass `scripts/release-check.sh` before
  upload.
- [x] README and usage instructions let a user choose the correct binary
  without reading the workflow source.

---

### Task 11: Close the migration decisions and update the roadmap

#### Status quo

Tasks 1–9 are complete and checked off above. Task 10's dual-frontend release
workflow, artifact naming, and user documentation are implemented, while the
criteria requiring a successful release tag remain open. Task 7's support lifetime,
canonical formatter, and launcher decisions are now adopted and recorded in
its "Review decisions (adopted)" section.

#### Objectives

Record the reviewed choices in this document, update the support and release
documentation to match them, and mark only the tasks whose acceptance criteria
actually passed.

#### Tech Notes

- If 0.15.2 is sunset, document the first release that drops its artifact and
  preserve the old binary-selection guidance until that release. If support is
  indefinite, state the maintenance commitment instead of leaving an implied
  deadline.
- Record the canonical formatter choice in `CLAUDE.md`, `docs/DEVELOPMENT.md`
  (which currently states no formatter policy), and the CI workflow so
  contributors know which `zig fmt` output is expected.
- If the launcher remains deferred, retain explicit artifact names and record
  the closing rationale in Task 7's "Review decisions (adopted)" section rather
  than restating it elsewhere; per that section, a launcher becomes a separate
  plan only if user demand shows filename selection is insufficient.

#### Acceptance criteria

- [x] The three decisions have a durable record with rationale and no
  contradictory statements in `README.md`, `docs/USAGE.md`, `CLAUDE.md`, or
  `docs/DEVELOPMENT.md`.
- [x] The checkboxes in this plan — the Task 1–7 steps and the Task 8–11
  acceptance criteria — match the code, CI, and release workflow that actually
  shipped.
- [x] The final implementation run ends with `just test` and `just lint` under
  both pinned shells.
