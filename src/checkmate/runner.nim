## Orchestration: discover -> compile -> run (x loop iterations) -> aggregate.
## runOnce is the watch-mode seam: pure and re-invokable, no quit() here.

import std/[cpuinfo, monotimes, os, strutils, times]
import ./config, ./discovery, ./events, ./compiler, ./pool, ./report, ./coverage

proc resolveJobs(cfg: Config): int =
  if cfg.jobs > 0: cfg.jobs else: max(1, countProcessors())

proc filterArgs*(filters: seq[string]): string =
  ## std/unittest globs support only exact, prefix*, *suffix, and
  ## prefix*suffix matching, so a contains-style *PAT* is inexpressible.
  ## A bare -t PAT expands to the OR'd pair "PAT*" + "*PAT" (starts-with or
  ## ends-with); values containing '*' or '::' pass through verbatim.
  var parts: seq[string]
  for f in filters:
    if '*' in f or "::" in f:
      parts.add quoteShell(f)
    else:
      parts.add quoteShell(f & "*")
      parts.add quoteShell("*" & f)
  parts.join(" ")

proc elapsedMs(t0: MonoTime): float =
  (getMonoTime() - t0).inNanoseconds.float / 1e6

proc runOnce*(cfg: Config, cliPaths, filters: seq[string], rep: Reporter): SuiteSummary =
  let t0 = getMonoTime()
  let files = discoverTests(cfg, cliPaths)
  var fos = newSeq[FileOutcome](files.len)
  for i, tf in files:
    fos[i] = FileOutcome(tf: tf)
  if files.len == 0:
    result = SuiteSummary(files: fos, wallMs: elapsedMs(t0))
    return
  prepareCacheDirs(cfg)
  discard materializeInject(cfg.cacheDir)
  let jobs = resolveJobs(cfg)
  var bailed = false

  # --- compile phase ---
  var ctasks: seq[CompileTask]
  var ptasks: seq[PoolTask]
  let extraFlags = if cfg.covEnabled: covCompileFlags() else: @[]
  for i, tf in files:
    let ct = buildCompileTask(cfg, tf, extraFlags)
    ctasks.add ct
    fos[i].compileLog = ct.logPath
    ptasks.add PoolTask(id: i, cmd: ct.cmd, logPath: ct.logPath,
                        workingDir: cfg.projectRoot)
  let bailOnCompile = cfg.bail
  let (cres, cbailed, cunstarted) = runPool(ptasks, jobs,
    proc(t: PoolTask, r: PoolResult): PoolCtl =
      if r.exitCode != 0 and bailOnCompile: pcBail else: pcContinue)
  for r in cres:
    fos[r.id].compiled = r.exitCode == 0
  for id in cunstarted:
    fos[id].notRun = true
  for i in 0 ..< files.len:
    if not fos[i].compiled:
      rep.fileLine(fos[i])
  if cbailed:
    # bail on compile failure: nothing runs
    for i in 0 ..< files.len:
      if fos[i].compiled:
        fos[i].notRun = true
        rep.fileLine(fos[i])
    result = SuiteSummary(files: fos, bailed: true, wallMs: elapsedMs(t0))
    return

  # --- run phase ---
  if cfg.covEnabled:
    covClean(cfg)
  var runnable: seq[int]
  for i in 0 ..< files.len:
    if fos[i].compiled: runnable.add i
  let filterStr = filterArgs(filters)
  var tasks: seq[PoolTask]
  var meta: seq[tuple[fi, iteration: int]]
  var evPaths: seq[string]
  for iteration in 1 .. cfg.loop:       # file-major interleave: all files at
    for fi in runnable:                 # iteration k before iteration k+1
      let evPath = cfg.cacheDir / "events" / files[fi].slug & "." & $iteration & ".jsonl"
      removeFile(evPath)
      var cmd = quoteShell(ctasks[fi].binPath)
      if filterStr.len > 0: cmd.add " " & filterStr
      tasks.add PoolTask(
        id: meta.len, cmd: cmd,
        logPath: cfg.cacheDir / "logs" / files[fi].slug & "." & $iteration & ".log",
        workingDir: cfg.projectRoot,
        serialKey: files[fi].slug,  # a file's iterations never overlap: test
                                    # files own their resources exclusively
        env: @[("CHECKMATE_EVENTS_FILE", evPath)],
        timeoutSec: cfg.timeoutSec)
      meta.add (fi: fi, iteration: iteration)
      evPaths.add evPath

  var completed = newSeq[int](files.len)
  let loopN = cfg.loop
  let bailOnFail = cfg.bail
  let (_, rbailed, _) = runPool(tasks, jobs,
    proc(t: PoolTask, r: PoolResult): PoolCtl =
      let (fi, iteration) = meta[t.id]
      let outcome = foldEvents(parseEvents(evPaths[t.id]), r.exitCode, r.timedOut)
      fos[fi].runs.add IterRun(
        iteration: iteration, exitCode: r.exitCode, timedOut: r.timedOut,
        durMs: r.durationMs, logPath: t.logPath, outcome: outcome)
      inc completed[fi]
      if completed[fi] == loopN:
        rep.fileLine(fos[fi])
      if bailOnFail and (r.exitCode != 0 or r.timedOut): pcBail
      else: pcContinue)
  bailed = rbailed
  if bailed:
    for fi in runnable:
      if completed[fi] < loopN:
        if fos[fi].runs.len == 0:
          fos[fi].notRun = true
        rep.fileLine(fos[fi])

  result = SuiteSummary(files: fos, bailed: bailed, wallMs: elapsedMs(t0))

proc exitCodeFor*(s: SuiteSummary, passWithNoTests = false): int =
  if s.files.len == 0:
    return (if passWithNoTests: 0 else: 1)  # no test files found
  if s.bailed:
    return 1
  for fo in s.files:
    if fileStatus(fo) in {fsFail, fsCompileFail, fsFlaky}:
      return 1
  if totalTestsRun(s) == 0 and not passWithNoTests:
    return 1  # files ran but zero tests executed (e.g. -t matched nothing)
  0
