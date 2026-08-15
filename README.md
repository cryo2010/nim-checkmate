# checkmate

A jest-like test runner for Nim. One binary that discovers, compiles, and runs
your unmodified `std/unittest` files in parallel, with pretty output, flake
detection, and line coverage.

```
 PASS  tests/t_config.nim (0.70 s)
 FAIL  tests/t_math.nim (0.51 s)
 FLAKY tests/t_net.nim (passed 8/10)

 FAIL  tests/t_math.nim
  math ops > addition works
    tests/t_math.nim(12, 5): Check failed: a + b == 5
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
| `-t`, `--filter PAT` | run tests whose name starts or ends with PAT; repeatable (OR'd) |
| `-l`, `--loop N` | run the whole suite N times to catch flaky tests |
| `-j`, `--jobs N` | parallel workers (default: CPU cores) |
| `-b`, `--bail` | stop on the first failing test file |
| `--timeout SECS` | per-test-binary timeout (default 300; 0 disables) |
| `-v`, `--verbose` | per-test result lines |
| `--color auto\|always\|never` | color mode (`NO_COLOR` is honored) |
| `-n`, `--nimflags FLAG` | extra flags for `nim c`; repeatable |
| `--coverage` | print a line-coverage table after the run |
| `--pass-with-no-tests` | exit 0 even when zero tests were run |

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
bail = false
timeout = 300             # seconds per test binary; 0 disables
pass_with_no_tests = false  # exit 0 even when zero tests were run

[compile]
nim = "nim"
backend = "c"             # c | cpp
flags = []                # e.g. ["-d:release", "--mm:orc"]
defines = []              # shorthand for -d: defines
paths = []                # extra --path entries

[output]
color = "auto"
verbose = false

[coverage]
enabled = false
```

Add `.checkmate/` (the build/state cache) to your `.gitignore`.

## Flake detection

`--loop:N` compiles once and runs every file N times, interleaved so early
iterations of all files finish first. Iterations of the *same* file never
run concurrently with each other (test files can assume exclusive ownership
of their temp dirs, ports, databases, ...); different files still fill the
`--jobs` workers. A test that both passes and fails
across iterations is reported as flaky, and flaky suites fail the run:

```
 FLAKY tests/t_net.nim (passed 8/10)
  reconnects after drop (flaky: failed 2/10)
    tests/t_net.nim(31, 10): Check failed: reconnected
    also failed in iteration(s): 4, 7
```

## Coverage

`--coverage` (or `[coverage] enabled = true`) compiles tests with gcov
instrumentation and `--lineDir:on`, so reports map to real `.nim` lines:

```
Coverage (executed lines):
  src/mathlib.nim                               72.7%  (8/11)
  TOTAL                                         72.7%  (8/11)
```

Line hits are merged across all test binaries and loop iterations. Needs
`xcrun` (macOS), `llvm-cov`, or `gcov` on PATH. Only files inside the
project are reported; test files themselves may be partially attributed to
`std/unittest` templates by gcov and are best read indicatively.

## How it works

checkmate compiles each test file with `--import:checkmate_inject`, a tiny
module (embedded in the checkmate binary, materialized into `.checkmate/`)
that registers a JSONL-emitting `OutputFormatter` before `std/unittest`
initializes. unittest then never installs its console formatter, checkmate
gets structured per-test events over a file, and your binaries stay fully
stock when run standalone. Test binaries run in a polling process pool with
their output captured per run; each file gets a private nimcache, so
parallel compiles are safe and unchanged files rebuild in well under a
second. Test-name filters are passed straight to unittest's own filtering.

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
- **POSIX only** for now (`/bin/sh` process wrapper); Windows would need a
  small port in `pool.nim`.

## Development

```sh
nimble build      # build ./checkmate
nimble test       # unit + integration tests (fixtures under tests/fixtures/)
./checkmate       # dogfood: checkmate runs its own suite
```
