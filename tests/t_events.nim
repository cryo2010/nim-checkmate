import std/[unittest, os]
import checkmate/[discovery, events]

let evPath = getTempDir() / "checkmate_t_events.jsonl"

proc writeEvents(lines: openArray[string]) =
  var content = ""
  for l in lines: content.add l & "\n"
  writeFile(evPath, content)

suite "parseEvents":
  teardown:
    removeFile(evPath)

  test "round trip of a passing run":
    writeEvents [
      """{"e":"init","pid":1}""",
      """{"e":"suiteStarted","suite":"s"}""",
      """{"e":"testStarted","test":"a"}""",
      """{"e":"testEnded","suite":"s","test":"a","status":"OK","durMs":1.5}""",
      """{"e":"suiteEnded"}""",
    ]
    let evs = parseEvents(evPath)
    check evs.len == 5
    check evs[3].kind == ekTestEnded
    check evs[3].durMs == 1.5

  test "tolerates malformed, truncated and unknown lines":
    writeEvents [
      """{"e":"testStarted","test":"a"}""",
      """not json at all""",
      """{"e":"fromTheFuture","x":1}""",
      """{"e":"testEnded","suite":"","test":"a","status":"OK","durMs":1}""",
      """{"e":"testStarted","tes""",  # truncated mid-write
    ]
    let evs = parseEvents(evPath)
    check evs.len == 2
  test "missing file yields no events":
    check parseEvents(getTempDir() / "checkmate_no_such.jsonl").len == 0

suite "foldEvents":
  test "attributes failures to the enclosing test":
    let evs = @[
      Event(kind: ekTestStarted, test: "a"),
      Event(kind: ekFailure, checkpoints: @["check failed"], stack: "tb"),
      Event(kind: ekTestEnded, test: "a", status: "FAILED", durMs: 2),
    ]
    let o = foldEvents(evs, 1, false)
    check o.tests.len == 1
    check o.tests[0].status == "FAILED"
    check o.tests[0].checkpoints == @["check failed"]
    check o.tests[0].stack == "tb"

  test "crash: started but never ended with nonzero exit":
    let evs = @[
      Event(kind: ekSuiteStarted, suite: "s"),
      Event(kind: ekTestStarted, test: "boom"),
    ]
    let o = foldEvents(evs, 139, false)
    check o.crashed
    check o.crashedTest == "boom"
    check o.tests[0].status == "CRASHED"
    check o.tests[0].suite == "s"

  test "timeout marks open test as TIMEOUT":
    let evs = @[Event(kind: ekTestStarted, test: "slow")]
    let o = foldEvents(evs, 143, true)
    check not o.crashed
    check o.tests[0].status == "TIMEOUT"

  test "no events + exit 0 = no tests":
    let o = foldEvents(@[], 0, false)
    check o.noTests
    check not o.crashed
  test "no events + nonzero exit = suite-level crash":
    let o = foldEvents(@[], 134, false)
    check o.crashed
    check not o.noTests
  test "failure outside any test becomes toplevel entry":
    let o = foldEvents(@[Event(kind: ekFailure, checkpoints: @["cp"])], 1, false)
    check o.tests.len == 1
    check o.tests[0].name == ToplevelName

suite "splitInProcessRuns":
  proc tr(name, status: string): TestRun =
    TestRun(name: name, status: status, durMs: 1)

  test "k-th occurrence lands in iteration k":
    let outcome = FileRunOutcome(tests: @[
      tr("a", "OK"), tr("a", "FAILED"), tr("a", "OK"),
      tr("b", "OK"), tr("b", "OK"), tr("b", "OK")])
    let runs = splitInProcessRuns(outcome, 3, 1, false, 30.0, "log")
    check runs.len == 3
    for r in runs:
      check r.outcome.tests.len == 2
    check runs[1].outcome.tests[0].status == "FAILED"
    check runs[1].iterFailed
    check not runs[0].iterFailed
    var fo = FileOutcome(compiled: true, runs: runs)
    check fileStatus(fo) == fsFlaky
    check fo.passedIters == 2

  test "iterations after a crash are dropped":
    let outcome = FileRunOutcome(tests: @[
      tr("a", "OK"), tr("a", "CRASHED")], crashed: true, crashedTest: "a")
    let runs = splitInProcessRuns(outcome, 5, 139, false, 10.0, "log")
    check runs.len == 2
    check runs[1].outcome.crashed
    check runs[1].outcome.crashedTest == "a"

  test "timeout marks the final executed iteration":
    let outcome = FileRunOutcome(tests: @[
      tr("a", "OK"), tr("a", "TIMEOUT")])
    let runs = splitInProcessRuns(outcome, 4, 143, true, 10.0, "log")
    check runs.len == 2
    check runs[1].timedOut
    check not runs[0].timedOut

  test "suite-level crash with no tests lands in iteration 1":
    let outcome = FileRunOutcome(crashed: true)
    let runs = splitInProcessRuns(outcome, 3, 139, false, 3.0, "log")
    check runs.len == 1
    check runs[0].outcome.crashed

  test "quit(0)-style masked exit still fails the final iteration":
    let outcome = FileRunOutcome(tests: @[
      tr("a", "OK"), tr("a", "OK")])
    let runs = splitInProcessRuns(outcome, 2, 1, false, 2.0, "log")
    check runs.len == 2
    check not runs[0].iterFailed
    check runs[1].iterFailed  # nonzero process exit lands on the last iteration

suite "aggregation":
  proc iterRun(iteration, exit: int, tests: seq[TestRun]): IterRun =
    IterRun(iteration: iteration, exitCode: exit,
            outcome: FileRunOutcome(tests: tests))
  proc tr(name, status: string): TestRun =
    TestRun(name: name, status: status, durMs: 1)

  test "flaky test counted across iterations":
    var fo = FileOutcome(compiled: true)
    fo.runs = @[
      iterRun(1, 1, @[tr("t", "FAILED")]),
      iterRun(2, 0, @[tr("t", "OK")]),
      iterRun(3, 0, @[tr("t", "OK")]),
    ]
    let agg = aggregateTests(fo)
    check agg.len == 1
    check agg[0].passes == 2
    check agg[0].fails == 1
    check fileStatus(fo) == fsFlaky
    check fo.passedIters == 2

  test "recorded failure fails the file even if exit code is 0":
    # user code calling quit(0) must not mask a FAILED test
    var fo = FileOutcome(compiled: true,
      runs: @[iterRun(1, 0, @[tr("t", "FAILED")])])
    check fileStatus(fo) == fsFail

  test "file status precedence":
    check fileStatus(FileOutcome(compiled: false)) == fsCompileFail
    check fileStatus(FileOutcome(compiled: false, notRun: true)) == fsNotRun
    var pass = FileOutcome(compiled: true,
      runs: @[iterRun(1, 0, @[tr("t", "OK")])])
    check fileStatus(pass) == fsPass
    var fail = FileOutcome(compiled: true,
      runs: @[iterRun(1, 1, @[tr("t", "FAILED")])])
    check fileStatus(fail) == fsFail
    var empty = FileOutcome(compiled: true, runs: @[iterRun(1, 0, @[])])
    empty.runs[0].outcome.noTests = true
    check fileStatus(empty) == fsNoTests
