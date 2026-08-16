# checkmate

A jest-like test runner for Nim. One binary that discovers, compiles, and runs
your unmodified `std/unittest` files in parallel, with pretty output, flake
detection, and line coverage.

```
 PASS  tests/t_config.nim (0.70 s)
 FAIL  tests/t_math.nim (0.51 s)
 FLAKY tests/t_net.nim (passed 8/10)

 FAIL  tests/t_math.nim
  ● math ops
    ✗ addition works
      12:  a + b == 5
        a + b was 4

suites: 1/3 passed (1 failed, 1 flaky)
tests:  14/17 passed (2 failed, 1 flaky)
time:   1.31 s
```

## Install

```sh
nimble install checkmate
```

## Quick start

```sh
cd my-project
checkmate                 # discover tests/t*.nim, compile, run, report
checkmate init            # generate checkmate.toml (optional)
```

No changes to your test files are needed; anything that works with
`import std/unittest` works with checkmate.

## Usage

```sh
checkmate [run] [paths...] [options]   # run is the default subcommand
checkmate init [--force]               # write a default checkmate.toml
checkmate list [paths...]              # print discovered test files
```

| Option | Meaning |
| --- | --- |
| `paths...` | test files (verbatim) or directories (walked with the filename pattern) |
| `-C`, `--chdir DIR` | run as if started in DIR (git-style) |
| `-t`, `--filter PAT` | run tests whose name starts or ends with PAT; repeatable (OR'd) |
| `-l`, `--loop N` | run the whole suite N times to catch flaky tests |
| `--loop-in-process` | loop each test inside one process per file (fast, lower fidelity) |
| `--time-travel` | freeze clocks; sleeps are instant, time advances virtually |
| `--time-start T` | pin the virtual wall clock (ISO 8601) |
| `-j`, `--jobs N` | parallel workers (default: CPU cores) |
| `-b`, `--bail` | stop everything at the first failing test (aborts mid-file) |
| `--timeout SECS` | seconds a single test may run (default 300; 0 disables) |
| `-v`, `--verbose` | per-test result lines: ✓/○/✗ marks, suite grouping, timings |
| `--color auto\|always\|never` | color mode (`NO_COLOR` and `CI` are honored) |
| `-n`, `--nimflags FLAG` | extra flags for `nim c`; repeatable |
| `--coverage` | print a line-coverage table after the run |
| `--min-lines N` | coverage gate: minimum percent, or max uncovered lines if negative |
| `--pass-with-no-tests` | exit 0 even when zero tests were run |
| `--allow-empty-tests` | don't fail tests that execute zero assertions |

Examples:

```sh
checkmate tests/api                    # one directory
checkmate tests/t_parser.nim           # one file
checkmate -t addition                  # test-name filter
checkmate -t 'mysuite::'               # a whole suite
checkmate -t 'fast_suite::mytest*'     # raw std/unittest filter syntax
checkmate --loop:20 --jobs:4           # flake hunting
checkmate --bail --timeout:30          # fail fast in CI
```

## Configuration (checkmate.toml)

`checkmate init` generates the full schema with defaults. CLI flags override
config values. The file also anchors the project root: checkmate walks up
from the current directory to find it.

```toml
[tests]
dirs = ["tests"]          # directories scanned recursively
pattern = "t*.nim"        # filename glob (covers t_*.nim and test_*.nim)
exclude = []              # path globs, e.g. ["tests/fixtures/*"]

[run]
jobs = 0                  # 0 = CPU cores
loop = 1
loop_in_process = false   # loop inside one process per file (fast, lower fidelity)
bail = false
timeout = 300             # seconds a single test may run; 0 disables
pass_with_no_tests = false  # exit 0 even when zero tests were run
allow_empty_tests = false   # don't fail tests that execute zero check/require/expect
time_travel = false       # virtualize clocks: sleep() instant, time frozen
time_start = ""           # pin the virtual wall clock (ISO 8601)

[compile]
nim = "nim"
backend = "c"             # c | cpp
flags = []                # e.g. ["-d:release", "--mm:orc"]
defines = []              # shorthand for -d: defines
paths = []                # extra --path entries

[output]
color = "auto"
verbose = false

[format]
max_path = 44             # rendered file paths, preceding ellipsis (0 = unlimited)
max_suite = 60            # suite names, trailing ellipsis
max_test = 60             # test names, trailing ellipsis
max_value = 400           # printed values in check failures

[coverage]
enabled = false
min_lines = 0             # gate: min percent (80.0) or max uncovered lines (-50)
```

Add `.checkmate/` (the build/state cache) to your `.gitignore`.

## Flake detection

`--loop:N` compiles once and runs every file N times, interleaved so early
iterations of all files finish first. Iterations of the *same* file never
run concurrently with each other (test files can assume exclusive ownership
of their temp dirs, ports, databases, ...); different files still fill the
`--jobs` workers.

A test that both passes and fails across iterations is reported as flaky,
and flaky suites fail the run:

```
 FLAKY tests/t_net.nim (passed 8/10)
  reconnects after drop (flaky: failed 2/10)
    tests/t_net.nim(31, 10): Check failed: reconnected
    also failed in iteration(s): 4, 7
```

`--loop-in-process` is an opt-in fast mode: each file runs as ONE process
and every test repeats N times inside it (suite setup/teardown re-run per
iteration). This skips N-1 process spawns and module initializations per
file, but iterations share process state, which changes what you measure:
flakes that only appear with a fresh process stay hidden, and a test that
mutates module-level state may look flaky when it never would across real
runs. A crash or timeout also ends all remaining iterations of that file,
and the per-file timeout budget covers all N iterations. Use it for quick
statistical sweeps; trust plain `--loop` for verdicts. Requires the
unittest overlay (see Empty-test enforcement); when the overlay is
unavailable it warns and falls back to process-level looping. The per-test
timeout applies per iteration in both modes.

## Empty-test enforcement

A test that executes zero assertions can only ever pass, so by default it
fails:

```
 FAIL  tests/t_api.nim
  ● users
    ✗ fetches the profile
      Test has no assertions (checkmate: add a check, or run with --allow-empty-tests)
```

Counting happens at runtime, so assertions made inside helper procs (in any
module) count. `check`, `require`, and `expect` all count; `skip()`ped tests
are exempt. A deliberate smoke test stays green with an explicit
`check true`. Disable globally with `--allow-empty-tests` or
`allow_empty_tests = true`.

This works by compiling tests against a generated overlay of your own
toolchain's `std/unittest` (see How it works); if a future Nim version
changes unittest's internals, checkmate detects the mismatch, prints a
warning, and compiles fully stock instead.

The overlay also upgrades failing-check output: operand values of types
without a `$` are printed via `repr` (stock unittest silently omits them),
and printed values are capped at 400 characters with an exact
`... (N more chars)` remainder. Failing `==` checks additionally get
comparison-aware context: long strings report the first differing index
with windowed excerpts around it, and seqs/arrays report the first
mismatching index and elements:

```
100:  lhs == rhs
  strings differ at index 100 (lengths 201 and 201, 1 differing position)
    lhs: ...aaaaaaaaaaaaaaaXaaaaaaaaaaaaaaaaaaaaaaaa...
    rhs: ...aaaaaaaaaaaaaaaYaaaaaaaaaaaaaaaaaaaaaaaa...
                          ^
```

Every mismatching column inside the window gets its own caret, and for
equal-length strings the header reports the total count of differing
positions across the whole string. Control characters render as
single-column placeholders inside the window (`␤` newline, `␍` CR,
`␉` tab) so multiline strings keep the excerpt and carets on one line.

Checks using `and`/`or`/`not` (which stock unittest does not decompose at
all) get power-assert instrumentation: every subexpression records its
value as it evaluates, so the report shows exactly what ran and what
short-circuiting skipped, with guarded expressions never evaluated
speculatively:

```
18:  conn != nil and conn.port == 443
  conn was nil
  conn != nil was false
  conn.port was not evaluated
  conn.port == 443 was not evaluated
```

## Time travel

`--time-travel` (or `[run] time_travel = true`) freezes the clocks inside
your test binaries: `sleep()` returns instantly, `sleepAsync` timers fire
without waiting, and `getTime`/`now`/`epochTime`/`getMonoTime` all read a
virtual clock that only advances when something sleeps or asks it to. A
suite that sleeps for minutes finishes in milliseconds, with zero test
changes, and timing logic becomes deterministic.

```nim
test "cache expires":
  cache.put("k", ttl = initDuration(hours = 1))
  sleep(3_600_001)          # instant; virtual clock advances 1 h
  check not cache.has("k")  # getTime() agrees an hour has passed
```

Pin the wall clock for date-dependent tests with
`time_start = "2020-06-15T12:00:00Z"` (or `--time-start`), and control time
explicitly from tests when auto mode isn't enough:

```nim
advanceTime(1500)                        # ms
advanceTime(initDuration(minutes = 5))
travelTo(dateTime(1999, mDec, 31))       # wall jump, backward allowed;
check timeTravelActive()                 # monotonic time never regresses
```

The API arrives via `import std/unittest` under checkmate (helper modules
can `import checkmate_timebase`); files that must also compile stock can
guard with `when declared(advanceTime)`. Reported test durations stay
real-clock, and the per-test timeout still catches genuine hangs.

Caveats: an async timeout racing real pending I/O never expires virtually
(the real-time watchdog backstops it); a busy-wait on the clock without
sleeping spins until the watchdog kills it; `cpuTime`, raw
`clock_gettime`, sockets, and external processes see real time. Requires
the stdlib overlay (see Empty-test enforcement); if it cannot be built,
checkmate warns and runs without time travel.

## Coverage

`--coverage` (or `[coverage] enabled = true`) compiles tests with gcov
instrumentation and `--lineDir:on`, so reports map to real `.nim` lines:

```
Coverage (executed lines):
  src/mathlib.nim                               72.7%  (8/11)
  TOTAL                                         72.7%  (8/11)
```

Line hits are merged across all test binaries and loop iterations. Needs
`xcrun` (macOS), `llvm-cov`, or `gcov` on PATH.

`min_lines` turns coverage into a CI gate: a passing test run still exits 1
when total line coverage is below the threshold. Positive values are a
minimum percentage; negative values cap the absolute number of uncovered
lines (steadier than percentages for small projects):

```
checkmate: coverage 72.7% is below the required minimum of 80.0% (src/mathlib.nim has the most uncovered lines: 3)
``` Only files inside the
project are reported; test files themselves may be partially attributed to
`std/unittest` templates by gcov and are best read indicatively.

## How it works

checkmate compiles each test file with `--import:checkmate_inject`, a tiny
module (embedded in the checkmate binary, materialized into `.checkmate/`)
that registers a JSONL-emitting `OutputFormatter` before `std/unittest`
initializes. unittest then never installs its console formatter, checkmate
gets structured per-test events over a file, and your binaries stay fully
stock when run standalone. For empty-test enforcement, tests compile with
`--lib:` pointing at `.checkmate/libfarm`, a symlink mirror of your
toolchain's lib directory whose `pure/unittest.nim` is a runtime-patched
copy of your own toolchain's source with assertion-counting wrappers; both
`import unittest` and `import std/unittest` resolve to it. Test binaries
run in a polling process pool with
their output captured per run; each file gets a private nimcache, so
parallel compiles are safe and unchanged files rebuild in well under a
second. Test-name filters are passed straight to unittest's own filtering.

## Repaired std/unittest quirks

Some std/unittest behaviors misreport results to any formatter-based
observer; checkmate detects and repairs them (the `quirks` fixture
demonstrates each):

- **Failures in helper procs**: `fail()`/failing `check`s outside the test
  body cannot set the test's status (a compile-time scoping quirk), so the
  test ends "OK" despite the failure. checkmate treats the failure event as
  authoritative and reports the test FAILED, annotating checkpoint-less
  `fail()` calls.
- **`skip()` after a failure** reports SKIPPED in stock unittest even
  though the exit code says failed; checkmate reports FAILED with the
  failure detail.
- **Duplicate test names** are distinct tests, disambiguated as
  `name (2)` so they cannot masquerade as a flaky single test (not
  applicable under `--loop-in-process`, where repetition encodes
  iterations).
- **Nested suites** are tracked as a stack for crash attribution.

## Limitations

- **Test-name filters are not regexes.** `std/unittest` supports only
  exact, `prefix*`, `*suffix`, and `prefix*suffix` matching, so a bare
  `-t PAT` means "starts or ends with PAT". Anything with `*` or `::` is
  passed through verbatim.
- **Binaries that read their own params** clash with `-t`: unittest ingests
  all argv as filters, and checkmate's filter args will reach your
  `paramStr` too. Without `-t`, no args are passed.
- **Checks inside spawned threads** don't reach formatters (true of stock
  unittest as well) and are invisible to checkmate's per-test reporting.
  They also don't count for empty-test enforcement (the counter is
  thread-local): a test asserting only in spawned threads needs a
  `check true` in its main body. Assertions in `teardown` blocks don't
  count either (they run after the per-test verdict).
- **The timeout is per test, enforced from outside the process**: a hung
  test is detected when the file's event stream stops progressing for
  `timeout` seconds. Killing it necessarily kills the whole file's process,
  so tests after the hung one are not run. A test that finishes but
  exceeded the budget is failed post-hoc without affecting its siblings.
- **Empty-test enforcement is baked in at compile time**, so binaries under
  `.checkmate/bin/` enforce it even when run standalone; a `--nimflags`
  `--lib:` override is shadowed by checkmate's own when enforcement is on.
- **POSIX only** for now (`/bin/sh` process wrapper); Windows would need a
  small port in `pool.nim`.

## Development

```sh
nimble build      # build ./checkmate
nimble test       # unit + integration tests (fixtures under tests/fixtures/)
./checkmate       # dogfood: checkmate runs its own suite
```

CI (`.github/workflows/ci.yml`) runs build, tests, and the dogfood on
macOS and Linux (Linux is experimental until proven on a real runner).

### Fixture projects

`tests/fixtures/` holds self-contained subprojects, each with a static
`checkmate.toml`, exercised end to end by `t_integration.nim` and handy
for manual testing:

```sh
./checkmate -C tests/fixtures/flaky --loop:10       # watch FLAKY reporting
./checkmate -C tests/fixtures/time_travel           # 5 virtual minutes in ~2 s
./checkmate -C tests/fixtures/sleepy                # 1 s timeout vs 2 s sleep
```

| Fixture | Demonstrates |
| --- | --- |
| `passing` | default config, green suites, a skipped test |
| `failing` | check failures and exception reporting |
| `flaky` | marker-file flake for `--loop` (delete `flake_marker` for a deterministic first iteration) |
| `bail` | `--bail` skipping later suites (`jobs = 1` for ordering) |
| `hanging` | watchdog kill of a hung test; per-test budget proof (`t_steady`) |
| `sleepy` | `timeout = 1` vs a 2 s sleeper |
| `crashing` | SIGSEGV attribution to the open test |
| `noisy` | captured stdout/stderr shown for failing files |
| `compile_error` | verbatim compiler error passthrough |
| `empty_test` | empty-test enforcement, helper-proc counting, escape hatches |
| `print_values` | enriched check output: repr fallback, value truncation |
| `power_assert` | and/or/not decomposition with evaluation tracking |
| `no_tests` | zero test files: fails unless `--pass-with-no-tests` |
| `covered` | coverage table and `min_lines` gating |
| `time_travel` | frozen clocks, pinned start, explicit API, async auto-advance |
| `own_params` | documented argv-clash limitation with `-t` |
| `quirks` | std/unittest edge cases checkmate repairs (see below) |
| `long_names` | long paths shortened with preceding ellipsis |
