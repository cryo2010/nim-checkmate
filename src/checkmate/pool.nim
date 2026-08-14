## Generic parallel process pool: single-threaded polling loop, no Nim
## threads. Child output is captured via shell redirection to per-task log
## files, so there is no stream-reading deadlock and no interleaving.

import std/[os, osproc, monotimes, strtabs, times]

type
  PoolTask* = object
    id*: int
    cmd*: string                  # a single command; run via `sh -c "exec cmd > log 2>&1"`
    logPath*: string
    workingDir*: string           # "" = inherit
    env*: seq[(string, string)]   # extra env merged over the parent env
    timeoutSec*: int              # 0 = no timeout

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
  Live(p: startProcess(exe, args = args, env = envTbl, options = {poUsePath}),
       start: getMonoTime())

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
    if not l.terminated:
      if now - l.start > initDuration(seconds = timeout):
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
  ## rest (their ids are returned in `unstarted`).
  let jobs = max(1, jobs)
  var next = 0
  var live: seq[Live]
  while next < tasks.len or live.len > 0:
    while next < tasks.len and live.len < jobs:
      var l = start(tasks[next])
      l.taskIdx = next
      live.add l
      inc next
    checkTimeouts(tasks, live)
    for (taskIdx, res) in reap(live):
      var res = res
      res.id = tasks[taskIdx].id
      result.results.add res
      if onDone(tasks[taskIdx], res) == pcBail:
        result.bailed = true
        for (_, r) in reap(live, killAll = true):
          discard  # killed by bail: intentionally unreported
        for i in next ..< tasks.len:
          result.unstarted.add tasks[i].id
        return
    if live.len > 0:
      sleep(25)
