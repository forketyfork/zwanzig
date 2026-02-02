# Task: Parallelize Analysis Across Multiple Cores

Overview: Add per-file concurrency using a thread pool, isolate per-task state (diagnostics, stats, typed IR), make cache/allocator usage thread-safe, and ensure deterministic output ordering.

## Step 1: Refactor Analyzer to produce per-file results without shared mutation

### Status Quo
- `Analyzer.analyzeFile` appends diagnostics to `self.diagnostics` and filters suppressions by slicing the shared list.
- `CheckerContext` gets a pointer to `self.analysis_stats`.
- Typed IR warm-up uses a shared `Analyzer.zir_bridge`.

### Objectives
Make analysis of a single file return an isolated result so it can run safely in parallel.

### Tech Notes
- Introduce a small `AnalysisResult` struct (for example, `diagnostics: std.ArrayList(Diagnostic)`, `stats: AnalysisStats`) and a helper method like `Analyzer.analyzeFileResult(file_path, allocator) !AnalysisResult`.
- Change `runChecksOnSource` to accept explicit `diagnostics` and `analysis_stats` parameters instead of using `self.diagnostics` and `self.analysis_stats`.
- Move suppression filtering to operate on the per-file diagnostics list (no `start_index` slicing).
- Remove or localize `Analyzer.zir_bridge` for typed IR warm-up. Prefer per-file `Source.zirBridge()` to avoid shared mutable state.

### Acceptance Criteria
- The analyzer can analyze one file and return a self-contained `AnalysisResult`.
- All diagnostics for a file are still filtered by suppressions, but no shared list mutation occurs inside `analyzeFile`.
- Existing single-file tests in `src/analyzer.zig` still pass.

## Step 2: Make allocator and cache usage safe for parallel work

### Status Quo
- Main uses `std.heap.GeneralPurposeAllocator(.{})` with default settings.
- `Cache` holds a single `std.fs.Dir` handle in `Analyzer`.

### Objectives
Ensure allocations and cache I/O are safe under concurrency.

### Tech Notes
- Wrap the global allocator in a thread-safe allocator (for example, `std.heap.ThreadSafeAllocator`) or configure GPA to be thread-safe before passing it to `Analyzer`.
- For caches, either:
  - Add a `std.Thread.Mutex` in `Cache` and lock `get/put`, or
  - Create one `Cache` per worker/thread so each has its own `Dir` handle.
- Keep diagnostics/messages allocated with the shared allocator (they must live until final output).

### Acceptance Criteria
- No shared allocator or cache access happens without thread-safe guarantees.
- Cache hits/misses and cache writes still function correctly with `--cache` enabled.

## Step 3: Add parallel scheduling and thread control

### Status Quo
- `src/cli/run.zig` loops through `files` and calls `analyzeFile` sequentially.
- No CLI option for controlling concurrency.

### Objectives
Run per-file analysis across multiple threads, with a CLI flag to control parallelism.

### Tech Notes
- Add `--threads <n>` to `CliArgs`, `parseArgs`, and `printUsage`; default to `std.Thread.getCpuCount()` (fallback to 1 on error).
- Implement a thread pool (for example, `std.Thread.Pool`) in `main` (or expose `Analyzer.analyzeFilesParallel`).
- Dispatch one job per file, each producing an `AnalysisResult` stored at a stable index (file order).
- Capture errors from worker threads (use a mutex-protected `first_error` or a concurrent queue) and fail after joining.

### Acceptance Criteria
- `zwanzig --threads 1 ...` behaves identically to the current serial implementation.
- `zwanzig --threads 4 ...` analyzes all files successfully and exits with correct status.

## Step 4: Deterministic merge of diagnostics and stats

### Status Quo
- Diagnostics are emitted in analysis order, which will be non-deterministic under concurrency.
- `analysis_stats` are collected in a single shared struct.

### Objectives
Provide stable, deterministic output regardless of scheduling order.

### Tech Notes
- Add a comparator for `Diagnostic` (file path, start line, start column, rule id, message).
- After collecting all per-file diagnostics, merge into one list and sort before output.
- Sum `AnalysisStats` from each `AnalysisResult` into the analyzer's aggregate stats.

### Acceptance Criteria
- Repeated runs on the same inputs produce identical output ordering.
- `Analyzer.logAnalysisStats()` shows aggregated totals consistent with the sum of per-file stats.

## Step 5: Update tests and docs for concurrency controls

### Status Quo
- CLI tests cover existing flags; no tests for `--threads` or deterministic ordering.

### Objectives
Validate new CLI behavior and deterministic output.

### Tech Notes
- Add `parseArgs` tests for `--threads` (valid/invalid, missing value, zero/negative).
- Add a unit test for diagnostic ordering (sort comparator or a helper that sorts results).
- Consider a small integration-style test that runs analysis twice with different thread counts and compares output.

### Acceptance Criteria
- `just test` passes with new CLI/tests.
- `just lint` passes with no formatting or lint regressions.
