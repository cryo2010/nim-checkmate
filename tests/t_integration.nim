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
    check "\n      7 |     check a + b == 5" in output  # verbatim source line
    check "\n        a + b was 4" in output       # values nest under the check line
    check "✗ wrong sum" in output                 # failing tests carry a mark
    check "✗ raises" in output
    # exception failures show the raise-site source; the message nests below
    check "\n      9 |     raise newException(ValueError, \"boom\")" in output
    check "\n        Unhandled exception: boom [ValueError]" in output
    check "a + b was 4" in output
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

  test "in-process loop falls back without the overlay":
    let (output, code) = cm("passing", "--loop:2 --loop-in-process --allow-empty-tests")
    check code == 0
    check "falling back to process-level looping" in output

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
    check "raises" notin output   # never executed

  test "bail cuts in-process loop iterations immediately":
    removeFile(fixture("flaky") / "flake_marker")
    let (output, code) = cm("flaky", "--loop:4 --loop-in-process --bail")
    check code == 1
    check "sometimes works" in output
    check "always works" notin output      # iteration 1 aborted before it

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
    check "src/mathlib.nim" in output
    check "(8/11)" in output   # sign branches + neverCalled stay uncovered

  test "min_lines percent gate fails below threshold":
    let (output, code) = cm("covered", "--min-lines:80")
    check code == 1
    check "below the required minimum of 80.0%" in output
    check "src/mathlib.nim has the most uncovered lines: 3" in output

  test "min_lines percent gate passes at threshold":
    let (_, code) = cm("covered", "--min-lines:70")
    check code == 0

  test "negative min_lines caps uncovered lines":
    let (output, code) = cm("covered", "--min-lines:-2")
    check code == 1
    check "3 uncovered lines, more than the allowed 2" in output
    let (_, okCode) = cm("covered", "--min-lines:-3")
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

  test "farm-compiled binary enforces standalone":
    discard cm("empty_test")  # ensure the binary is farm-compiled
    # unset CHECKMATE_EVENTS_FILE: when this suite itself runs under
    # checkmate, the child would otherwise inherit it, suppress its console
    # output, and append its events into OUR events file
    let (output, code) = execCmdEx(
      "env -u CHECKMATE_EVENTS_FILE " &
        quoteShell(fixture("empty_test") / ".checkmate" / "bin" / "tests__t_mixed"),
      workingDir = fixture("empty_test"))
    check code == 1
    check "Test has no assertions" in output

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
    check "tests/helper.nim:6 |   check x > 0" in output
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
    check "\n    4 |   check false" in output  # same-file header still matches
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
    check "14 |   check user.age >= 18 and user.name.len > 0" in output
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
