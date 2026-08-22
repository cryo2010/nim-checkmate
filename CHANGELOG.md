# Changelog

All notable changes to checkmate are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Pre-1.0, minor
releases may include breaking changes.

## [0.3.0] - 2026-08-21

### Fixed

- Test binaries are compiled with the project's own source directory (the
  `srcDir` from the `<project>.nimble`, or the project root if unset) on the
  path, searched ahead of installed packages. A globally-installed copy of the
  package can no longer shadow the local code under test. When there is no
  `.checkmate.toml`, checkmate now anchors the project root at the nearest
  `.nimble` file.

## [0.2.0] - 2026-08-21

### Breaking

- **`-t` is now a regex over test names** (jest-style), replacing the old
  `std/unittest` glob filter. Use alternation and anchors (for example
  `-t 'parses|renders'` or `-t 'works$'`) instead of `prefix*` / `*suffix`
  globs.
- **Positional arguments are now unanchored regexes over test-file paths**
  (for example `checkmate parser`), replacing literal file/dir arguments;
  multiple arguments OR together. As a result, pointing at a single file inside
  a *nested* project no longer switches to that project's own config (one
  project root per run, like jest's rootDir).
- **The time-travel controls moved out of `std/unittest` into an importable
  `checkmate` module.** Add `import checkmate` to any test that calls
  `advanceTime`, `travelTo`, or `timeTravelActive`. Those files now also compile
  under a plain `nimble test`, where the controls raise `CheckmateError` and
  `timeTravelActive()` returns `false`.

### Added

- **Time travel** (`--time-travel`, `[run] time_travel`, `time_start`): freezes
  the clock so `sleep` / `sleepAsync` are instant and `getTime` / `now` /
  `epochTime` / `getMonoTime` read a virtual clock; drive it explicitly with
  `advanceTime` / `travelTo`.
- **Empty-test enforcement**: tests that execute zero assertions fail by default
  (`--allow-empty-tests` or `[run] allow_empty_tests` to opt out).
- **Rich failure output**: power-assert decomposition of `and` / `or` / `not`
  expressions, a `repr` fallback and length cap for printed operands, and
  `string` / `seq` diff windows (first-diff index, caret columns, control-char
  placeholders). Failing tests group under a red-circle suite heading with
  `file:line` headers.
- **Per-test timeouts** via a progress-based watchdog (`--timeout` or
  `[run] timeout`), which kills a hung test's whole process tree.
- **`--loop-in-process`**: a faster loop mode that repeats each test inside one
  process per file.
- **`--bail`**: stop at the first failing test, aborting the running binary.
- **Coverage gate** (`--min-lines` or `[coverage] min_lines`): fail when line
  coverage is below a percentage, or above a maximum uncovered-line count.
- **`--pass-with-no-tests`**, plus a clear failure when zero tests run.
- **`-C` / `--chdir`**: run as if started in another directory (git-style).
- **`schema_version`** config key, so future upgrades can migrate old configs.
- **CI**: a GitHub Actions matrix on macOS and Linux.

### Changed

- **The config file is now `.checkmate.toml`** (dot-prefixed). A plain
  `checkmate.toml` is still discovered and loaded as a deprecated fallback.
- Source paths in output are printed relative to the project root.

## [0.1.0] - 2026-08-14

Initial release: a jest-like test runner that discovers `std/unittest` files,
compiles and runs them in parallel, detects flaky tests with `--loop`, filters
tests by name, reads a `checkmate.toml`, and reports gcov-based line coverage.
