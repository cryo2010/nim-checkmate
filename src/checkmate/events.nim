## JSONL event protocol shared vocabulary: parse events emitted by the
## injected formatter, fold them into per-run outcomes, aggregate across
## loop iterations. The inject module cannot import this file (it must be
## self-contained for embedding); an integration test keeps them in sync.

import std/[json, os, sequtils, sets, strutils, tables]
import ./discovery

type
  EventKind* = enum
    ekInit, ekSuiteStarted, ekTestStarted, ekFailure, ekTestEnded, ekSuiteEnded

  Event* = object
    kind*: EventKind
    suite*: string
    test*: string
    status*: string
    durMs*: float
    checkpoints*: seq[string]
    stack*: string

  TestRun* = object
    ## One test in one iteration.
    suite*, name*: string
    status*: string        # OK | FAILED | SKIPPED | CRASHED | TIMEOUT
    durMs*: float
    checkpoints*: seq[string]
    stack*: string

  FileRunOutcome* = object
    tests*: seq[TestRun]
    crashed*: bool         # abnormal termination detected
    crashedTest*: string   # "" if crash outside any test
    noTests*: bool

  IterRun* = object
    iteration*: int        # 1-based
    exitCode*: int
    timedOut*: bool
    durMs*: float
    logPath*: string
    outcome*: FileRunOutcome

  FileOutcome* = object
    tf*: TestFile
    compiled*: bool
    compileLog*: string    # path to compile log
    notRun*: bool          # skipped due to bail
    runs*: seq[IterRun]

  SuiteSummary* = object
    files*: seq[FileOutcome]
    bailed*: bool
    wallMs*: float

  FileStatus* = enum
    fsPass, fsFail, fsFlaky, fsCompileFail, fsNotRun, fsNoTests

  FailureDetail* = object
    iteration*: int
    status*: string
    checkpoints*: seq[string]
    stack*: string

  TestOutcome* = object
    ## One test aggregated across iterations.
    suite*, name*: string
    passes*, fails*, skips*: int
    durationsMs*: seq[float]
    failures*: seq[FailureDetail]

const CrashedName* = "<no test running>"
const ToplevelName* = "<top level>"
const maxStoredFailures* = 20  # per test; counts are exact, details capped

proc parseEvents*(path: string): seq[Event] =
  ## Tolerant parser: unknown event kinds and malformed/truncated lines
  ## are skipped (crash resilience + forward compatibility).
  if not fileExists(path):
    return
  for line in lines(path):
    if line.strip.len == 0: continue
    var node: JsonNode
    try:
      node = parseJson(line)
    except CatchableError:
      continue
    if node.kind != JObject or not node.hasKey("e"): continue
    var ev = Event()
    case node["e"].getStr
    of "init": ev.kind = ekInit
    of "suiteStarted":
      ev.kind = ekSuiteStarted
      ev.suite = node{"suite"}.getStr
    of "testStarted":
      ev.kind = ekTestStarted
      ev.test = node{"test"}.getStr
    of "failure":
      ev.kind = ekFailure
      for c in node{"checkpoints"}.getElems:
        ev.checkpoints.add c.getStr
      ev.stack = node{"stack"}.getStr
    of "testEnded":
      ev.kind = ekTestEnded
      ev.suite = node{"suite"}.getStr
      ev.test = node{"test"}.getStr
      ev.status = node{"status"}.getStr
      ev.durMs = node{"durMs"}.getFloat
    of "suiteEnded":
      ev.kind = ekSuiteEnded
    else:
      continue
    result.add ev

proc foldEvents*(events: seq[Event], exitCode: int, timedOut: bool,
                 testTimeoutMs = 0.0): FileRunOutcome =
  ## Attribute failures to tests, detect crashes (testStarted without
  ## testEnded + abnormal exit) and empty runs. With testTimeoutMs > 0,
  ## a test that COMPLETED but exceeded the per-test budget is rewritten
  ## to TIMEOUT (hung tests are killed by the pool's progress watchdog
  ## before they can complete; this catches the slow-but-finishing rest).
  var openTest = ""
  var openSuite = ""
  var pendingCheckpoints: seq[string]
  var pendingStack = ""
  for ev in events:
    case ev.kind
    of ekInit: discard
    of ekSuiteStarted: openSuite = ev.suite
    of ekSuiteEnded: openSuite = ""
    of ekTestStarted:
      openTest = ev.test
      pendingCheckpoints = @[]
      pendingStack = ""
    of ekFailure:
      if openTest.len > 0:
        pendingCheckpoints.add ev.checkpoints
        if ev.stack.len > 0: pendingStack = ev.stack
      else:
        result.tests.add TestRun(
          suite: openSuite, name: ToplevelName, status: "FAILED",
          checkpoints: ev.checkpoints, stack: ev.stack)
    of ekTestEnded:
      result.tests.add TestRun(
        suite: ev.suite, name: ev.test, status: ev.status,
        durMs: ev.durMs, checkpoints: pendingCheckpoints, stack: pendingStack)
      openTest = ""
      pendingCheckpoints = @[]
      pendingStack = ""
  if testTimeoutMs > 0:
    for t in result.tests.mitems:
      if t.status == "OK" and t.durMs > testTimeoutMs:
        t.status = "TIMEOUT"
        t.checkpoints.add "Test exceeded the timeout (" &
          formatFloat(t.durMs / 1000, ffDecimal, 1) & " s > " &
          formatFloat(testTimeoutMs / 1000, ffDecimal, 1) & " s)"
  if openTest.len > 0 and (exitCode != 0 or timedOut):
    # a recorded failure before the cut-off means the test FAILED and the
    # binary stopped (bail's abortOnError quits before testEnded fires);
    # only an eventless cut-off is a genuine crash
    let status =
      if timedOut: "TIMEOUT"
      elif pendingCheckpoints.len > 0: "FAILED"
      else: "CRASHED"
    if status == "CRASHED":
      result.crashed = true
      result.crashedTest = openTest
    result.tests.add TestRun(
      suite: openSuite, name: openTest, status: status,
      checkpoints: pendingCheckpoints, stack: pendingStack)
  elif result.tests.len == 0:
    if exitCode != 0 or timedOut:
      result.crashed = not timedOut
    else:
      result.noTests = true

proc iterFailed*(run: IterRun): bool =
  ## Trust the exit code, but never let it mask recorded failures: user code
  ## calling quit(0) would otherwise override unittest's setProgramResult(1).
  if run.exitCode != 0 or run.timedOut or run.outcome.crashed:
    return true
  for t in run.outcome.tests:
    if t.status notin ["OK", "SKIPPED"]:
      return true
  false

proc fileStatus*(fo: FileOutcome): FileStatus =
  if fo.notRun: return fsNotRun
  if not fo.compiled: return fsCompileFail
  if fo.runs.len == 0: return fsNotRun
  var failed = 0
  for run in fo.runs:
    if run.iterFailed: inc failed
  if failed == 0:
    if fo.runs.allIt(it.outcome.noTests): return fsNoTests
    fsPass
  elif failed == fo.runs.len:
    fsFail
  else:
    fsFlaky

proc splitInProcessRuns*(outcome: FileRunOutcome, loopN, exitCode: int,
                         timedOut: bool, durMs: float,
                         logPath: string): seq[IterRun] =
  ## Reconstructs per-iteration outcomes from one in-process-looped run:
  ## the overlay repeats each test N times, so the k-th occurrence of a
  ## test name belongs to iteration k. Iterations after a crash or timeout
  ## never ran and are dropped (not counted as passed).
  var occ = initTable[string, int]()
  var slots = newSeq[FileRunOutcome](loopN)
  for t in outcome.tests:
    let key = t.suite & "::" & t.name
    let k = min(occ.getOrDefault(key) + 1, loopN)
    occ[key] = k
    slots[k - 1].tests.add t
    if t.status == "CRASHED":
      slots[k - 1].crashed = true
      slots[k - 1].crashedTest = t.name
  if outcome.crashed and outcome.tests.len == 0:
    slots[0].crashed = true
  if outcome.noTests:
    slots[0].noTests = true
  var last = loopN - 1
  for i in 0 ..< loopN:
    if slots[i].crashed or slots[i].tests.anyIt(it.status == "TIMEOUT"):
      last = i
      break
  if timedOut or exitCode != 0:
    # killed between tests: trailing slots never ran, drop them
    while last > 0 and slots[last].tests.len == 0 and not slots[last].crashed:
      dec last
  # unittest exits 1 whenever any iteration failed, so a nonzero exit is
  # usually already explained by test statuses; only when it is NOT (e.g.
  # quit(1) after all tests passed) does it get pinned on the last iteration
  var explained = timedOut
  for i in 0 .. last:
    if slots[i].crashed or
        slots[i].tests.anyIt(it.status notin ["OK", "SKIPPED"]):
      explained = true
      break
  let perIterMs = durMs / (last + 1).float
  for i in 0 .. last:
    result.add IterRun(
      iteration: i + 1,
      exitCode: if i == last and not explained: exitCode else: 0,
      timedOut: timedOut and i == last,
      durMs: perIterMs, logPath: logPath, outcome: slots[i])

proc totalTestsRun*(s: SuiteSummary): int =
  ## Distinct tests that executed (incl. skipped) across all files.
  for fo in s.files:
    var seen = initHashSet[string]()
    for run in fo.runs:
      for t in run.outcome.tests:
        seen.incl t.suite & "::" & t.name
    result += seen.len

proc passedIters*(fo: FileOutcome): int =
  for run in fo.runs:
    if not run.iterFailed: inc result

proc aggregateTests*(fo: FileOutcome): seq[TestOutcome] =
  ## Merge per-iteration test runs by (suite, name), preserving first-seen order.
  var index = initTable[string, int]()
  for run in fo.runs:
    for t in run.outcome.tests:
      let key = t.suite & "::" & t.name
      if not index.hasKey(key):
        index[key] = result.len
        result.add TestOutcome(suite: t.suite, name: t.name)
      template agg: untyped = result[index[key]]
      case t.status
      of "OK": inc agg.passes
      of "SKIPPED": inc agg.skips
      else: inc agg.fails
      if t.durMs > 0: agg.durationsMs.add t.durMs
      if t.status notin ["OK", "SKIPPED"] and agg.failures.len < maxStoredFailures:
        # counts (fails/passes) are tracked above; details are only for
        # display, so a huge --loop must not hoard checkpoints per failure
        agg.failures.add FailureDetail(
          iteration: run.iteration, status: t.status,
          checkpoints: t.checkpoints, stack: t.stack)
