## End-to-end tests: shell out to the built checkmate binary against the
## fixture projects in tests/fixtures/. Requires `nimble build` first.
## Also keeps the JSONL protocol in sync between the embedded inject module
## and events.nim (see "events protocol round trip").

import std/[unittest, monotimes, os, osproc, strutils, times]
import checkmate/events

let projectRoot = getCurrentDir()
let checkmateBin =
  if getEnv("CHECKMATE_BIN").len > 0: getEnv("CHECKMATE_BIN")
  else: projectRoot / "checkmate"

doAssert fileExists(checkmateBin),
  "checkmate binary not found at " & checkmateBin & " (run `nimble build` first)"

proc fixture(name: string): string =
  projectRoot / "tests" / "fixtures" / name

proc fixtureLine(name, relFile, needle: string): int =
  ## 1-based line of the first occurrence of needle. Assertions derive
  ## line numbers from fixture sources so editing a fixture (moving code,
  ## adding comments) cannot silently break them.
  let lines = readFile(fixture(name) / relFile).splitLines
  for i, ln in lines:
    if needle in ln:
      return i + 1
  doAssert false, "'" & needle & "' not found in " & relFile

proc cm(fixtureName: string, args: string = ""): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShell(checkmateBin) & " --color:never " & args,
            workingDir = fixture(fixtureName))

suite "fixture runs":
  test "passing fixture is green":
    let (output, code) = cm("passing")
    check code == 0
    check "PASS" in output
    check "suites: 2/2 passed" in output

  test "failing fixture reports checkpoints and exits 1":
    let (output, code) = cm("failing")
    check code == 1
    check "● broken" in output   # suite heading above its failing tests
    # line numbers derived from the fixture source, not hardcoded
    let checkLn = fixtureLine("failing", "tests/t_bad.nim", "check a + b == 5")
    let ctxLn = fixtureLine("failing", "tests/t_bad.nim", "let a = 2")
    let raiseLn = fixtureLine("failing", "tests/t_bad.nim", "raise newException")
    check ($checkLn & " |     check a + b == 5") in output  # marked failing line
    check ($ctxLn & " |     let a = 2") in output           # muted context line
    check "\n        a + b was 4" in output       # values nest under the check line
    check "✗ wrong sum" in output                 # failing tests carry a mark
    check "✗ raises" in output
    # exception failures show the raise-site frame; the message nests below
    check ($raiseLn & " |     raise newException(ValueError, \"boom\")") in output
    check "\n        Unhandled exception: boom [ValueError]" in output
    check "suites: 1/2 passed (1 failed)" in output
    check "tests:  2/4 passed (2 failed)" in output

  test "filter runs only matching tests":
    let (output, code) = cm("passing", "-t addition")
    check code == 0
    check "tests:  1/1 passed" in output
    check "no matching tests" in output   # the file without matches

  test "filter matching nothing fails by default":
    let (output, code) = cm("passing", "-t zzz_no_such_test")
    check code == 1
    check "failing because no tests were run" in output

  test "pass-with-no-tests allows zero matches":
    let (_, code) = cm("passing", "-t zzz_no_such_test --pass-with-no-tests")
    check code == 0

  test "consistently failing loops summarize instead of listing iterations":
    let (output, code) = cm("failing", "--loop:3")
    check code == 1
    check "failed in all 3 iterations" in output
    check "also failed in iteration" notin output

  test "loop detects flakes":
    removeFile(fixture("flaky") / "flake_marker")
    let (output, code) = cm("flaky", "--loop:4")
    check code == 1
    check "FLAKY" in output
    check "(passed 2/4)" in output

  test "in-process loop detects flakes with correct iteration counts":
    removeFile(fixture("flaky") / "flake_marker")
    let (output, code) = cm("flaky", "--loop:4 --loop-in-process")
    check code == 1
    check "FLAKY" in output
    check "(passed 2/4)" in output
    check "(flaky: failed 2/4)" in output

  test "in-process loop builds the overlay even with allow-empty-tests":
    # loop_in_process is a farm consumer in its own right: allow_empty_tests
    # must not silently downgrade it to process-level looping
    let (output, code) = cm("passing", "--loop:2 --loop-in-process --allow-empty-tests")
    check code == 0
    check "falling back to process-level looping" notin output

  test "bail skips remaining suites":
    let (output, code) = cm("bail", "--bail")
    check code == 1
    check "(not run)" in output
    check "Bailed on first failure" in output

  test "bail aborts a file mid-run at the first failing test":
    # t_bad.nim: "wrong sum" fails first; "raises" and "still ok" follow
    let (output, code) = cm("failing", "--bail")
    check code == 1
    check "wrong sum" in output
    check "✗ raises" notin output   # never executed (context frames may
                                    # show the word in neighboring source)

  test "bail cuts in-process loop iterations immediately":
    removeFile(fixture("flaky") / "flake_marker")
    let (output, code) = cm("flaky", "--loop:4 --loop-in-process --bail")
    check code == 1
    check "sometimes works" in output
    # iteration 1 aborted before "always works" could run: exactly one test
    # has a result (its name may still appear in context frames)
    check "tests:  0/1 passed (1 failed)" in output

  test "hanging test times out":
    let (output, code) = cm("hanging")
    check code == 1
    check "never finishes" in output
    check "(timed out)" in output

  test "project with no test files fails with a clear message":
    let (output, code) = cm("no_tests")
    check code == 1
    check "no test files found" in output

  test "project with no test files passes with --pass-with-no-tests":
    let (_, code) = cm("no_tests", "--pass-with-no-tests")
    check code == 0

  test "one-second timeout kills a two-second sleeper":
    let (output, code) = cm("sleepy")
    check code == 1
    check "sleeps for 2 seconds" in output
    check "(timed out)" in output

  test "positional files resolve their own project root":
    # a fixture file run from the repo root uses the FIXTURE's config and
    # cache (nearest checkmate.toml to the file), not the repo's
    let (output, code) = execCmdEx(quoteShell(checkmateBin) &
      " --color:never tests/fixtures/failing/tests/t_bad.nim",
      workingDir = projectRoot)
    check code == 1
    check "note: using project at tests/fixtures/failing" in output
    check " FAIL  tests/t_bad.nim" in output   # fixture-relative, not repo-relative

  test "positional files from different projects run as separate groups":
    let (output, code) = execCmdEx(quoteShell(checkmateBin) &
      " --color:never tests/fixtures/failing/tests/t_bad.nim" &
      " tests/fixtures/passing/tests/t_ok.nim",
      workingDir = projectRoot)
    check code == 1                            # combined: failing group fails
    check "using project at tests/fixtures/failing" in output
    check "using project at tests/fixtures/passing" in output
    check " PASS  tests/t_ok.nim" in output

  test "chdir flag runs a fixture from anywhere":
    let (_, code) = execCmdEx(
      quoteShell(checkmateBin) & " --color:never -C " &
      quoteShell(fixture("passing")))
    check code == 0

  test "timeout is per test, not per file":
    # t_steady runs 4.5 s total against a 2 s timeout, but each test
    # resets the progress watchdog, so the file passes
    let (output, code) = cm("hanging", "tests/t_steady.nim")
    check code == 0
    check "3/3 passed" in output

  test "crash is attributed to the open test":
    let (output, code) = cm("crashing")
    check code == 1
    check "dies mid test" in output
    check "(crashed)" in output
    check "SIGSEGV" in output

  test "quit(0) mid-test fails instead of passing":
    let (output, code) = cm("quit_zero")
    check code == 1
    check "quits mid-test" in output
    check "(crashed)" in output
    check "exited cleanly mid-test" in output

  test "duplicate names under in-process loop are not phantom flakes":
    let (output, code) = cm("dup_names", "--loop:2 --loop-in-process")
    check code == 1
    check "roundtrip (2)" in output            # second block, distinct test
    check "FLAKY" notin output                 # fails consistently, no flake
    check "failed in all 2 iterations" in output
    check "tests:  1/2 passed (1 failed)" in output

  test "a stuck test emitting failures forever still times out":
    let t0 = getMonoTime()
    let (output, code) = cm("restless")
    let wallMs = (getMonoTime() - t0).inMilliseconds
    check code == 1
    check "(timed out)" in output
    # compile dominates; the run itself must die at ~1 s, not hang forever
    check wallMs < 60_000

  test "timeout kill takes the test's children with it":
    removeFile(fixture("spawner") / "child.pid")
    let (output, code) = cm("spawner")
    check code == 1
    check "(timed out)" in output
    let pid = parseInt(readFile(fixture("spawner") / "child.pid").strip)
    removeFile(fixture("spawner") / "child.pid")
    var gone = false
    for _ in 1 .. 100:   # up to ~10 s for the tree kill to land
      if execCmd("kill -0 " & $pid & " 2>/dev/null") != 0:
        gone = true
        break
      sleep(100)
    check gone

  test "compile errors pass through verbatim":
    let (output, code) = cm("compile_error")
    check code == 1
    check "(compile failed)" in output
    check "undeclared identifier" in output

  test "captured output is shown for failing files":
    let (output, code) = cm("noisy")
    check code == 1
    check "setup chatter on stdout" in output
    check "setup chatter on stderr" in output
    check "inside the failing test" in output

  test "binaries with their own params work when no filter is used":
    let (_, code) = cm("own_params")
    check code == 0

  test "coverage reports project source lines":
    let (output, code) = cm("covered")
    check code == 0
    check "Coverage (executed lines):" in output
    # line accounting differs between gcov implementations (llvm: 8/11,
    # GNU 13: 9/12), so require a partially-covered mathlib row instead of
    # exact counts: sign branches + neverCalled must stay uncovered
    var sawRow = false
    for ln in output.splitLines:
      if "src/mathlib.nim" in ln and "(" in ln:
        let o = ln.find('(')
        let s = ln.find('/', o)
        let e = ln.find(')', s)
        if o >= 0 and s > o and e > s:
          let c = parseInt(ln[o + 1 ..< s])
          let t = parseInt(ln[s + 1 ..< e])
          check c > 0
          check t > c
          sawRow = true
    check sawRow

  test "min_lines percent gate fails below threshold":
    # generous margins: totals vary by gcov accounting (72-78% observed)
    let (output, code) = cm("covered", "--min-lines:95")
    check code == 1
    check "below the required minimum of 95.0%" in output
    check "src/mathlib.nim has the most uncovered lines: " in output

  test "min_lines percent gate passes at threshold":
    let (_, code) = cm("covered", "--min-lines:50")
    check code == 0

  test "negative min_lines caps uncovered lines":
    # toolchains differ in whether test-file lines get attributed, so the
    # uncovered count is derived from the report rather than hardcoded
    let (rep, repCode) = cm("covered")
    check repCode == 0
    var covered = -1
    var total = -1
    for ln in rep.splitLines:
      if "TOTAL" in ln:
        let o = ln.find('(')
        let s = ln.find('/', o)
        let e = ln.find(')', s)
        if o >= 0 and s > o and e > s:
          covered = parseInt(ln[o + 1 ..< s])
          total = parseInt(ln[s + 1 ..< e])
    check total > covered   # the fixture guarantees uncovered lines exist
    let uncovered = total - covered
    let (output, code) = cm("covered", "--min-lines:-" & $(uncovered - 1))
    check code == 1
    check $uncovered & " uncovered lines, more than the allowed " &
          $(uncovered - 1) in output
    let (_, okCode) = cm("covered", "--min-lines:-" & $uncovered)
    check okCode == 0

  test "min_lines without coverage warns":
    let (output, code) = cm("passing", "--min-lines:80")
    check code == 0
    check "min_lines is set but coverage is not enabled" in output

  test "empty test fails by default":
    let (output, code) = cm("empty_test")
    check code == 1
    check "Test has no assertions" in output
    check "● empty enforcement" in output
    check "tests:  4/6 passed (1 failed, 1 skipped)" in output

  test "allow-empty-tests disables enforcement":
    let (output, code) = cm("empty_test", "--allow-empty-tests")
    check code == 0
    check "Test has no assertions" notin output

  test "farm-compiled binary behaves stock when run standalone":
    discard cm("empty_test")  # ensure the binary is farm-compiled
    # unset checkmate's env vars: when this suite itself runs under
    # checkmate, the child would otherwise inherit them and stop being
    # "standalone" (events into OUR file, enforcement enabled, ...)
    let (output, code) = execCmdEx(
      "env -u CHECKMATE_EVENTS_FILE -u CHECKMATE_ENFORCE_EMPTY" &
      " -u CHECKMATE_MAX_VALUE -u CHECKMATE_BAIL -u CHECKMATE_LOOP " &
        quoteShell(fixture("empty_test") / ".checkmate" / "bin" / "tests__t_mixed"),
      workingDir = fixture("empty_test"))
    check code == 0                            # no enforcement standalone
    check "Test has no assertions" notin output

  test "list prints files without running":
    # subcommand must come first; flags before it would dispatch to run
    let (output, code) = execCmdEx(quoteShell(checkmateBin) & " list",
                                   workingDir = fixture("passing"))
    check code == 0
    check "tests/t_ok.nim" in output
    check "PASS" notin output

suite "check output enrichment":
  test "dollar-less types print via repr and huge values truncate":
    let (output, code) = cm("print_values")
    check code == 1
    check "a was " in output              # absent entirely under stock unittest
    check "b was " in output
    check "... (1600 more chars)" in output
    check count(output, 'x') < 600        # 2000-char value was truncated
    check "strings differ at index 100 (lengths 201 and 201, 1 differing position)" in output
    check "first mismatch at index 2: 3 vs 9" in output
    # divergence past the 400-char truncation window: only the diff shows it
    check "strings differ at index 1500 (lengths 2000 and 2000, 2 differing positions)" in output
    check "brownZfoxZjumps" in output
    check "^   ^" in output   # carets under BOTH divergence columns
    # checks failing inside helper modules show filename:line (and are not
    # silently swallowed by the testStatusIMPL scoping quirk)
    check "tests/helper.nim:" in output          # foreign-file frame heading
    let helperLn = fixtureLine("print_values", "tests/helper.nim", "check x > 0")
    check ($helperLn & " |   check x > 0") in output
    check "x was -5" in output
    check "0/8 passed" in output
    # newlines render as single-column placeholders inside diff windows
    check "fiveXline one" & "␤" & "line two" in output
    check "five" & "␤" & "line one" in output
    check "lengths differ: 3 vs 5" in output

suite "verbose listing":
  test "marks, suite grouping, and timings":
    let (output, code) = cm("passing", "-v")
    check code == 0
    check "\n  math ops\n" in output          # suite heading above its tests
    check "✓ addition works (" in output      # pass mark + timing
    check "✓ bare test passes (" in output    # standalone test, flat layout
    check "○ skipped one (" in output         # skip mark
    let (failOut, _) = cm("failing", "-v")
    check "✗ wrong sum (" in failOut          # fail mark

suite "path display":
  test "long relative paths shorten with preceding ellipsis":
    let (output, code) = cm("long_names")
    check code == 1
    check " ...nested/directory/structure/t_long.nim " in output
    check "tests/very/deeply" notin output   # prefix elided
    # one place deliberately pins the ">" marker with alignment: gutter
    # width is len($(line + context)) with the default context of 3
    let ln = fixtureLine("long_names",
      "tests/very/deeply/nested/directory/structure/t_long.nim", "check false")
    check ("> " & align($ln, len($(ln + 3))) & " |   check false") in output
    # [format] caps from the fixture config (30/30/30)
    check "● this suite name is quite lo..." in output
    check "this test name is also exce..." in output
    check "012345678901234567890123456789 ... (170 more chars)" in output

suite "unittest quirk repairs":
  test "helper bare-fail, duplicate names, and skip-after-fail are truthful":
    let (output, code) = cm("quirks")
    check code == 1
    check "fail() was called (no checkpoint recorded)" in output
    check "duplicate name (2)" in output       # distinct test, not a flake
    check "(flaky" notin output
    check "skips after failing" in output      # FAILED, not silently skipped
    check "1/4 passed (3 failed)" in output

suite "power assert":
  test "boolean connectives decompose with evaluation tracking":
    let (output, code) = cm("power_assert")
    check code == 1
    check "user.age was 16" in output
    check "user.age >= 18 was false" in output
    check "user.name.len was not evaluated" in output
    check "conn was nil" in output
    check "conn.port == 443 was not evaluated" in output   # guard held
    check "code == 200 was false" in output
    check "code == 204 was false" in output                # or: all attempted
    let ln = fixtureLine("power_assert", "tests/t_power.nim",
                         "check user.age >= 18")
    check ($ln & " |   check user.age >= 18 and user.name.len > 0") in output
    # Tier 2 diff windows compose with power-assert
    check "strings differ at index 100 (lengths 225 and 225, 1 differing position)" in output
    check "quick Qrown" in output
    check "first mismatch at index 2: 4 vs 3" in output

suite "time travel":
  test "virtual sleeps finish in real milliseconds":
    let t0 = getMonoTime()
    let (output, code) = cm("time_travel")
    let wallMs = (getMonoTime() - t0).inMilliseconds
    check code == 0
    check "suites: 4/4 passed" in output
    # the fixture sleeps/advances >5 virtual minutes; generous real bound
    # for cold compiles: the run phase itself is milliseconds
    check wallMs < 60_000
    check "tests:  7/7 passed" in output

  test "time-start accepts unix epoch seconds":
    # 1592222400 == 2020-06-15T12:00:00Z, the instant t_pinned asserts
    let (_, code) = cm("time_travel", "--time-start:1592222400")
    check code == 0

  test "time-start CLI override repins the clock":
    # t_pinned asserts year 2020, so a 1999 pin must fail exactly that test
    let (output, code) = cm("time_travel", "--time-start:1999-12-31T00:00:00Z")
    check code == 1
    check "wall clock is pinned to the configured start" in output
    check "tests:  6/7 passed (1 failed)" in output

suite "init generation":
  test "init writes checkmate.toml, refuses overwrite, honors --force":
    let dir = getTempDir() / "checkmate_t_init"
    removeDir(dir)
    createDir(dir)
    let (_, code) = execCmdEx(quoteShell(checkmateBin) & " init", workingDir = dir)
    check code == 0
    check fileExists(dir / "checkmate.toml")
    let (_, again) = execCmdEx(quoteShell(checkmateBin) & " init", workingDir = dir)
    check again == 2  # refuses to overwrite
    let (_, forced) = execCmdEx(quoteShell(checkmateBin) & " init --force",
                                workingDir = dir)
    check forced == 0
    removeDir(dir)

suite "events protocol round trip":
  test "inject module output parses into expected outcomes":
    # run a fixture binary directly with the env var, as checkmate would
    let (_, code) = cm("failing")
    check code == 1
    let binPath = fixture("failing") / ".checkmate" / "bin" / "tests__t_bad"
    let evPath = getTempDir() / "checkmate_t_integration.jsonl"
    removeFile(evPath)
    let cmd = "CHECKMATE_EVENTS_FILE=" & quoteShell(evPath) & " " &
              quoteShell(binPath) & " >/dev/null 2>&1"
    let rc = execCmd("/bin/sh -c " & quoteShell(cmd))
    check rc == 1
    let outcome = foldEvents(parseEvents(evPath), rc, false)
    removeFile(evPath)
    check outcome.tests.len == 3
    check outcome.tests[0].status == "FAILED"
    check outcome.tests[0].suite == "broken"
    check outcome.tests[0].checkpoints.len > 0
    check outcome.tests[2].status == "OK"
    check not outcome.crashed
