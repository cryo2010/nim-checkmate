## Stdlib overlay farm: empty-test enforcement and time travel.
##
## Passing checks are invisible to OutputFormatters and clocks cannot be
## virtualized from outside, so both features intercept stdlib modules at
## compile time. `--lib` pointed at a symlink farm (real toolchain lib dir
## mirrored 1:1, with a handful of files replaced) intercepts BOTH
## `import unittest` and `import std/unittest` forms, which plain --path
## shadowing cannot.
##
## Overlays are NOT vendored forks: each is a copy of the user's own
## toolchain source with anchored textual patches plus appended wrappers.
## Every anchor must match exactly once; otherwise the affected feature
## auto-disables with a warning. unittest patch failure kills the whole
## farm; any time-patch failure drops ALL time overlays (all-or-nothing,
## preventing a farm where a frozen monotonic clock hangs asyncdispatch).
##
## Virtualization is runtime-gated by env vars (CHECKMATE_TIME_TRAVEL,
## CHECKMATE_ALLOW_EMPTY, CHECKMATE_LOOP), so toggling features never
## changes compile commands or thrashes nimcaches.

import std/[json, os, osproc, sets, strutils, tables]
import ./config

const OverlayVersion = 9

# --- generated module: the shared virtual clock core ----------------------
# Importable as `import checkmate_timebase` by overlay modules and by user
# helper modules wanting the raw API. Frozen model: no syscalls at all, so
# no import cycles are possible (only std/envvars + std/sysatomics).

const timebaseSource* = """# checkmate: generated time-travel core (overlay farm). Not part of stdlib.
const checkmateTimeTravel* = true

when defined(js) or defined(nimscript):
  proc checkmateTimeTravelEnabled*(): bool = false
  proc timeTravelActive*(): bool = false
  proc advanceTime*(ms: int) = discard
  proc checkmateAdvanceNanos*(ns: int64) = discard
  proc checkmateAdvanceMonoToTicks*(target: int64) = discard
  proc checkmateTravelToWallNs*(target: int64) = discard
  proc checkmateVirtualMonoTicks*(): int64 = 0
  proc checkmateVirtualWallNs*(): int64 = 0
else:
  import std/envvars

  const checkmateDefaultWallNs = 946_684_800'i64 * 1_000_000_000'i64  # 2000-01-01Z
  const checkmateBaseMonoTicks = 1_000_000_000_000'i64                # 1000 s, arbitrary

  proc checkmateParseNs(s: string): int64 =
    if s.len == 0 or s.len > 19: return -1
    for c in s:
      if c < '0' or c > '9': return -1
      result = result * 10 + int64(ord(c) - ord('0'))

  let checkmateTtEnabled = getEnv("CHECKMATE_TIME_TRAVEL") == "1"
  let checkmateBaseWallNs = block:
    let parsed = checkmateParseNs(getEnv("CHECKMATE_TIME_START_NS"))
    if parsed >= 0: parsed else: checkmateDefaultWallNs

  var checkmateMonoOffsetNs: int64   # sleep/advanceTime/async; only grows
  var checkmateWallSkewNs: int64     # travelTo; wall-only jumps, may be negative

  when not declared(atomicAddFetch):
    import std/sysatomics

  proc checkmateTimeTravelEnabled*(): bool {.inline.} = checkmateTtEnabled
  proc timeTravelActive*(): bool {.inline.} = checkmateTtEnabled

  proc checkmateLoadMonoOffset(): int64 {.inline.} =
    atomicLoadN(addr checkmateMonoOffsetNs, ATOMIC_SEQ_CST)

  proc checkmateVirtualMonoTicks*(): int64 {.inline.} =
    checkmateBaseMonoTicks + checkmateLoadMonoOffset()

  proc checkmateVirtualWallNs*(): int64 {.inline.} =
    checkmateBaseWallNs + checkmateLoadMonoOffset() +
      atomicLoadN(addr checkmateWallSkewNs, ATOMIC_SEQ_CST)

  proc checkmateAdvanceNanos*(ns: int64) =
    if ns > 0:
      discard atomicAddFetch(addr checkmateMonoOffsetNs, ns, ATOMIC_SEQ_CST)

  proc advanceTime*(ms: int) =
    ## Advances the virtual clock by ms milliseconds (all clocks).
    checkmateAdvanceNanos(int64(ms) * 1_000_000)

  proc checkmateAdvanceMonoToTicks*(target: int64) =
    let cur = checkmateVirtualMonoTicks()
    if target > cur:
      checkmateAdvanceNanos(target - cur)

  proc checkmateTravelToWallNs*(target: int64) =
    let skew = target - (checkmateBaseWallNs + checkmateLoadMonoOffset())
    atomicStoreN(addr checkmateWallSkewNs, skew, ATOMIC_SEQ_CST)
"""

# --- generic anchored patcher ---------------------------------------------

proc applyAnchorPatches(source: string,
                        patches: openArray[(string, string)],
                        tail = ""): string =
  ## "" if any anchor does not occur exactly once (unknown stdlib layout).
  result = source
  for (anchor, replacement) in patches:
    if result.count(anchor) != 1:
      return ""
    result = result.replace(anchor, replacement)
  result.add tail

# --- pure/unittest.nim ----------------------------------------------------

const unittestPatches: seq[(string, string)] = @[
  # 1: declare the counter before every later reference, rename check
  ("macro check*(conditions: untyped): untyped =",
   """# --- checkmate: empty-test enforcement (generated overlay, part 1) --------
const checkmateEmptyTestGuard* = true
var checkmateAssertions* {.threadvar.}: int

proc checkmateTrim*(s: string): string =
  ## Bounds printed operand values so a failing comparison of huge strings
  ## cannot flood the report; also drops trailing newlines from repr output.
  var t = s
  while t.len > 0 and t[^1] in {'\n', '\r'}:
    t.setLen(t.len - 1)
  const cap = 400
  if t.len <= cap: t
  else: t[0 ..< cap] & " ... (" & $(t.len - cap) & " more chars)"

proc checkmateVisible(c: char): string =
  ## Control chars as single-column placeholders so diff windows stay on
  ## one display line and caret columns line up (one glyph per char).
  case c
  of '\n': "␤"   # symbol for newline
  of '\r': "␍"   # symbol for carriage return
  of '\t': "␉"   # symbol for horizontal tab
  else:
    if c < ' ' or c == '\127': "·"
    else: $c

proc checkmateWindow(s: string, i: int): string =
  let lo = max(0, i - 15)
  let hi = min(s.len, i + 25)
  if lo > 0: result.add "..."
  for p in lo ..< hi:
    result.add checkmateVisible(s[p])
  if hi < s.len: result.add "..."

proc checkmateExplainDiff*(a, b: string) =
  ## Comparison-aware context for failing string equality: first differing
  ## index plus windows around it (long strings only; short values are
  ## already printed in full).
  var i = 0
  while i < min(a.len, b.len) and a[i] == b[i]: inc i
  if i >= a.len and i >= b.len: return
  if max(a.len, b.len) <= 40: return
  var header = "strings differ at index " & $i &
               " (lengths " & $a.len & " and " & $b.len
  if a.len == b.len:
    # positional mismatch count is meaningful only without length drift
    # (an insertion would positionally "differ" everywhere after it)
    var diffs = 0
    for p in 0 ..< a.len:
      if a[p] != b[p]: inc diffs
    header.add ", " & $diffs & " differing position"
    if diffs != 1: header.add "s"
  header.add ")"
  checkpoint(header)
  checkpoint("  lhs: " & checkmateWindow(a, i))
  checkpoint("  rhs: " & checkmateWindow(b, i))
  # carets under every mismatching column inside the window; keep the
  # geometry in sync with checkmateWindow
  let lo = max(0, i - 15)
  let hiCommon = min(min(a.len, b.len), i + 25)
  var caretLine = ""
  for _ in 1 .. len("  rhs: ") + (if lo > 0: 3 else: 0):
    caretLine.add ' '
  for p in lo ..< hiCommon:
    caretLine.add (if a[p] != b[p]: '^' else: ' ')
  if a.len != b.len and min(a.len, b.len) < i + 25:
    caretLine.add '^'  # divergence by length: one string ends here
  while caretLine.len > 0 and caretLine[^1] == ' ':
    caretLine.setLen(caretLine.len - 1)
  if caretLine.len > 0 and caretLine[^1] == '^':
    checkpoint(caretLine)

proc checkmateExplainDiffSeq[T](a, b: openArray[T]) =
  var i = 0
  while i < min(a.len, b.len) and a[i] == b[i]: inc i
  if i >= a.len and i >= b.len: return
  if a.len != b.len:
    checkpoint("lengths differ: " & $a.len & " vs " & $b.len)
  if i < min(a.len, b.len):
    when compiles($a[i]):
      checkpoint("first mismatch at index " & $i & ": " &
                 checkmateTrim($a[i]) & " vs " & checkmateTrim($b[i]))
    elif compiles(checkmateTrim(repr(a[i]))):
      checkpoint("first mismatch at index " & $i & ": " &
                 checkmateTrim(repr(a[i])) & " vs " & checkmateTrim(repr(b[i])))
    else:
      checkpoint("first mismatch at index " & $i)

proc checkmateExplainDiff*[T](a, b: seq[T]) =
  checkmateExplainDiffSeq(a, b)

proc checkmateExplainDiff*[I; T](a, b: array[I, T]) =
  checkmateExplainDiffSeq(a, b)

proc checkmateExplainDiff*[A; B](a: A, b: B) {.inline.} =
  discard  # no extra context for other types

macro checkmateOrigCheck*(conditions: untyped): untyped ="""),
  # inject the diff explainer into the printouts of failing == checks
  ("""    let (assigns, check, printOuts) = inspectArgs(checked)
    let lineinfo = newStrLitNode(checked.lineInfo)""",
   """    let (assigns, check, printOuts) = inspectArgs(checked)
    if check.kind == nnkInfix and check.len == 3 and
        check[0].kind in {nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice,
                          nnkSym} and
        $check[0] == "==":
      printOuts.add newCall(bindSym"checkmateExplainDiff", check[1], check[2])
    let lineinfo = newStrLitNode(checked.lineInfo)"""),
  # richer operand printing: repr fallback for $-less types, bounded length
  ("""  template print(name: untyped, value: typed) =
    when compiles(string($value)):
      checkpoint(name & " was " & $value)""",
   """  template print(name: untyped, value: typed) =
    when compiles(string($value)):
      checkpoint(name & " was " & checkmateTrim($value))
    elif compiles(checkmateTrim(repr(value))):
      checkpoint(name & " was " & checkmateTrim(repr(value)))"""),
  # 2: rename test
  ("template test*(name, body) {.dirty.} =",
   "template checkmateOrigTest*(name, body) {.dirty.} ="),
  # 3: rename expect
  ("macro expect*(exceptions: varargs[typed], body: untyped): untyped =",
   "macro checkmateOrigExpect*(exceptions: varargs[typed], body: untyped): untyped ="),
  # 4: count inside require (not renamed, no wrapper; both referenced
  #    symbols are declared before require via patch 1)
  ("""  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    check conditions
  abortOnError = savedAbortOnError""",
   """  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    inc checkmateAssertions
    checkmateOrigCheck conditions
  abortOnError = savedAbortOnError"""),
]

const unittestTail = """

# --- checkmate: generated overlay, part 2 ---------------------------------

import std/os as checkmateOs
from std/strutils as checkmateStrutils import parseInt
import checkmate_timebase
export checkmate_timebase

proc advanceTime*(d: Duration) =
  ## Advances the virtual clock (monotonic and wall) by `d`.
  checkmateAdvanceNanos(d.inNanoseconds)

proc travelTo*(t: Time) =
  ## Jumps the virtual wall clock to `t`; the monotonic clock is unaffected.
  checkmateTravelToWallNs(t.toUnix() * 1_000_000_000'i64 + t.nanosecond)

proc travelTo*(dt: DateTime) =
  travelTo(dt.toTime())

# --- power-assert: subexpression recording through and/or/not -------------
# Activates only when the top-level expression uses boolean connectives
# (which stock check does not decompose at all); plain comparisons keep the
# original path. Values are recorded AS the expression evaluates, so
# short-circuit semantics are exact and unevaluated branches are reported
# as such rather than evaluated speculatively (a nil-guarded dereference
# must never run).

var checkmateRecords* {.threadvar.}: seq[(string, string)]

proc checkmateRecordVal*[T](val: T, exprText: string): T =
  when compiles($val):
    checkmateRecords.add((exprText, checkmateTrim($val)))
  elif compiles(checkmateTrim(repr(val))):
    checkmateRecords.add((exprText, checkmateTrim(repr(val))))
  else:
    checkmateRecords.add((exprText, "<unprintable>"))
  val

const checkmateCmpOps = ["==", "!=", "<", "<=", ">", ">=", "in", "notin",
                         "is", "isnot"]

proc checkmateIsInfixOf(n: NimNode, ops: openArray[string]): bool =
  n.kind == nnkInfix and n.len == 3 and
    n[0].kind in {nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice, nnkSym} and
    $n[0] in ops

proc checkmateSkipOperand(n: NimNode): bool =
  if n.kind in nnkLiterals: return true
  if n.kind in {nnkNilLit, nnkBracket, nnkTupleConstr}: return true
  if n.kind == nnkPrefix and n.len == 2 and n[0].kind == nnkIdent and
      $n[0] == "@" and n[1].kind == nnkBracket:
    return true
  if n.kind == nnkIdent and $n in ["true", "false", "nil"]: return true
  false

proc checkmateWrapVal(n: NimNode, texts: var seq[string]): NimNode =
  let txt = n.repr
  texts.add txt
  newCall(bindSym"checkmateRecordVal", n, newLit(txt))

proc checkmateInstrument(n: NimNode, texts: var seq[string]): NimNode =
  if n.kind == nnkPar and n.len == 1:
    newTree(nnkPar, checkmateInstrument(n[0], texts))
  elif checkmateIsInfixOf(n, ["and", "or"]):
    newTree(nnkInfix, n[0], checkmateInstrument(n[1], texts),
            checkmateInstrument(n[2], texts))
  elif n.kind == nnkPrefix and n.len == 2 and n[0].kind == nnkIdent and
      $n[0] == "not":
    newTree(nnkPrefix, n[0], checkmateInstrument(n[1], texts))
  elif checkmateIsInfixOf(n, checkmateCmpOps):
    let origTxt = n.repr
    var op1 = n[1]
    var op2 = n[2]
    if not checkmateSkipOperand(op1):
      op1 = checkmateWrapVal(op1, texts)
    if $n[0] notin ["is", "isnot"] and not checkmateSkipOperand(op2):
      op2 = checkmateWrapVal(op2, texts)
    let cmpNode = newTree(nnkInfix, n[0], op1, op2)
    texts.add origTxt
    newCall(bindSym"checkmateRecordVal", cmpNode, newLit(origTxt))
  else:
    checkmateWrapVal(n, texts)

macro checkmatePowerCheck*(cond: untyped, lineTxt: static string): untyped =
  # lineTxt is captured by the dispatching check macro BEFORE splicing:
  # quote do would otherwise smear the overlay's own line info onto cond
  var texts: seq[string]
  let inst = checkmateInstrument(cond, texts)
  let exprTxt = newLit(cond.repr)
  let lineLit = newLit(lineTxt)
  let textsLit = newLit(texts)
  result = quote do:
    block:
      let checkmateRecStart = checkmateRecords.len
      let checkmateCondVal = `inst`
      if not checkmateCondVal:
        checkpoint(`lineLit` & ": Check failed: " & `exprTxt`)
        var checkmatePrinted: seq[(string, string)]
        for checkmateK in checkmateRecStart ..< checkmateRecords.len:
          if checkmateRecords[checkmateK] notin checkmatePrinted:
            checkpoint(checkmateRecords[checkmateK][0] & " was " &
                       checkmateRecords[checkmateK][1])
            checkmatePrinted.add checkmateRecords[checkmateK]
        for checkmateTxt in `textsLit`:
          var checkmateFound = false
          for checkmateK in checkmateRecStart ..< checkmateRecords.len:
            if checkmateRecords[checkmateK][0] == checkmateTxt:
              checkmateFound = true
          if not checkmateFound:
            checkpoint(checkmateTxt & " was not evaluated")
        checkmateRecords.setLen(checkmateRecStart)
        fail()
      else:
        checkmateRecords.setLen(checkmateRecStart)

proc checkmateTopIsBool(n: NimNode): bool =
  (n.kind == nnkInfix and n.len == 3 and
   n[0].kind in {nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice, nnkSym} and
   $n[0] in ["and", "or"]) or
  (n.kind == nnkPrefix and n.len == 2 and n[0].kind == nnkIdent and
   $n[0] == "not") or
  (n.kind == nnkPar and n.len == 1 and checkmateTopIsBool(n[0]))

macro check*(conditions: untyped): untyped =
  if conditions.kind == nnkStmtList:
    result = newStmtList()
    for node in conditions:
      if node.kind != nnkCommentStmt:
        result.add newCall(newIdentNode("check"), node)
  elif checkmateTopIsBool(conditions):
    let lineLit = newLit(conditions.lineInfo)
    result = newStmtList(
      newCall(newIdentNode("inc"), newIdentNode("checkmateAssertions")),
      newCall(bindSym"checkmatePowerCheck", conditions, lineLit))
  else:
    # newCall shares the conditions node without copying: quote do would
    # re-stamp its line info and break checkmateOrigCheck's callsite()
    result = newStmtList(
      newCall(newIdentNode("inc"), newIdentNode("checkmateAssertions")),
      newCall(bindSym"checkmateOrigCheck", conditions))

macro expect*(exceptions: varargs[typed], body: untyped): untyped =
  var origCall = newCall(newIdentNode("checkmateOrigExpect"))
  for e in exceptions:
    origCall.add e
  origCall.add body
  result = quote do:
    inc checkmateAssertions
    `origCall`

var checkmateLoopNCache = -1

proc checkmateLoopCount*(): int =
  ## In-process loop count from CHECKMATE_LOOP; 1 (stock) when unset/invalid.
  if checkmateLoopNCache < 0:
    checkmateLoopNCache = 1
    let v = checkmateOs.getEnv("CHECKMATE_LOOP")
    if v.len > 0:
      try:
        checkmateLoopNCache = max(1, checkmateStrutils.parseInt(v))
      except ValueError:
        discard
  checkmateLoopNCache

var checkmateAllowEmptyCache = -1

proc checkmateAllowEmpty*(): bool =
  ## Runtime opt-out of empty-test enforcement (CHECKMATE_ALLOW_EMPTY=1),
  ## set by checkmate when allow_empty_tests is on but the farm is needed
  ## anyway (e.g. for time travel).
  if checkmateAllowEmptyCache < 0:
    checkmateAllowEmptyCache =
      if checkmateOs.getEnv("CHECKMATE_ALLOW_EMPTY") == "1": 1 else: 0
  checkmateAllowEmptyCache == 1

template test*(name, body) {.dirty.} =
  # the loop wraps the ORIGINAL test template, so suite setup/teardown and
  # testStarted/testEnded events all fire once per iteration
  for checkmateLoopIter in 1 .. checkmateLoopCount():
    checkmateOrigTest name:
      let checkmateAssertionsBefore {.used.} = checkmateAssertions
      body
      if checkmateAssertions == checkmateAssertionsBefore and
          testStatusIMPL == TestStatus.OK and not checkmateAllowEmpty():
        checkpoint("Test has no assertions (checkmate: add a check, or run with --allow-empty-tests)")
        fail()
"""

proc patchUnittest*(source: string): string =
  applyAnchorPatches(source, unittestPatches, unittestTail)

# --- pure/times.nim -------------------------------------------------------

const timesPatches: seq[(string, string)] = @[
  ("import std/[strutils, math, options]",
   """import std/[strutils, math, options]
when not (defined(js) or defined(nimscript)):
  import checkmate_timebase"""),
  ("proc getTime*(): Time {.tags: [TimeEffect], gcsafe.} =",
   "proc checkmateOrigGetTime*(): Time {.tags: [TimeEffect], gcsafe.} ="),
  # the getTime wrapper must be declared BEFORE now() (which calls it), so
  # it is inserted here rather than appended
  ("proc now*(): DateTime {.tags: [TimeEffect], gcsafe.} =",
   """proc getTime*(): Time {.tags: [TimeEffect], gcsafe.} =
  ## Gets the current time (virtual under checkmate time travel).
  when nimvm:
    checkmateOrigGetTime()
  else:
    when defined(js) or defined(nimscript):
      checkmateOrigGetTime()
    else:
      if checkmateTimeTravelEnabled():
        let ns = checkmateVirtualWallNs()
        initTime(floorDiv(ns, 1_000_000_000'i64),
                 floorMod(ns, 1_000_000_000'i64).NanosecondRange)
      else:
        checkmateOrigGetTime()

proc now*(): DateTime {.tags: [TimeEffect], gcsafe.} ="""),
  ("proc epochTime*(): float {.tags: [TimeEffect].} =",
   "proc checkmateOrigEpochTime*(): float {.tags: [TimeEffect].} ="),
]

const timesTail = """

# --- checkmate: time-travel overlay (generated) ---------------------------
proc epochTime*(): float {.tags: [TimeEffect].} =
  ## Unix epoch seconds (virtual under checkmate time travel).
  when defined(js) or defined(nimscript):
    checkmateOrigEpochTime()
  else:
    if checkmateTimeTravelEnabled():
      checkmateVirtualWallNs().float / 1e9
    else:
      checkmateOrigEpochTime()
"""

proc patchTimes*(source: string): string =
  applyAnchorPatches(source, timesPatches, timesTail)

# --- std/monotimes.nim ----------------------------------------------------

const monotimesPatches: seq[(string, string)] = @[
  # exported rename: also the inject formatter's real-clock escape hatch
  ("proc getMonoTime*(): MonoTime {.tags: [TimeEffect].} =",
   "proc checkmateOrigGetMonoTime*(): MonoTime {.tags: [TimeEffect].} ="),
]

const monotimesTail = """

# --- checkmate: time-travel overlay (generated) ---------------------------
when not (defined(js) or defined(nimscript)):
  import checkmate_timebase
  proc getMonoTime*(): MonoTime {.tags: [TimeEffect].} =
    ## Monotonic timestamp (virtual under checkmate time travel).
    if checkmateTimeTravelEnabled():
      MonoTime(ticks: checkmateVirtualMonoTicks())
    else:
      checkmateOrigGetMonoTime()
else:
  proc getMonoTime*(): MonoTime {.tags: [TimeEffect].} =
    checkmateOrigGetMonoTime()
"""

proc patchMonotimes*(source: string): string =
  applyAnchorPatches(source, monotimesPatches, monotimesTail)

# --- pure/os.nim ----------------------------------------------------------

const osPatches: seq[(string, string)] = @[
  # the whole sleep proc (sits inside `when not weirdTarget:`, 2-space indent)
  ("""  proc sleep*(milsecs: int) {.rtl, extern: "nos$1", tags: [TimeEffect], noWeirdTarget.} =
    ## Sleeps `milsecs` milliseconds.
    ## A negative `milsecs` causes sleep to return immediately.
    when defined(windows):
      if milsecs < 0:
        return  # fixes #23732
      winlean.sleep(int32(milsecs))
    else:
      var a, b: Timespec = default(Timespec)
      a.tv_sec = posix.Time(milsecs div 1000)
      a.tv_nsec = (milsecs mod 1000) * 1000 * 1000
      discard posix.nanosleep(a, b)""",
   """  import checkmate_timebase

  proc checkmateOrigSleep*(milsecs: int) {.tags: [TimeEffect], noWeirdTarget.} =
    ## Sleeps `milsecs` milliseconds (real clock, checkmate escape hatch).
    ## A negative `milsecs` causes sleep to return immediately.
    when defined(windows):
      if milsecs < 0:
        return  # fixes #23732
      winlean.sleep(int32(milsecs))
    else:
      var a, b: Timespec = default(Timespec)
      a.tv_sec = posix.Time(milsecs div 1000)
      a.tv_nsec = (milsecs mod 1000) * 1000 * 1000
      discard posix.nanosleep(a, b)

  proc sleep*(milsecs: int) {.rtl, extern: "nos$1", tags: [TimeEffect], noWeirdTarget.} =
    ## Sleeps `milsecs` milliseconds (virtual under checkmate time travel).
    if checkmateTimeTravelEnabled():
      if milsecs > 0:
        checkmateAdvanceNanos(int64(milsecs) * 1_000_000)
    else:
      checkmateOrigSleep(milsecs)"""),
]

proc patchOs*(source: string): string =
  applyAnchorPatches(source, osPatches)

# --- pure/asyncdispatch.nim -----------------------------------------------
# Conservative auto-advance: jump the virtual clock to the next timer only
# when nothing else is pending, so sleepAsync completes instantly but a
# timeout racing real I/O never fires eagerly (the checkmate real-time
# watchdog backstops the never-expires case).

const asyncdispatchPatches: seq[(string, string)] = @[
  ("import std/[math, monotimes]",
   "import std/[math, monotimes]\nimport checkmate_timebase"),
  # posix runOnce
  ("""    result = false
    var keys: array[64, ReadyKey]
    let nextTimer = processTimers(p, result)""",
   """    result = false
    if checkmateTimeTravelEnabled() and p.timers.len != 0 and
        p.selector.isEmpty() and p.callbacks.len == 0:
      checkmateAdvanceMonoToTicks(p.timers[0].finishAt.ticks)
    var keys: array[64, ReadyKey]
    let nextTimer = processTimers(p, result)"""),
  # windows runOnce
  ("""    result = false
    let nextTimer = processTimers(p, result)
    let at = adjustTimeout(p, timeout, nextTimer)""",
   """    result = false
    if checkmateTimeTravelEnabled() and p.timers.len != 0 and
        p.handles.len == 0 and p.callbacks.len == 0:
      checkmateAdvanceMonoToTicks(p.timers[0].finishAt.ticks)
    let nextTimer = processTimers(p, result)
    let at = adjustTimeout(p, timeout, nextTimer)"""),
]

proc patchAsyncdispatch*(source: string): string =
  applyAnchorPatches(source, asyncdispatchPatches)

# --- overlay assembly -----------------------------------------------------

type OverlaySet* = object
  unittestOk*: bool
  timeOk*: bool
  timeWarning*: string
  overlays*: seq[(string, string)]  # (relPath with '/', content)

proc buildOverlays*(libDir: string): OverlaySet =
  let unittestPath = libDir / "pure" / "unittest.nim"
  var unittestSrc: string
  try:
    unittestSrc = readFile(unittestPath)
  except IOError:
    return
  let patchedUnittest = patchUnittest(unittestSrc)
  if patchedUnittest.len == 0:
    return
  result.unittestOk = true
  result.overlays.add ("pure/unittest.nim", patchedUnittest)

  let timePatchers: array[4, tuple[rel: string,
                                   fn: proc(s: string): string {.nimcall.}]] = [
    ("pure/times.nim", patchTimes),
    ("std/monotimes.nim", patchMonotimes),
    ("pure/os.nim", patchOs),
    ("pure/asyncdispatch.nim", patchAsyncdispatch),
  ]
  var timeOverlays: seq[(string, string)]
  for (rel, fn) in timePatchers:
    var src: string
    try:
      src = readFile(libDir / rel.replace("/", $DirSep))
    except IOError:
      result.timeWarning = "time travel unavailable: cannot read " & libDir / rel
      return
    let patched = fn(src)
    if patched.len == 0:
      result.timeWarning = "time travel unavailable: " & libDir / rel &
        " does not match the expected layout"
      return  # all-or-nothing: no time overlays at all
    timeOverlays.add (rel, patched)
  result.timeOk = true
  result.overlays.add timeOverlays
  result.overlays.add ("pure/checkmate_timebase.nim", timebaseSource)

# --- farm building --------------------------------------------------------

proc buildFarm*(libDir, farm: string, overlays: seq[(string, string)]) =
  removeDir(farm)
  var overridden = initTable[string, HashSet[string]]()  # top dir -> basenames
  for (rel, _) in overlays:
    let parts = rel.split('/', maxsplit = 1)
    overridden.mgetOrPut(parts[0], initHashSet[string]()).incl parts[1]
  createDir(farm)
  for entry in walkDir(libDir):
    let name = extractFilename(entry.path)
    if overridden.hasKey(name):
      createDir(farm / name)
      for child in walkDir(entry.path):
        let childName = extractFilename(child.path)
        if childName notin overridden[name]:
          createSymlink(child.path, farm / name / childName)
    else:
      createSymlink(entry.path, farm / name)
  for (rel, content) in overlays:
    let dest = farm / rel.replace("/", $DirSep)
    # hard guard against ever writing an overlay through a symlink into the
    # real toolchain (a farm-layout bug elsewhere must not become data loss)
    if symlinkExists(dest):
      removeFile(dest)
    writeFile(dest, content)

proc resolveNimLib*(cfg: Config): string =
  ## Toolchain lib dir via `nim dump`; honors the project's own nim config
  ## because it runs in projectRoot. "" on any failure.
  try:
    let (output, code) = execCmdEx(
      quoteShell(cfg.nimBin) & " dump --dump.format:json --hints:off checkmate_dump",
      options = {poUsePath, poEvalCommand},  # no poStdErrToStdOut: keep JSON clean
      workingDir = cfg.projectRoot)
    if code != 0: return ""
    let jsonStart = output.find('{')
    if jsonStart < 0: return ""
    let node = parseJson(output[jsonStart .. ^1])
    result = node{"libpath"}.getStr
    if not dirExists(result): result = ""
  except CatchableError:
    result = ""

proc prepareLibFarm*(cfg: Config):
    tuple[ok, timeOk: bool; dir, warning, timeWarning: string] =
  const disabled = "empty-test enforcement disabled: "
  let libDir = resolveNimLib(cfg)
  if libDir.len == 0:
    result.warning = disabled & "could not resolve the nim lib dir via '" &
      cfg.nimBin & " dump'"
    return
  let ovs = buildOverlays(libDir)
  if not ovs.unittestOk:
    result.warning = disabled & libDir / "pure" / "unittest.nim" &
      " does not match the expected layout; set allow_empty_tests = true to silence"
    return
  result.timeOk = ovs.timeOk
  result.timeWarning = ovs.timeWarning
  result.dir = cfg.cacheDir / "libfarm"
  let stampPath = cfg.cacheDir / "libfarm.stamp"
  let stamp = libDir & "\n" & $OverlayVersion & "\ntime=" & $ovs.timeOk
  # rebuild only when stale; stable overlay mtimes keep nimcaches valid
  var fresh = fileExists(stampPath) and readFile(stampPath) == stamp
  if fresh:
    for (rel, content) in ovs.overlays:
      let path = result.dir / rel.replace("/", $DirSep)
      if not fileExists(path) or readFile(path) != content:
        fresh = false
        break
  if not fresh:
    try:
      createDir(cfg.cacheDir)
      buildFarm(libDir, result.dir, ovs.overlays)
      writeFile(stampPath, stamp)
    except OSError as e:
      return (false, false, "", disabled & "cannot build lib overlay: " & e.msg,
              result.timeWarning)
  result.ok = true
