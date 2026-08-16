## Jest-like terminal rendering: streamed per-file result lines, failure
## detail blocks, and the closing summary.

import std/[os, strutils, tables]
import ./config, ./events

type
  Reporter* = object
    colors*: bool
    verbose*: bool
    filtered*: bool     # a -t filter is active: empty files are expected
    rootPrefix*: string # absolute project root + separator, stripped from output
    maxPath*: int       # [format] display caps; 0 = unlimited
    maxSuite*: int
    maxTest*: int
    context*: int       # source lines around failing lines; 0 = just the line

proc newReporter*(cfg: Config, filtered = false): Reporter =
  Reporter(colors: cfg.colorsEnabled, verbose: cfg.verbose, filtered: filtered,
           rootPrefix: cfg.projectRoot & $DirSep,
           maxPath: cfg.fmtMaxPath, maxSuite: cfg.fmtMaxSuite,
           maxTest: cfg.fmtMaxTest, context: cfg.fmtContext)

proc relativize(r: Reporter, s: string): string =
  ## Nim embeds absolute source paths in check messages, stack traces, and
  ## compile errors regardless of how the file was passed to the compiler;
  ## strip the project root so output is project-relative, jest-style.
  if r.rootPrefix.len > 1: s.replace(r.rootPrefix, "") else: s

# --- styling --------------------------------------------------------------

proc style(r: Reporter, code, s: string): string =
  if r.colors: "\e[" & code & "m" & s & "\e[0m" else: s

proc red(r: Reporter, s: string): string = r.style("31", s)
proc green(r: Reporter, s: string): string = r.style("32", s)
proc yellow(r: Reporter, s: string): string = r.style("33", s)
proc dim(r: Reporter, s: string): string = r.style("2", s)
proc bold(r: Reporter, s: string): string = r.style("1", s)

proc badge(r: Reporter, fs: FileStatus): string =
  # every label is padded to the width of the widest ("FLAKY") so the
  # badges are uniform and the filename column stays aligned when a FLAKY
  # (or WARN/SKIP) row sits among PASS/FAIL rows
  proc b(code, label: string): string =
    r.style(code, " " & alignLeft(label, 5) & " ")
  case fs
  of fsPass: b("1;97;42", "PASS")
  of fsFail, fsCompileFail: b("1;97;41", "FAIL")
  of fsFlaky: b("1;30;43", "FLAKY")
  of fsNotRun: b("1;30;47", "SKIP")
  of fsNoTests: b("1;30;43", "WARN")

proc fmtSecs(ms: float): string =
  formatFloat(ms / 1000.0, ffDecimal, 2) & " s"

proc fmtMs(ms: float): string =
  if ms >= 1000: fmtSecs(ms)
  else: formatFloat(ms, ffDecimal, 1) & " ms"

proc median(xs: seq[float]): float =
  if xs.len == 0: return 0
  var s = xs
  for i in 1 ..< s.len:  # insertion sort; tiny inputs
    var j = i
    while j > 0 and s[j - 1] > s[j]:
      swap(s[j - 1], s[j]); dec j
  s[s.len div 2]

proc testTitle(t: TestOutcome): string =
  if t.suite.len > 0: t.suite & " > " & t.name else: t.name

proc shortenPath(path: string, cap: int): string =
  ## Long paths keep their tail (the significant part), preceded by "...",
  ## cut at a component boundary when one falls inside the kept range.
  if cap <= 0 or path.len <= cap:
    return path
  var tail = path[path.len - max(cap - 3, 1) .. ^1]
  let slash = tail.find('/')
  if slash >= 0 and slash < tail.len - 1:
    tail = tail[slash + 1 .. ^1]
  "..." & tail

proc shortenName(name: string, cap: int): string =
  ## Long suite/test names keep their head, followed by "...".
  if cap <= 0 or name.len <= cap:
    return name
  name[0 ..< max(cap - 3, 1)] & "..."

# --- per-file result line (streamed in completion order) ------------------

proc fileLine*(r: Reporter, fo: FileOutcome) =
  let fs = fileStatus(fo)
  var note = ""
  case fs
  of fsCompileFail: note = r.dim("(compile failed)")
  of fsNotRun: note = r.dim("(not run)")
  of fsNoTests:
    note = r.dim(if r.filtered: "(no matching tests)" else: "(no tests found)")
  of fsFlaky: note = r.yellow("(passed " & $fo.passedIters & "/" & $fo.runs.len & ")")
  of fsPass, fsFail:
    var durs: seq[float]
    for run in fo.runs: durs.add run.durMs
    note = r.dim("(" & fmtSecs(median(durs)) & ")")
  echo r.badge(fs), " ", shortenPath(fo.tf.relPath, r.maxPath), " ", note
  if r.verbose and fs in {fsPass, fsFail, fsFlaky}:
    var currentSuite = "\0"  # sentinel: no suite announced yet
    for t in aggregateTests(fo):
      if t.suite != currentSuite:
        currentSuite = t.suite
        if t.suite.len > 0:
          echo "  ", r.bold(shortenName(t.suite, r.maxSuite))
      let base = if t.suite.len > 0: "    " else: "  "
      let n = t.passes + t.fails + t.skips
      let mark =
        if t.fails > 0 and t.passes > 0: r.yellow("~")
        elif t.fails > 0: r.red("✗")
        elif t.skips == n: r.yellow("○")
        else: r.green("✓")
      var line = base & mark & " " & r.dim(shortenName(t.name, r.maxTest))
      if t.durationsMs.len > 0:
        line.add " " & r.dim("(" & fmtMs(median(t.durationsMs)) & ")")
      if t.fails > 0 and t.passes > 0:
        line.add " " & r.yellow("[flaky: passed " & $t.passes & "/" & $n & "]")
      echo line

# --- failure details ------------------------------------------------------

proc indented(text: string, prefix: string): string =
  var lines: seq[string]
  for line in text.splitLines:
    lines.add prefix & line
  lines.join("\n")

type HeaderParts = object
  isHeader: bool
  path: string   # "" when the checkpoint points at the reported file
  num: string
  rest: string

proc headerRewrite(cp, relPath: string): HeaderParts =
  ## Splits "path(line, col): [Check failed: ]expr" into parts; path is
  ## kept only when the check failed in another module (helper procs), so
  ## the line number is never attributed to the wrong file.
  let open = cp.find('(')
  if open <= 0:
    return
  let path = cp[0 ..< open]
  # a path containing spaces is almost certainly a VALUE checkpoint whose
  # text embeds lineinfo (e.g. `err was tests/x.nim(3, 5): ...`), not a
  # real header; misclassifying it would swallow the value line entirely.
  # Genuinely-spaced project paths degrade to plain checkpoint text.
  if not path.endsWith(".nim") or ' ' in path:
    return
  var idx = open + 1
  var lineNum = ""
  while idx < cp.len and cp[idx] in {'0' .. '9'}:
    lineNum.add cp[idx]
    inc idx
  if lineNum.len == 0 or idx >= cp.len or cp[idx] != ',':
    return
  inc idx
  while idx < cp.len and cp[idx] in {' ', '0' .. '9'}:
    inc idx
  if idx + 1 >= cp.len or cp[idx] != ')' or cp[idx + 1] != ':':
    return
  idx += 2
  while idx < cp.len and cp[idx] == ' ':
    inc idx
  var rest = cp[idx .. ^1]
  const checkPrefix = "Check failed: "
  if rest.startsWith(checkPrefix):
    rest = rest[checkPrefix.len .. ^1]
  result.isHeader = true
  result.num = lineNum
  result.rest = rest
  if path != relPath:
    result.path = path

proc sourceLine(r: Reporter, cache: var Table[string, seq[string]],
                relPath, num: string): string =
  ## The verbatim source line (original indentation, full statement) for a
  ## gutter header; "" when the file or line is unavailable.
  if relPath notin cache:
    let p = r.rootPrefix & relPath
    cache[relPath] =
      if fileExists(p):
        try: readFile(p).splitLines
        except IOError: @[]
      else:
        @[]
  var idx = -1
  try:
    idx = parseInt(num) - 1
  except ValueError:
    discard
  if idx >= 0 and idx < cache[relPath].len:
    result = cache[relPath][idx]

proc gutterWidth(numStr: string, context: int): int =
  ## Width needed for the largest line number a frame may reach.
  try:
    len($(parseInt(numStr) + context))
  except ValueError:
    numStr.len

proc codeFrame(r: Reporter, cache: var Table[string, seq[string]],
               relPath, numStr: string, numW: int, cpIndent: string): bool =
  ## Source frame around the failing line: context lines fully muted, the
  ## failing line marked with ">". false when the source is unavailable so
  ## the caller can fall back to checkpoint text.
  var lineNo = -1
  try:
    lineNo = parseInt(numStr)
  except ValueError:
    return false
  discard r.sourceLine(cache, relPath, numStr)  # ensures the file is cached
  let lines = cache.getOrDefault(relPath)
  if lineNo < 1 or lineNo > lines.len:
    return false
  if r.context <= 0:
    echo cpIndent, r.dim(align(numStr, numW) & " |"), " ", lines[lineNo - 1]
    return true
  for n in max(1, lineNo - r.context) .. min(lines.len, lineNo + r.context):
    let code = lines[n - 1]
    if n == lineNo:
      echo cpIndent, r.red(">"), " ", r.dim(align($n, numW) & " |"), " ", code
    else:
      var s = align($n, numW) & " |"
      if code.len > 0:
        s.add " " & code
      echo cpIndent, "  ", r.dim(s)
  true

proc stackLineNum(stack, relPath: string): string =
  ## Line number of the most recent frame in relPath ("path(N) proc"),
  ## used to give exception failures a line-number header like checks have.
  for ln in stack.splitLines:
    let l = ln.strip
    if l.startsWith(relPath & "("):
      var i = relPath.len + 1
      var num = ""
      while i < l.len and l[i] in {'0' .. '9'}:
        num.add l[i]
        inc i
      if num.len > 0 and i < l.len and l[i] == ')':
        result = num   # keep scanning: tracebacks list most recent last

proc capturedOutputBlock(r: Reporter, fo: FileOutcome) =
  for run in fo.runs:
    if run.iterFailed:
      let content = if fileExists(run.logPath): readFile(run.logPath) else: ""
      if content.strip.len > 0:
        echo r.dim("  --- captured output (iteration " & $run.iteration & ") ---")
        echo indented(r.relativize(content.strip(leading = false)), "  ")
      return  # first failing iteration only

proc failureBlock*(r: Reporter, fo: FileOutcome) =
  let fs = fileStatus(fo)
  if fs notin {fsFail, fsFlaky, fsCompileFail}: return
  echo ""
  echo r.badge(fs), " ", r.bold(shortenPath(fo.tf.relPath, r.maxPath))
  if fs == fsCompileFail:
    let content = if fileExists(fo.compileLog): readFile(fo.compileLog) else: ""
    echo indented(r.relativize(content.strip(leading = false)), "  ")
    return
  var srcCache = initTable[string, seq[string]]()
  # gutter width: right-align line numbers across this file's whole block
  var numW = 0
  for t in aggregateTests(fo):
    if t.failures.len == 0: continue
    let f = t.failures[0]
    for i, cp in f.checkpoints:
      let h = headerRewrite(r.relativize(cp), fo.tf.relPath)
      if h.isHeader:
        numW = max(numW, gutterWidth(h.num, r.context))
      elif i == 0:
        let ln = stackLineNum(r.relativize(f.stack), fo.tf.relPath)
        if ln.len > 0:
          numW = max(numW, gutterWidth(ln, r.context))
  var currentSuite = "\0"  # sentinel: no suite announced yet
  for t in aggregateTests(fo):
    if t.failures.len == 0: continue
    if t.suite != currentSuite:
      currentSuite = t.suite
      if t.suite.len > 0:
        echo "  ", r.red("●"), " ", r.bold(shortenName(t.suite, r.maxSuite))
    # tests inside a suite nest under its heading; standalone tests keep
    # the flat layout
    let base = if t.suite.len > 0: "    " else: "  "
    let cpIndent = base & "  "
    var suffix = ""
    let n = t.passes + t.fails + t.skips
    case t.failures[0].status
    of "CRASHED": suffix = " " & r.red("(crashed)")
    of "TIMEOUT": suffix = " " & r.red("(timed out)")
    else:
      if t.passes > 0: suffix = " " & r.yellow("(flaky: failed " & $t.fails & "/" & $n & ")")
    let nameMark = if t.passes > 0: r.yellow("~") else: r.red("✗")
    echo base, nameMark, " ", r.red(shortenName(t.name, r.maxTest)), suffix
    let f = t.failures[0]
    var cps = f.checkpoints
    if cps.len > 0:
      # exception failures have no lineinfo'd checkpoint; derive a header
      # from the stack so every failure gets a line-number anchor
      if not headerRewrite(r.relativize(cps[0]), fo.tf.relPath).isHeader:
        let lineNum = stackLineNum(r.relativize(f.stack), fo.tf.relPath)
        if lineNum.len > 0:
          # show the raise-site code; the exception message nests below
          if not r.codeFrame(srcCache, fo.tf.relPath, lineNum, numW, cpIndent):
            echo cpIndent, r.dim(align(lineNum, numW) & " |"), " ",
                 r.relativize(cps[0])
            cps = cps[1 .. ^1]
    for cp in cps:
      let rcp = r.relativize(cp)
      let h = headerRewrite(rcp, fo.tf.relPath)
      if h.isHeader and h.path.len == 0:
        if not r.codeFrame(srcCache, fo.tf.relPath, h.num, numW, cpIndent):
          echo cpIndent, r.dim(align(h.num, numW) & " |"), " ", h.rest
      elif h.isHeader:
        if r.context > 0 and r.sourceLine(srcCache, h.path, h.num).len > 0:
          echo cpIndent, r.dim(shortenPath(h.path, r.maxPath) & ":")
          discard r.codeFrame(srcCache, h.path, h.num, numW, cpIndent)
        else:
          let src = r.sourceLine(srcCache, h.path, h.num)
          echo cpIndent, r.dim(shortenPath(h.path, r.maxPath) & ":" & h.num & " |"),
               " ", (if src.len > 0: src else: h.rest)
      else:
        echo indented(rcp, cpIndent & "  ")  # values nest under their header
    if f.stack.strip.len > 0:
      echo r.dim(indented(r.relativize(f.stack.strip(leading = false)),
                          cpIndent & "  "))
    if t.failures.len > 1:
      if t.fails == n:
        # every iteration failed: individual numbers carry no information
        echo r.dim(cpIndent & "  failed in all " & $n & " iterations")
      else:
        const maxListed = 10
        var iters: seq[string]
        for other in t.failures[1 .. min(maxListed, t.failures.len - 1)]:
          iters.add $other.iteration
        # total failing iterations is exact even though details are capped
        let unlisted = t.fails - 1 - iters.len
        var line = cpIndent & "  also failed in iteration(s): " & iters.join(", ")
        if unlisted > 0:
          line.add " and " & $unlisted & " more"
        echo r.dim(line)
  # suite-level crash with no attributable test
  var anyTestFailure = false
  for t in aggregateTests(fo):
    if t.failures.len > 0: anyTestFailure = true
  if not anyTestFailure:
    for run in fo.runs:
      if run.iterFailed:
        let what =
          if run.timedOut: "timed out after " & $((run.durMs / 1000).int) & " s"
          elif run.outcome.crashed: "crashed before reporting results (exit " & $run.exitCode & ")"
          else: "exited with code " & $run.exitCode
        echo "  ", r.red(what), r.dim(" (iteration " & $run.iteration & ")")
        break
  r.capturedOutputBlock(fo)

# --- summary --------------------------------------------------------------

proc ratioLine(r: Reporter; label: string; passed, total: int;
               failed, flaky, skipped: int): string =
  ## Hybrid summary: "96/100 passed" spine, non-pass buckets named only
  ## when nonzero, so a clean run stays compact and "failed" is greppable.
  var ratio = $passed & "/" & $total & " passed"
  ratio =
    if failed > 0: r.red(ratio)
    elif flaky > 0: r.yellow(ratio)
    else: r.green(ratio)
  var buckets: seq[string]
  if failed > 0: buckets.add r.red($failed & " failed")
  if flaky > 0: buckets.add r.yellow($flaky & " flaky")
  if skipped > 0: buckets.add r.dim($skipped & " skipped")
  result = r.bold(label) & ratio
  if buckets.len > 0:
    result.add " (" & buckets.join(", ") & ")"

proc summary*(r: Reporter, s: SuiteSummary) =
  var sFailed, sFlaky, sPassed, sSkipped = 0
  var tFailed, tFlaky, tPassed, tSkipped = 0
  for fo in s.files:
    case fileStatus(fo)
    of fsFail, fsCompileFail: inc sFailed
    of fsFlaky: inc sFlaky
    of fsPass: inc sPassed
    of fsNotRun, fsNoTests: inc sSkipped
    for t in aggregateTests(fo):
      if t.fails > 0 and t.passes > 0: inc tFlaky
      elif t.fails > 0: inc tFailed
      elif t.passes > 0: inc tPassed
      else: inc tSkipped
  echo ""
  if s.bailed:
    echo r.yellow("Bailed on first failure; remaining suites were not run.")
  echo r.ratioLine("suites: ", sPassed, s.files.len, sFailed, sFlaky, sSkipped)
  echo r.ratioLine("tests:  ", tPassed, tFailed + tFlaky + tPassed + tSkipped,
                   tFailed, tFlaky, tSkipped)
  echo r.bold("time:   "), fmtSecs(s.wallMs)

proc finish*(r: Reporter, s: SuiteSummary) =
  ## Failure blocks (discovery order) + summary.
  for fo in s.files:
    r.failureBlock(fo)
  r.summary(s)
