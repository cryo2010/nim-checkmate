## Orchestration: discover -> compile -> run (x loop iterations) -> aggregate.
## runOnce is the watch-mode seam: pure and re-invokable, no quit() here.

import std/[cpuinfo, monotimes, os, strutils, times]
import ./config, ./discovery, ./events, ./compiler, ./pool, ./report, ./coverage,
       ./shadow

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
  var extraFlags = if cfg.covEnabled: covCompileFlags() else: newSeq[string]()
  var farmOk = false
  var timeOk = false
  if not cfg.allowEmptyTests or cfg.timeTravel:
    let farm = prepareLibFarm(cfg)
    farmOk = farm.ok
    timeOk = farm.timeOk
    if farm.ok:
      extraFlags.add "--lib:" & quoteShell(farm.dir)
    else:
      stderr.writeLine "checkmate: warning: " & farm.warning
    if cfg.timeTravel and farm.ok and not farm.timeOk:
      stderr.writeLine "checkmate: warning: " & farm.timeWarning
  var inProcessLoop = cfg.loopInProcess and cfg.loop > 1
  if inProcessLoop and not farmOk:
    stderr.writeLine "checkmate: warning: loop_in_process needs the unittest " &
      "overlay (unavailable here); falling back to process-level looping"
    inProcessLoop = false
  let timeTravelActive = cfg.timeTravel and farmOk and timeOk
  if cfg.timeTravel and not timeTravelActive and not farmOk:
    stderr.writeLine "checkmate: warning: time travel disabled: the stdlib " &
      "overlay could not be built"
  var timeStartNs = 0'i64
  if timeTravelActive:
    timeStartNs =
      if cfg.timeStart.len > 0:
        parseTimeStartNs(cfg.timeStart)
      else:
        let now = getTime()
        now.toUnix * 1_000_000_000'i64 + now.nanosecond
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
  # stale event files from previous/aborted runs must never leak into this
  # run's aggregation (the formatter appends): start from an empty dir
  removeDir(cfg.cacheDir / "events")
  createDir(cfg.cacheDir / "events")
  if cfg.covEnabled:
    covClean(cfg)
  var runnable: seq[int]
  for i in 0 ..< files.len:
    if fos[i].compiled: runnable.add i
  let filterStr = filterArgs(filters)
  # in-process loop: one process per file, the overlay repeats each test
  # CHECKMATE_LOOP times; otherwise one process per (file, iteration)
  let itersPerFile = if inProcessLoop: 1 else: cfg.loop
  var tasks: seq[PoolTask]
  var meta: seq[tuple[fi, iteration: int]]
  var evPaths: seq[string]
  for iteration in 1 .. itersPerFile:   # file-major interleave: all files at
    for fi in runnable:                 # iteration k before iteration k+1
      let evPath = cfg.cacheDir / "events" / files[fi].slug & "." & $iteration & ".jsonl"
      removeFile(evPath)
      var cmd = quoteShell(ctasks[fi].binPath)
      if filterStr.len > 0: cmd.add " " & filterStr
      var env = @[("CHECKMATE_EVENTS_FILE", evPath)]
      if inProcessLoop:
        env.add ("CHECKMATE_LOOP", $cfg.loop)
      if timeTravelActive:
        env.add ("CHECKMATE_TIME_TRAVEL", "1")
        env.add ("CHECKMATE_TIME_START_NS", $timeStartNs)
      if cfg.allowEmptyTests and farmOk:
        # farm in use (time travel) but enforcement opted out at runtime
        env.add ("CHECKMATE_ALLOW_EMPTY", "1")
      if cfg.bail:
        # first failing test aborts the binary mid-file (abortOnError)
        env.add ("CHECKMATE_BAIL", "1")
      tasks.add PoolTask(
        id: meta.len, cmd: cmd,
        logPath: cfg.cacheDir / "logs" / files[fi].slug & "." & $iteration & ".log",
        workingDir: cfg.projectRoot,
        serialKey: files[fi].slug,  # a file's iterations never overlap: test
                                    # files own their resources exclusively
        env: env,
        # per-test budget: the watchdog deadline resets on every event the
        # test binary emits, so it fires when ONE test stalls for timeoutSec
        timeoutSec: cfg.timeoutSec,
        watchFile: evPath)
      meta.add (fi: fi, iteration: iteration)
      evPaths.add evPath

  var completed = newSeq[int](files.len)
  let loopN = cfg.loop
  let bailOnFail = cfg.bail
  let (_, rbailed, _) = runPool(tasks, jobs,
    proc(t: PoolTask, r: PoolResult): PoolCtl =
      let (fi, iteration) = meta[t.id]
      let outcome = foldEvents(parseEvents(evPaths[t.id]), r.exitCode, r.timedOut,
                               testTimeoutMs = cfg.timeoutSec.float * 1000)
      if inProcessLoop:
        fos[fi].runs = splitInProcessRuns(
          outcome, loopN, r.exitCode, r.timedOut, r.durationMs, t.logPath)
      else:
        fos[fi].runs.add IterRun(
          iteration: iteration, exitCode: r.exitCode, timedOut: r.timedOut,
          durMs: r.durationMs, logPath: t.logPath, outcome: outcome)
      inc completed[fi]
      if completed[fi] == itersPerFile:
        rep.fileLine(fos[fi])
      if bailOnFail and (r.exitCode != 0 or r.timedOut): pcBail
      else: pcContinue)
  bailed = rbailed
  if bailed:
    for fi in runnable:
      if completed[fi] < itersPerFile:
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
