## checkmate: a jest-like test runner for Nim, plus the small user-facing API
## its enhanced runs expose.
##
## `import checkmate` gives a test file the time-travel controls
## (`advanceTime`, `travelTo`, `timeTravelActive`). Under `checkmate
## --time-travel` these drive the virtual clock; under a plain `nimble test`
## (stock std/unittest, no overlay) the file still COMPILES, but
## `timeTravelActive()` is false and the controls raise `CheckmateError` --
## guard time-sensitive code with `if timeTravelActive():`.
##
## Everything below `when isMainModule` is the CLI (subcommands run/init/list);
## it is compiled only when this module is built as the `checkmate` binary, so
## `import checkmate` never pulls cligen or the runner internals into a test
## binary.

import std/times

type CheckmateError* = object of CatchableError
  ## Raised by the time-travel controls when time travel is not active
  ## (e.g. compiled without checkmate's overlay, or run without --time-travel).

when defined(checkmateTimebase):
  # -d:checkmateTimebase is set by the runner when the stdlib overlay farm
  # provides the virtual clock; the primitives then resolve via --lib:farm.
  from checkmate_timebase import checkmateAdvanceNanos, checkmateTravelToWallNs,
                                 checkmateTimeTravelEnabled

proc timeTravelActive*(): bool =
  ## Whether checkmate's virtual clock is active for this run. False under a
  ## stock build or when the suite was not run with --time-travel.
  when defined(checkmateTimebase): checkmateTimeTravelEnabled()
  else: false

proc ensureActive() =
  if not timeTravelActive():
    raise newException(CheckmateError,
      "time travel is not active; run this test under `checkmate --time-travel`")

proc advanceTime*(ms: int) =
  ## Advance the virtual clock (all clocks) by `ms` milliseconds.
  ensureActive()
  when defined(checkmateTimebase): checkmateAdvanceNanos(int64(ms) * 1_000_000)

proc advanceTime*(d: Duration) =
  ## Advance the virtual clock (all clocks) by `d`.
  ensureActive()
  when defined(checkmateTimebase): checkmateAdvanceNanos(d.inNanoseconds)

proc travelTo*(t: Time) =
  ## Jump the virtual wall clock to `t`; the monotonic clock is unaffected.
  ensureActive()
  when defined(checkmateTimebase):
    checkmateTravelToWallNs(t.toUnix * 1_000_000_000'i64 + t.nanosecond)

proc travelTo*(dt: DateTime) =
  ## Jump the virtual wall clock to `dt`.
  travelTo(dt.toTime)

when isMainModule:
  import std/os
  import cligen
  import checkmate/[config, coverage, discovery, events, runner, report]

  proc validatePattern(pattern, flagName: string) =
    ## Fail fast with a clear message on a bad regex, before any compilation.
    if pattern.len > 0:
      discard compilePattern(pattern, flagName)

  const checkmateVersion = "0.1.0"

  proc applyChdir(chdir: string) =
    ## git/make-style -C: run as if started in this directory.
    if chdir.len > 0:
      if not dirExists(chdir):
        raise newException(UsageError, "no such directory: " & chdir)
      setCurrentDir(chdir)

  proc runGroup(root: string; pathPatterns: seq[string]; namePattern: string;
                loop, jobs: int; bail: bool; timeout: int; verbose: bool;
                color: string; nimflags: seq[string];
                coverage, passWithNoTests, allowEmptyTests: bool;
                minLines: float; loopInProcess, timeTravel: bool;
                timeStart: string): int =
    ## One project's discover-compile-run cycle with its own config and cache.
    var cfg = loadConfig(root)
    cfg.mergeCli(loop, jobs, timeout, bail, verbose, coverage, color, nimflags,
                 passWithNoTests, allowEmptyTests, minLines, loopInProcess,
                 timeTravel, timeStart)
    let rep = newReporter(cfg, filtered = namePattern.len > 0)
    let summary = runOnce(cfg, pathPatterns, namePattern, rep)
    if summary.files.len == 0:
      stderr.writeLine "checkmate: no test files found (dirs: " &
        $cfg.dirs & ", pattern: " & cfg.pattern & ")"
      return exitCodeFor(summary, cfg.passWithNoTests)
    rep.finish(summary)
    var covGate = ""
    if cfg.covEnabled:
      covGate = covGateFailure(cfg, covReport(cfg))
    elif cfg.covMinLines != 0:
      stderr.writeLine "checkmate: warning: coverage.min_lines is set " &
        "but coverage is not enabled"
    if cfg.timeStart.len > 0 and not cfg.timeTravel:
      stderr.writeLine "checkmate: warning: time_start is set " &
        "but time_travel is not enabled"
    result = exitCodeFor(summary, cfg.passWithNoTests)
    if covGate.len > 0:
      stderr.writeLine "checkmate: " & covGate
      if result == 0: result = 1
    if result != 0 and totalTestsRun(summary) == 0 and not summary.bailed:
      stderr.writeLine "checkmate: failing because no tests were run " &
        "(use --pass-with-no-tests to allow this)"

  proc cmRun(paths: seq[string] = @[]; testNamePattern = "";
             loop = 0; jobs = 0; bail = false; timeout = -1;
             verbose = false; color = ""; nimflags: seq[string] = @[];
             coverage = false; passWithNoTests = false;
             allowEmptyTests = false; minLines = 0.0;
             loopInProcess = false; timeTravel = false; timeStart = "";
             chdir = ""): int =
    ## Discover, compile, and run std/unittest test files.
    ## Positional args are jest-style regexes over test-file paths.
    try:
      validatePattern(testNamePattern, "--test-name-pattern")
      for p in paths:
        validatePattern(p, "test path filter")
      applyChdir(chdir)
      let root = findProjectRoot(getCurrentDir())
      result = runGroup(root, paths, testNamePattern, loop, jobs,
        bail, timeout, verbose, color, nimflags, coverage, passWithNoTests,
        allowEmptyTests, minLines, loopInProcess, timeTravel, timeStart)
    except UsageError as e:
      stderr.writeLine "checkmate: " & e.msg
      result = 2

  proc cmInit(force = false; chdir = ""): int =
    ## Generate a .checkmate.toml with the default configuration.
    try:
      applyChdir(chdir)
      let path = writeInitToml(getCurrentDir(), force)
      echo "created ", path
      echo "tip: commit ", ConfigFileName,
        " and add the .checkmate/ cache dir to your .gitignore"
      0
    except UsageError as e:
      stderr.writeLine "checkmate: " & e.msg
      2

  proc cmList(paths: seq[string] = @[]; chdir = ""): int =
    ## Print discovered test files without compiling or running them.
    ## Positional args are jest-style regexes over test-file paths.
    try:
      for p in paths:
        validatePattern(p, "test path filter")
      applyChdir(chdir)
      let cfg = loadConfig(findProjectRoot(getCurrentDir()))
      for tf in discoverTests(cfg, paths):
        echo tf.relPath
      0
    except UsageError as e:
      stderr.writeLine "checkmate: " & e.msg
      2

  clCfg.version = checkmateVersion
  dispatchGen(cmRun, cmdName = "run", dispatchName = "dispatchRun",
    positional = "paths",
    short = {"chdir": 'C', "testNamePattern": 't'},
    help = {
      "chdir": "run as if started in this directory",
      "paths": "regex(es) matched against test file paths, jest-style (omit to run all)",
      "testNamePattern": "run only tests whose name matches this regex (jest -t)",
      "loop": "run the suite N times to catch flaky tests",
      "jobs": "parallel workers (0 = CPU cores)",
      "bail": "stop everything at the first failing test (aborts mid-file)",
      "timeout": "seconds a single test may run (0 disables)",
      "verbose": "per-test lines and captured output for passing files",
      "color": "auto|always|never",
      "nimflags": "extra flags passed to nim c",
      "coverage": "report line coverage (needs xcrun, llvm-cov or gcov)",
      "passWithNoTests": "exit 0 even when zero tests were run",
      "allowEmptyTests": "don't fail tests that execute zero assertions",
      "minLines": "coverage gate: min percent, or max uncovered lines if negative",
      "loopInProcess": "loop inside one process per file (fast, lower fidelity)",
      "timeTravel": "freeze clocks; sleeps are instant, time advances virtually",
      "timeStart": "pin the virtual start time (ISO 8601 or unix epoch seconds)",
    })
  dispatchGen(cmInit, cmdName = "init", dispatchName = "dispatchInit",
    short = {"chdir": 'C'},
    help = {"force": "overwrite an existing .checkmate.toml",
            "chdir": "run as if started in this directory"})
  dispatchGen(cmList, cmdName = "list", dispatchName = "dispatchList",
    positional = "paths", short = {"chdir": 'C'},
    help = {"paths": "regex(es) matched against test file paths, jest-style (omit to list all)",
            "chdir": "run as if started in this directory"})

  proc main() =
    let params = commandLineParams()
    var code: int
    try:
      if params.len > 0 and params[0] == "init":
        code = dispatchInit(params[1 .. ^1])
      elif params.len > 0 and params[0] == "list":
        code = dispatchList(params[1 .. ^1])
      elif params.len > 0 and params[0] == "run":
        code = dispatchRun(params[1 .. ^1])
      else:
        code = dispatchRun(params)  # default subcommand, jest-style
    except HelpOnly, VersionOnly:
      code = 0
    except ParseError:
      code = 2
    quit(code)
  main()
