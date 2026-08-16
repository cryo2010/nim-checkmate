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
    iter*: int             # in-process loop iteration (0 = untagged binary)
    checkpoints*: seq[string]
    stack*: string

  TestRun* = object
    ## One test in one iteration.
    suite*, name*: string
    status*: string        # OK | FAILED | SKIPPED | CRASHED | TIMEOUT
    durMs*: float
    iter*: int             # overlay iteration tag; 0 when not looping in-process
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
      ev.iter = node{"iter"}.getInt
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
      ev.iter = node{"iter"}.getInt
    of "suiteEnded":
      ev.kind = ekSuiteEnded
    else:
      continue
    result.add ev

proc foldEvents*(events: seq[Event], exitCode: int, timedOut: bool,
                 testTimeoutMs = 0.0): FileRunOutcome =
  ## Attribute failures to tests, detect crashes (testStarted without
  ## testEnded, regardless of exit code) and empty runs. With
  ## testTimeoutMs > 0, a test that COMPLETED but exceeded the per-test
  ## budget is rewritten to TIMEOUT (hung tests are killed by the pool's
  ## progress watchdog before they can complete; this catches the
  ## slow-but-finishing rest).
  var openTest = ""
  var openIter = 0
  var suiteStack: seq[string]   # suites can nest; testEnded carries its own
  var pendingCheckpoints: seq[string]
  var pendingStack = ""
  var pendingFailure = false
  var nameCounts = initTable[string, int]()
  template openSuite: string =
    (if suiteStack.len > 0: suiteStack[^1] else: "")
  for ev in events:
    case ev.kind
    of ekInit: discard
    of ekSuiteStarted: suiteStack.add ev.suite
    of ekSuiteEnded:
      if suiteStack.len > 0: suiteStack.setLen(suiteStack.len - 1)
    of ekTestStarted:
      openTest = ev.test
      openIter = ev.iter
      pendingCheckpoints = @[]
      pendingStack = ""
      pendingFailure = false
    of ekFailure:
      if openTest.len > 0:
        pendingFailure = true
        if ev.checkpoints.len > 0:
          pendingCheckpoints.add ev.checkpoints
        else:
          pendingCheckpoints.add "fail() was called (no checkpoint recorded)"
        if ev.stack.len > 0: pendingStack = ev.stack
      else:
        result.tests.add TestRun(
          suite: openSuite, name: ToplevelName, status: "FAILED",
          checkpoints: ev.checkpoints, stack: ev.stack)
    of ekTestEnded:
      var status = ev.status
      if status in ["OK", "SKIPPED"] and pendingFailure:
        # failureOccurred is authoritative: fail() inside a helper proc
        # cannot see testStatusIMPL (test ends OK), and skip() after a
        # failure clears the status but the exit code already says failed
        status = "FAILED"
      var name = ev.test
      # duplicate test names in one run are DISTINCT tests; without a
      # suffix the aggregation would merge them into a phantom flake.
      # Keyed per iteration so under in-process looping the same block
      # keeps one name across iterations while a second same-named block
      # is suffixed consistently in every iteration.
      let key = ev.suite & "::" & ev.test & "::" & $ev.iter
      let count = nameCounts.getOrDefault(key) + 1
      nameCounts[key] = count
      if count > 1:
        name.add " (" & $count & ")"
      result.tests.add TestRun(
        suite: ev.suite, name: name, status: status, durMs: ev.durMs,
        iter: ev.iter, checkpoints: pendingCheckpoints, stack: pendingStack)
      openTest = ""
      pendingCheckpoints = @[]
      pendingStack = ""
      pendingFailure = false
  if testTimeoutMs > 0:
    for t in result.tests.mitems:
      if t.status == "OK" and t.durMs > testTimeoutMs:
        t.status = "TIMEOUT"
        t.checkpoints.add "Test exceeded the timeout (" &
          formatFloat(t.durMs / 1000, ffDecimal, 1) & " s > " &
          formatFloat(testTimeoutMs / 1000, ffDecimal, 1) & " s)"
  if openTest.len > 0:
    # the binary stopped mid-test: even a CLEAN exit here means this test
    # never finished and everything after it never ran, so quit(0) from
    # user code must not turn a truncated run into a pass. A recorded
    # failure before the cut-off means the test FAILED and the binary
    # stopped (bail's abortOnError quits before testEnded fires); only an
    # eventless cut-off is a genuine crash
    let status =
      if timedOut: "TIMEOUT"
      elif pendingCheckpoints.len > 0: "FAILED"
      else: "CRASHED"
    if status == "CRASHED":
      result.crashed = true
      result.crashedTest = openTest
      if exitCode == 0:
        pendingCheckpoints.add "the process exited cleanly mid-test " &
          "(quit(0) from user code?); this test and everything after it never finished"
    var name = openTest
    let key = openSuite & "::" & openTest & "::" & $openIter
    let count = nameCounts.getOrDefault(key) + 1
    if count > 1:
      # same dedupe as testEnded: a crashing duplicate-named test must not
      # merge with an earlier completed namesake into a phantom flake
      name.add " (" & $count & ")"
    result.tests.add TestRun(
      suite: openSuite, name: name, status: status, iter: openIter,
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
  ## Reconstructs per-iteration outcomes from one in-process-looped run.
  ## Runs carry the overlay's explicit iteration tag; events from an
  ## untagged (older) binary fall back to "the k-th occurrence of a test
  ## name is iteration k". Iterations after a crash or a watchdog kill
  ## never ran and are dropped (not counted as passed).
  var occ = initTable[string, int]()
  var slots = newSeq[FileRunOutcome](loopN)
  for t in outcome.tests:
    var k = t.iter
    if k < 1 or k > loopN:
      let key = t.suite & "::" & t.name
      k = min(occ.getOrDefault(key) + 1, loopN)
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
    # a crashed slot ends the run; a TIMEOUT-status test does so only when
    # the watchdog actually killed the process. The post-hoc rewrite in
    # foldEvents marks slow-but-COMPLETED tests TIMEOUT while later
    # iterations really ran, and those results must not be discarded
    if slots[i].crashed or
        (timedOut and slots[i].tests.anyIt(it.status == "TIMEOUT")):
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
