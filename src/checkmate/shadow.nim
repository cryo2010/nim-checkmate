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
## CHECKMATE_ENFORCE_EMPTY, CHECKMATE_LOOP), so toggling features never
## changes compile commands or thrashes nimcaches. Every gate defaults to
## OFF when its var is absent, so a farm-compiled binary run standalone
## behaves like a stock std/unittest build.

import std/[json, os, osproc, sets, strutils, tables]
import ./config

const OverlayVersion = 16

# --- generated module: the shared virtual clock core ----------------------
# Importable as `import checkmate_timebase` by overlay modules and by user
# helper modules wanting the raw API. Frozen model: no syscalls at all, so
# no import cycles are possible (only std/envvars + std/sysatomics).

const timebaseSource* = """# checkmate: generated time-travel core (overlay farm). Not part of stdlib.
const checkmateTimeTravel* = true

when defined(js) or defined(nimscript):
  proc checkmateTimeTravelEnabled*(): bool = false
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

import std/envvars as checkmateEnvvars

var checkmateMaxValueCache = -1

proc checkmateMaxValueCap(): int =
  ## Printed-value cap from CHECKMATE_MAX_VALUE ([format] max_value);
  ## 0 disables truncation. Unset (a standalone run outside checkmate)
  ## means stock behavior: no truncation at all.
  if checkmateMaxValueCache < 0:
    checkmateMaxValueCache = 0
    let v = checkmateEnvvars.getEnv("CHECKMATE_MAX_VALUE")
    if v.len > 0:
      var n = 0
      var valid = true
      for c in v:
        if c in {'0' .. '9'}:
          # saturate instead of rejecting: an absurdly large cap must mean
          # "effectively unlimited", never a silent fallback
          if n < 100_000_000: n = n * 10 + ord(c) - ord('0')
        else: valid = false
      if valid: checkmateMaxValueCache = n
  checkmateMaxValueCache

proc checkmateTrim*(s: string): string =
  ## Bounds printed operand values so a failing comparison of huge strings
  ## cannot flood the report; also drops trailing newlines from repr output.
  var t = s
  while t.len > 0 and t[^1] in {'\n', '\r'}:
    t.setLen(t.len - 1)
  let cap = checkmateMaxValueCap()
  if cap <= 0 or t.len <= cap: t
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

proc checkmateDiffLines*(a, b: string): seq[string] =
  ## Comparison-aware context for failing string equality: first differing
  ## index plus windows around it (long strings only; short values are
  ## already printed in full). Line-based so both the plain and the
  ## power-assert paths can emit it.
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
  result.add header
  result.add "  lhs: " & checkmateWindow(a, i)
  result.add "  rhs: " & checkmateWindow(b, i)
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
    result.add caretLine

proc checkmateDiffLinesSeq[T](a, b: openArray[T]): seq[string] =
  var i = 0
  while i < min(a.len, b.len) and a[i] == b[i]: inc i
  if i >= a.len and i >= b.len: return
  if a.len != b.len:
    result.add "lengths differ: " & $a.len & " vs " & $b.len
  if i < min(a.len, b.len):
    when compiles($a[i]):
      result.add "first mismatch at index " & $i & ": " &
                 checkmateTrim($a[i]) & " vs " & checkmateTrim($b[i])
    elif compiles(checkmateTrim(repr(a[i]))):
      result.add "first mismatch at index " & $i & ": " &
                 checkmateTrim(repr(a[i])) & " vs " & checkmateTrim(repr(b[i]))
    else:
      result.add "first mismatch at index " & $i

proc checkmateDiffLines*[T](a, b: seq[T]): seq[string] =
  checkmateDiffLinesSeq(a, b)

proc checkmateDiffLines*[I; T](a, b: array[I, T]): seq[string] =
  checkmateDiffLinesSeq(a, b)

proc checkmateDiffLines*[A; B](a: A, b: B): seq[string] =
  discard  # no extra context for other types

proc checkmateExplainDiff*[A; B](a: A, b: B) =
  for checkmateLine in checkmateDiffLines(a, b):
    checkpoint(checkmateLine)

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

# The time-travel control API (advanceTime/travelTo/timeTravelActive) is no
# longer injected here: it lives in the importable `checkmate` module so a
# test that uses it stays honest about its dependency and still compiles under
# stock std/unittest. The transparent clock overlays (times/os/monotimes/
# asyncdispatch) are unaffected.

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

proc checkmateRecordEqOutcome*[A; B](res: bool, a: A, b: B, cmpTxt: string): bool =
  ## Records an == comparison's result and, on mismatch, defers the Tier 2
  ## diff lines into the record stream (text "" marks a raw line). The
  ## comparison itself happens at the CALL SITE, never in here: a generic
  ## `a == b` would bind a literal operand as int and fail to compile
  ## against sized types (`x == 0` with x: uint8). Deferral matters: a
  ## failing == inside a passing `or` chain must stay silent.
  result = res
  checkmateRecords.add((cmpTxt, $result))
  if not result:
    for checkmateLine in checkmateDiffLines(a, b):
      checkmateRecords.add(("", checkmateLine))

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

proc checkmateVerbatimOperand(n: NimNode): bool =
  ## Effect-free nodes that may be REPEATED verbatim in generated code.
  ## Repeating matters for ==: a raw literal keeps its flexible type and
  ## unifies against the other side (`x == 0` with x: uint8), while a
  ## let-bound copy would harden to int. Constructors like @[...] are
  ## skip-operands but NOT verbatim: their elements may have effects.
  n.kind in nnkLiterals or
    (n.kind == nnkIdent and $n in ["true", "false", "nil"])

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
    let typeLevel = $n[0] in ["is", "isnot"]
    var op1 = n[1]
    var op2 = n[2]
    if not typeLevel:
      # is/isnot operands stay untouched: either side may be a typedesc
      # (`User is object`), which cannot be passed as a runtime value, and
      # `is` folds at compile time without evaluating its operand anyway,
      # so a recording wrapper would be dead code even for values
      if not checkmateSkipOperand(op1):
        op1 = checkmateWrapVal(op1, texts)
      if not checkmateSkipOperand(op2):
        op2 = checkmateWrapVal(op2, texts)
    texts.add origTxt
    if $n[0] == "==":
      # the recorder needs BOTH typed operands for diff windows, but the
      # comparison must be emitted VERBATIM here so a literal operand still
      # unifies against the other side's type. Verbatim-safe nodes repeat;
      # everything else is let-bound once (single evaluation; the RecordVal
      # wrapper inside the binding records the operand exactly once)
      var stmts = newStmtList()
      var aRef = op1
      var bRef = op2
      if not checkmateVerbatimOperand(n[1]):
        let cmA = genSym(nskLet, "checkmateEqA")
        stmts.add newLetStmt(cmA, op1)
        aRef = cmA
      if not checkmateVerbatimOperand(n[2]):
        let cmB = genSym(nskLet, "checkmateEqB")
        stmts.add newLetStmt(cmB, op2)
        bRef = cmB
      stmts.add newCall(bindSym"checkmateRecordEqOutcome",
                        newTree(nnkInfix, n[0], aRef, bRef),
                        aRef, bRef, newLit(origTxt))
      newTree(nnkBlockStmt, newEmptyNode(), stmts)
    else:
      let cmpNode = newTree(nnkInfix, n[0], op1, op2)
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
            if checkmateRecords[checkmateK][0].len == 0:
              checkpoint(checkmateRecords[checkmateK][1])  # raw diff line
            else:
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

var checkmateEnforceEmptyCache = -1

proc checkmateEnforceEmpty*(): bool =
  ## Empty-test enforcement is an explicit opt-in from the checkmate
  ## runner (CHECKMATE_ENFORCE_EMPTY=1). Standalone runs never enforce:
  ## a farm-compiled binary must behave like a stock unittest build.
  if checkmateEnforceEmptyCache < 0:
    checkmateEnforceEmptyCache =
      if checkmateOs.getEnv("CHECKMATE_ENFORCE_EMPTY") == "1": 1 else: 0
  checkmateEnforceEmptyCache == 1

var checkmateCurrentIter* {.threadvar.}: int
  ## 1-based in-process loop iteration, read by the inject formatter so
  ## every event carries an exact iteration tag.

# --- name filtering (--test-name-pattern) ---------------------------------
# Only pulled in when the checkmate runner requests it (-d:checkmateNameRegex),
# so ordinary farm builds never compile the regex engine. The regex itself is
# matched INSIDE the binary (the only place a test can truly be skipped),
# gating the original test template so unmatched tests never execute.
when defined(checkmateNameRegex):
  import regex as checkmateRegex

  var checkmateNameRx: checkmateRegex.Regex2
  var checkmateNameRxState = 0  # 0 = uncompiled, 1 = active, 2 = run-all

  proc checkmateNameMatches*(suiteName, testName: string): bool =
    ## Whether a test runs under CHECKMATE_NAME_REGEX. Compiled once; an
    ## unset/invalid pattern runs everything (the host validates the pattern
    ## up front, so invalid is unreachable in practice, but degrade safe).
    ## Matched against the test name and the "suite test" join, so either a
    ## test-oriented or a suite-oriented pattern selects the test.
    if checkmateNameRxState == 0:
      let pat = checkmateEnvvars.getEnv("CHECKMATE_NAME_REGEX")
      if pat.len == 0:
        checkmateNameRxState = 2
      else:
        try:
          checkmateNameRx = checkmateRegex.re2(pat)
          checkmateNameRxState = 1
        except checkmateRegex.RegexError:
          checkmateNameRxState = 2
    if checkmateNameRxState != 1:
      return true
    if checkmateRegex.contains(testName, checkmateNameRx):
      return true
    suiteName.len > 0 and
      checkmateRegex.contains(suiteName & " " & testName, checkmateNameRx)

template checkmateRunLoop*(name, body) {.dirty.} =
  # the loop wraps the ORIGINAL test template, so suite setup/teardown and
  # testStarted/testEnded events all fire once per iteration
  for checkmateLoopIter in 1 .. checkmateLoopCount():
    checkmateCurrentIter = checkmateLoopIter
    checkmateOrigTest name:
      let checkmateAssertionsBefore {.used.} = checkmateAssertions
      body
      if checkmateAssertions == checkmateAssertionsBefore and
          testStatusIMPL == TestStatus.OK and checkmateEnforceEmpty():
        checkpoint("Test has no assertions (checkmate: add a check, or run with --allow-empty-tests)")
        fail()

template test*(name, body) {.dirty.} =
  when defined(checkmateNameRegex):
    # a non-matching test is skipped whole: no testStarted/testEnded events,
    # exactly like std/unittest's own command-line filter
    if checkmateNameMatches(
        when declared(testSuiteName): testSuiteName else: "", name):
      checkmateRunLoop(name, body)
  else:
    checkmateRunLoop(name, body)
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
  # if the farm PATH is itself a symlink (leftover state, tampering),
  # removeDir would follow it and recursively delete the TARGET's contents,
  # i.e. the real toolchain lib dir: drop the link itself, never recurse
  if symlinkExists(farm):
    removeFile(farm)
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
      if symlinkExists(stampPath):
        removeFile(stampPath)  # writeFile follows links; never write through
      writeFile(stampPath, stamp)
    except OSError as e:
      return (false, false, "", disabled & "cannot build lib overlay: " & e.msg,
              result.timeWarning)
  result.ok = true
