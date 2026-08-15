## checkmate: a jest-like test runner for Nim.
##
## Subcommands: run (default), init, list. Bare `checkmate` or
## `checkmate tests/foo` dispatches to run, jest-style.

import std/os
import cligen
import checkmate/[config, coverage, discovery, events, runner, report]

const checkmateVersion = "0.1.0"

proc cmRun(paths: seq[string] = @[]; filter: seq[string] = @[];
           loop = 0; jobs = 0; bail = false; timeout = -1;
           verbose = false; color = ""; nimflags: seq[string] = @[];
           coverage = false; passWithNoTests = false;
           allowEmptyTests = false; minLines = 0.0;
           loopInProcess = false; timeTravel = false; timeStart = ""): int =
  ## Discover, compile, and run std/unittest test files.
  try:
    var cfg = loadConfig(findProjectRoot(getCurrentDir()))
    cfg.mergeCli(loop, jobs, timeout, bail, verbose, coverage, color, nimflags,
                 passWithNoTests, allowEmptyTests, minLines, loopInProcess,
                 timeTravel, timeStart)
    let rep = newReporter(cfg, filtered = filter.len > 0)
    let summary = runOnce(cfg, paths, filter, rep)
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
  except UsageError as e:
    stderr.writeLine "checkmate: " & e.msg
    result = 2

proc cmInit(force = false): int =
  ## Generate a checkmate.toml with the default configuration.
  try:
    let path = writeInitToml(getCurrentDir(), force)
    echo "created ", path
    echo "tip: add .checkmate/ to your .gitignore"
    0
  except UsageError as e:
    stderr.writeLine "checkmate: " & e.msg
    2

proc cmList(paths: seq[string] = @[]): int =
  ## Print discovered test files without compiling or running them.
  try:
    let cfg = loadConfig(findProjectRoot(getCurrentDir()))
    for tf in discoverTests(cfg, paths):
      echo tf.relPath
    0
  except UsageError as e:
    stderr.writeLine "checkmate: " & e.msg
    2

when isMainModule:
  clCfg.version = checkmateVersion
  dispatchGen(cmRun, cmdName = "run", dispatchName = "dispatchRun",
    positional = "paths",
    short = {"filter": 't'},
    help = {
      "paths": "test files or directories (default: config [tests].dirs)",
      "filter": "run tests whose name starts or ends with PAT (or raw unittest glob / suite::test)",
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
      "timeStart": "pin the virtual start time (ISO 8601), e.g. 2020-06-15T12:00:00Z",
    })
  dispatchGen(cmInit, cmdName = "init", dispatchName = "dispatchInit",
    help = {"force": "overwrite an existing checkmate.toml"})
  dispatchGen(cmList, cmdName = "list", dispatchName = "dispatchList",
    positional = "paths",
    help = {"paths": "test files or directories (default: config [tests].dirs)"})

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
