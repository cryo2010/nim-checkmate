## Jest-like terminal rendering: streamed per-file result lines, failure
## detail blocks, and the closing summary.

import std/[os, strutils]
import ./config, ./events

type
  Reporter* = object
    colors*: bool
    verbose*: bool
    filtered*: bool     # a -t filter is active: empty files are expected
    rootPrefix*: string # absolute project root + separator, stripped from output

proc newReporter*(cfg: Config, filtered = false): Reporter =
  Reporter(colors: cfg.colorsEnabled, verbose: cfg.verbose, filtered: filtered,
           rootPrefix: cfg.projectRoot & $DirSep)

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
  case fs
  of fsPass: r.style("1;97;42", " PASS ")
  of fsFail, fsCompileFail: r.style("1;97;41", " FAIL ")
  of fsFlaky: r.style("1;30;43", " FLAKY ")
  of fsNotRun: r.style("1;30;47", " SKIP ")
  of fsNoTests: r.style("1;30;43", " WARN ")

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
  echo r.badge(fs), " ", fo.tf.relPath, " ", note
  if r.verbose and fs in {fsPass, fsFail, fsFlaky}:
    for t in aggregateTests(fo):
      let n = t.passes + t.fails + t.skips
      let mark =
        if t.fails > 0 and t.passes > 0: r.yellow("~")
        elif t.fails > 0: r.red("x")
        elif t.skips == n: r.dim("-")
        else: r.green("+")
      var line = "  " & mark & " " & testTitle(t)
      if t.durationsMs.len > 0: line.add " " & r.dim("(" & fmtMs(median(t.durationsMs)) & ")")
      if t.fails > 0 and t.passes > 0:
        line.add " " & r.yellow("[flaky: passed " & $t.passes & "/" & $n & "]")
      echo line

# --- failure details ------------------------------------------------------

proc indented(text: string, prefix: string): string =
  var lines: seq[string]
  for line in text.splitLines:
    lines.add prefix & line
  lines.join("\n")

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
  echo r.badge(fs), " ", r.bold(fo.tf.relPath)
  if fs == fsCompileFail:
    let content = if fileExists(fo.compileLog): readFile(fo.compileLog) else: ""
    echo indented(r.relativize(content.strip(leading = false)), "  ")
    return
  for t in aggregateTests(fo):
    if t.failures.len == 0: continue
    var suffix = ""
    let n = t.passes + t.fails + t.skips
    case t.failures[0].status
    of "CRASHED": suffix = " " & r.red("(crashed)")
    of "TIMEOUT": suffix = " " & r.red("(timed out)")
    else:
      if t.passes > 0: suffix = " " & r.yellow("(flaky: failed " & $t.fails & "/" & $n & ")")
    echo "  ", r.red(testTitle(t)), suffix
    let f = t.failures[0]
    for cp in f.checkpoints:
      echo indented(r.relativize(cp), "    ")
    if f.stack.strip.len > 0:
      echo r.dim(indented(r.relativize(f.stack.strip(leading = false)), "    "))
    if t.failures.len > 1:
      var iters: seq[string]
      for other in t.failures[1 .. ^1]: iters.add $other.iteration
      echo r.dim("    also failed in iteration(s): " & iters.join(", "))
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
