# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `unused-decl` now runs a project-wide pass by default when more than one file is analyzed, reporting public top-level declarations that are not referenced by any other analyzed file (#91).

### Changed

- Project-wide `unused-decl` ignores package entrypoint and alias-style public API exports to reduce library facade noise (#91).
- Project-wide `unused-decl` now keeps declarations that are exposed through another used public declaration's type, signature, field, or initializer surface (#91).

## [0.12.2] - 2026-05-27

### Changed

- Per-file scratch now uses libc's allocator instead of an arena over the page allocator. The engine eagerly frees its temporaries, so the arena was retaining roughly an order of magnitude more memory than the analyzer's actual working set. On engine-heavy inputs (notably `0.12.x` after `defer-frees-escapee` landed) this could push peak RSS into multi-GB territory and OOM on CI runners with limited memory (#89).

## [0.12.1] - 2026-05-26

### Fixed

- `store-violations` no longer flags slices returned directly from `appendSlice` as escapes — they are treated as copies (#86).

## [0.12.0] - 2026-05-26

### Added

- New `defer-frees-escapee` rule that detects allocations freed by `defer` while still escaping the function (#79).
- CFG construction now visits `switch` arms, improving coverage for engine-based checkers (#79).

### Changed

- Skip inlining of recursive calls during engine analysis for faster runs on recursive code (#79).
- Build script auto-detects the active macOS SDK via `xcrun` when applying the Zig 0.15.2 macOS link workaround (#82).

### Fixed

- `ExplodedGraph.addEdge` deduplicates edges and remains atomic under allocation failure (#83).

## [0.11.0] - 2026-02-24

### Added

- New `deinit-lifecycle` rule that detects misuse of `deinit` and other cleanup methods, including missing or duplicate calls and reinitialization after cleanup (#72).

## [0.10.0] - 2026-02-20

### Added

- New `slice-bounds-engine` checker for path-sensitive array and slice out-of-bounds detection, including definite and possible OOB access, negative indices, and tracking of array/string literal lengths (#70).

## [0.9.0] - 2026-02-16

### Added

- New `divide-by-zero` engine checker (#67).

### Fixed

- Deduplicate diagnostics that previously appeared multiple times across inlined functions in the store-violations engine (#63).
- Recognize `.call_comma` in `resolveFunctionCall`, fixing missed call sites.

## [0.8.1] - 2026-02-04

### Fixed

- Four engine correctness bugs in the analysis engine (#60).
- `unreachable-code` no longer treats float literals as parseable const ints.
- `optional-unwrap` now treats `debug.assert` as a null-guard.

## [0.8.0] - 2026-02-04

### Added

- New `return-local-ptr` rule that detects functions returning pointers to local stack values (#58).

## [0.7.0] - 2026-02-03

### Added

- `free_owned` ownership model with sentinel-aware typing, improving store-violation precision on owned/freed allocations (#56).

## [0.6.0] - 2026-02-03

### Added

- New `stack-escape-engine` checker that detects stack escapes through spawned threads (#54).

### Changed

- Diagnostic JSON output now uses `std.json` for serialization.

### Fixed

- Cached CFG artifacts are correctly wired through the analysis pipeline (#53).

## [0.5.1] - 2026-02-02

### Changed

- Avoid ZIR lookup for local identifiers, reducing analysis overhead (#51).

### Fixed

- Improved fallback handling for local error-union types (#51).

## [0.5.0] - 2026-02-02

### Changed

- Typed IR is now always on; the previous toggle has been removed (#47).
- Core modules and `optional-unwrap` helpers were split for clearer module boundaries (#48).

### Fixed

- `optional-unwrap` now traverses callee unwraps and applies improved guard recognition (#48).

## [0.4.0] - 2026-02-02

### Added

- New `optional-unwrap` rule that flags forced `.?` unwrapping, with guard-aware analysis to reduce false positives — covers `if`/`if_simple`, `orelse`, early-exit, labeled-block, `try`, `catch`, and `debug.assert` patterns (#44, #45, #46).

## [0.3.0] - 2026-02-01

### Added

- Parallel file analysis with a new `--threads` CLI option and deterministic diagnostic ordering across threads.
- New `unused-parameter` rule.
- New `sentinel-alloc` rule (disabled by default) for sentinel-terminated allocation bugs.
- New `unreachable-code-engine` checker for path-sensitive dead-code detection.
- New `store-violations` engine and checker with ownership and store modeling.
- Type-aware checks added to `identifier-style` and `unused-decl` rules.
- SARIF output format and richer text output with source pointers.
- CFG and lattice-flow visualization via DOT output, with boolean value tracking and const flag detection.

### Changed

- Widening is now enabled by default for engine convergence.
- Default rule filtering: when no config or `--do`/`--skip` flag is present, `sentinel-alloc` is blocklisted.

### Fixed

- No more false-positive leak diagnostics at inlined function exits (#41).
- `unused-parameter` correctly handles generic parameters (#39).
- Cache keys use a deterministic rule order.

## [0.2.4] - 2026-01-25

### Fixed

- `release-check.sh` uses `grep` instead of `rg` for portability in CI environments.

## [0.2.3] - 2026-01-25

### Fixed

- Enforce `release-check` validation in the release workflow.

## [0.2.2] - 2026-01-25

### Changed

- `identifier-style` rule aligned with Zig naming guidance: types vs. values vs. external conventions clarified; `SCREAMING_SNAKE_CASE` restricted to external-convention aliases (#22).

### Fixed

- `identifier-style` treats `if`-expressions yielding types as type aliases and no longer misclassifies call-result types.

## [0.2.1] - 2026-01-24

### Fixed

- Refined `@typeInfo` alias checks and identifier-style type-alias detection.

## [0.2.0] - 2026-01-24

### Added

- Inline comment-based suppression of diagnostics (#16).

## [0.1.1] - 2026-01-24

### Fixed

- Updated `setup-zig` action to v2 in the release workflow (#15).

## [0.1.0] - 2026-01-24

### Added

- Initial release: Zig static analyzer MVP with the `empty-catch` rule, rule-selection flags, and source parsing cache.

[Unreleased]: https://github.com/forketyfork/zwanzig/compare/v0.12.1...HEAD
[0.12.1]: https://github.com/forketyfork/zwanzig/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/forketyfork/zwanzig/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/forketyfork/zwanzig/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/forketyfork/zwanzig/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/forketyfork/zwanzig/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/forketyfork/zwanzig/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/forketyfork/zwanzig/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/forketyfork/zwanzig/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/forketyfork/zwanzig/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/forketyfork/zwanzig/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/forketyfork/zwanzig/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/forketyfork/zwanzig/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/forketyfork/zwanzig/compare/v0.2.4...v0.3.0
[0.2.4]: https://github.com/forketyfork/zwanzig/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/forketyfork/zwanzig/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/forketyfork/zwanzig/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/forketyfork/zwanzig/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/forketyfork/zwanzig/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/forketyfork/zwanzig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/forketyfork/zwanzig/releases/tag/v0.1.0
