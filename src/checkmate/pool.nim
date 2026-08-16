## Generic parallel process pool: single-threaded polling loop, no Nim
## threads. Child output is captured via shell redirection to per-task log
## files, so there is no stream-reading deadlock and no interleaving.

import std/[os, osproc, monotimes, posix, sets, strtabs, strutils, tables, times]

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
    lastProgress: MonoTime  # start, or last test boundary seen in watchFile
    lastSize: int64         # watchFile size last observed (-1 = none yet)
    terminated: bool    # SIGTERM sent (timeout)
    killAt: MonoTime    # when to escalate to SIGKILL
    timedOut: bool
    descendants: seq[int]   # grandchild pids captured at kill time

const killGrace = initDuration(seconds = 2)

proc descendantPids(root: int): seq[int] =
  ## Transitive children of root via ps (POSIX-portable). Orphans reparent
  ## to init the moment the direct child dies, so this must be captured
  ## while it is still alive. Kills are rare; the subprocess cost is fine.
  var output: string
  try:
    let (o, code) = execCmdEx("ps -axo pid=,ppid=")
    if code != 0: return
    output = o
  except CatchableError:
    return
  var children = initTable[int, seq[int]]()
  for line in output.splitLines:
    let parts = line.splitWhitespace
    if parts.len != 2: continue
    try:
      children.mgetOrPut(parseInt(parts[1]), @[]).add parseInt(parts[0])
    except ValueError:
      continue
  var queue = @[root]
  while queue.len > 0:
    for child in children.getOrDefault(queue.pop()):
      result.add child
      queue.add child

proc signalPids(pids: seq[int], sig: cint) =
  for pid in pids:
    discard posix.kill(Pid(pid), sig)

proc boundaryProgress(path: string, fromByte: int64): bool =
  ## True when the bytes appended since fromByte contain a test BOUNDARY
  ## event. Mid-test events (failure checkpoints from a check inside a
  ## loop) deliberately do not count: a single stuck test must trip the
  ## per-test timeout even if it emits failures forever.
  try:
    let f = open(path)
    defer: close(f)
    f.setFilePos(fromByte)
    let chunk = f.readAll()
    # JSON string escaping makes these markers unforgeable from user
    # checkpoint text (embedded quotes arrive backslash-escaped)
    chunk.contains("\"e\":\"testStarted\"") or
      chunk.contains("\"e\":\"testEnded\"")
  except IOError, OSError:
    true  # unreadable: err on the side of not killing

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
        # capture the process tree first: grandchildren (helper servers,
        # spawned tools) must die with the test, or they hold its
        # resources (ports, files) into the next iteration
        if l.descendants.len == 0:
          l.descendants = descendantPids(processID(l.p))
        signalPids(l.descendants, SIGTERM)
        terminate(l.p)
        signalPids(l.descendants, SIGKILL)
        kill(l.p)
  var i = 0
  while i < live.len:
    let code = peekExitCode(live[i].p)
    let finished = code != -1 or killAll
    if finished:
      let exitCode = if code != -1: code else: waitForExit(live[i].p)
      if live[i].descendants.len > 0:
        # the direct child is gone; make sure its helpers are too before
        # the serialKey frees and the file's next iteration starts
        signalPids(live[i].descendants, SIGKILL)
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
        # only a test boundary in the appended bytes counts as progress;
        # any-growth would let one stuck test reset the deadline forever
        # by emitting failure events
        let grown = l.lastSize >= 0 and size > l.lastSize
        if not grown or boundaryProgress(watchFile, l.lastSize):
          l.lastProgress = now
        l.lastSize = size
    if not l.terminated:
      if now - l.lastProgress > initDuration(seconds = timeout):
        l.timedOut = true
        l.terminated = true
        l.killAt = now + killGrace
        l.descendants = descendantPids(processID(l.p))
        signalPids(l.descendants, SIGTERM)
        terminate(l.p)
    elif now > l.killAt:
      for pid in descendantPids(processID(l.p)):
        if pid notin l.descendants:
          l.descendants.add pid
      signalPids(l.descendants, SIGKILL)
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
    var bailing = false
    for (taskIdx, res) in reap(live):
      var res = res
      res.id = tasks[taskIdx].id
      liveKeys.excl tasks[taskIdx].serialKey
      result.results.add res
      # every finished task in this batch is reported, even after a bail
      # decision: batch-mates completed BEFORE the bail and their results
      # are real (dropping them would misreport finished work)
      if onDone(tasks[taskIdx], res) == pcBail:
        bailing = true
    if bailing:
      result.bailed = true
      for (taskIdx, _) in reap(live, killAll = true):
        # killed mid-flight by the bail: no result to report, but the task
        # did not run to completion either; callers treat these like
        # never-started tasks
        result.unstarted.add tasks[taskIdx].id
      for idx in pending:
        result.unstarted.add tasks[idx].id
      return
    if live.len > 0:
      sleep(25)
