## Generic parallel process pool: single-threaded polling loop, no Nim
## threads. Child output is captured via shell redirection to per-task log
## files, so there is no stream-reading deadlock and no interleaving.

import std/[os, osproc, monotimes, sets, strtabs, times]

type
  PoolTask* = object
    id*: int
    cmd*: string                  # a single command; run via `sh -c "exec cmd > log 2>&1"`
    logPath*: string
    workingDir*: string           # "" = inherit
    serialKey*: string            # tasks sharing a nonempty key never run
                                  # concurrently (e.g. loop iterations of one
                                  # test file, which owns its resources)
    env*: seq[(string, string)]   # extra env merged over the parent env
    timeoutSec*: int              # 0 = no timeout
    watchFile*: string            # progress-based timeout: the deadline
                                  # resets whenever this file grows (per-test
                                  # semantics via the event stream); "" =
                                  # timeout counts from process start

  PoolResult* = object
    id*: int
    exitCode*: int
    durationMs*: float
    timedOut*: bool

  PoolCtl* = enum
    pcContinue, pcBail

  Live = object
    taskIdx: int
    p: Process
    start: MonoTime
    lastProgress: MonoTime  # start, or last growth of watchFile
    lastSize: int64         # watchFile size at lastProgress (-1 = none yet)
    terminated: bool    # SIGTERM sent (timeout)
    killAt: MonoTime    # when to escalate to SIGKILL
    timedOut: bool

const killGrace = initDuration(seconds = 2)

proc shellWrap(t: PoolTask): (string, seq[string]) =
  ## `exec` makes the shell replace itself with the child, so terminate/kill
  ## reach the real process and its exit code passes through unchanged.
  ## POSIX-only; isolate Windows porting here.
  var script = ""
  if t.workingDir.len > 0:
    script.add "cd " & quoteShell(t.workingDir) & " && "
  script.add "exec " & t.cmd & " > " & quoteShell(t.logPath) & " 2>&1"
  ("/bin/sh", @["-c", script])

proc start(t: PoolTask): Live =
  var envTbl: StringTableRef = nil
  if t.env.len > 0:
    envTbl = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      envTbl[k] = v
    for (k, v) in t.env:
      envTbl[k] = v
  let (exe, args) = shellWrap(t)
  let now = getMonoTime()
  Live(p: startProcess(exe, args = args, env = envTbl, options = {poUsePath}),
       start: now, lastProgress: now, lastSize: -1)

proc reap(live: var seq[Live], killAll = false): seq[(int, PoolResult)] =
  ## Poll live processes; collect finished ones. With killAll, terminate
  ## everything and wait for it to die.
  if killAll:
    for l in live.mitems:
      if peekExitCode(l.p) == -1:
        terminate(l.p)
        kill(l.p)
  var i = 0
  while i < live.len:
    let code = peekExitCode(live[i].p)
    let finished = code != -1 or killAll
    if finished:
      let exitCode = if code != -1: code else: waitForExit(live[i].p)
      result.add (live[i].taskIdx, PoolResult(
        exitCode: exitCode,
        durationMs: (getMonoTime() - live[i].start).inNanoseconds.float / 1e6,
        timedOut: live[i].timedOut))
      close(live[i].p)
      live.del(i)
    else:
      inc i

proc checkTimeouts(tasks: seq[PoolTask], live: var seq[Live]) =
  let now = getMonoTime()
  for l in live.mitems:
    let timeout = tasks[l.taskIdx].timeoutSec
    if timeout <= 0: continue
    let watchFile = tasks[l.taskIdx].watchFile
    if watchFile.len > 0:
      let size =
        try: getFileSize(watchFile)
        except CatchableError: -1'i64
      if size != l.lastSize:
        l.lastSize = size
        l.lastProgress = now
    if not l.terminated:
      if now - l.lastProgress > initDuration(seconds = timeout):
        l.timedOut = true
        l.terminated = true
        l.killAt = now + killGrace
        terminate(l.p)
    elif now > l.killAt:
      kill(l.p)

proc runPool*(tasks: seq[PoolTask], jobs: int,
              onDone: proc(t: PoolTask, r: PoolResult): PoolCtl):
             tuple[results: seq[PoolResult], bailed: bool, unstarted: seq[int]] =
  ## Runs tasks with up to `jobs` concurrent processes. onDone fires in
  ## completion order; returning pcBail kills live processes and skips the
  ## rest (their ids are returned in `unstarted`). Tasks with the same
  ## nonempty serialKey are never live simultaneously.
  let jobs = max(1, jobs)
  var pending: seq[int]
  for i in 0 ..< tasks.len:
    pending.add i
  var live: seq[Live]
  var liveKeys = initHashSet[string]()
  while pending.len > 0 or live.len > 0:
    var pi = 0
    while pi < pending.len and live.len < jobs:
      let idx = pending[pi]
      let key = tasks[idx].serialKey
      if key.len > 0 and key in liveKeys:
        inc pi  # an iteration of this file is already running; try later
      else:
        var l = start(tasks[idx])
        l.taskIdx = idx
        live.add l
        if key.len > 0:
          liveKeys.incl key
        pending.delete(pi)
    checkTimeouts(tasks, live)
    for (taskIdx, res) in reap(live):
      var res = res
      res.id = tasks[taskIdx].id
      liveKeys.excl tasks[taskIdx].serialKey
      result.results.add res
      if onDone(tasks[taskIdx], res) == pcBail:
        result.bailed = true
        for (_, r) in reap(live, killAll = true):
          discard  # killed by bail: intentionally unreported
        for idx in pending:
          result.unstarted.add tasks[idx].id
        return
    if live.len > 0:
      sleep(25)
