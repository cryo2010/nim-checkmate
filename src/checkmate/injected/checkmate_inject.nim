# Injected into test binaries via `nim c --import:checkmate_inject`.
#
# Because --import'ed modules run their top-level code BEFORE the main
# module's, this registers an OutputFormatter before std/unittest's
# ensureInitialized() runs; unittest then never installs its default
# ConsoleOutputFormatter (it only does so when no formatter is registered),
# so console output is suppressed without any env tricks.
#
# If CHECKMATE_EVENTS_FILE is unset, nothing is registered and the binary
# behaves exactly like a stock std/unittest build.
#
# This file must stay self-contained (std imports only): it is embedded in
# the checkmate binary via staticRead and materialized at runtime. The JSONL
# protocol here is mirrored by checkmate/events.nim.

import std/[unittest, os, json, monotimes, times]

type CheckmateFormatter = ref object of OutputFormatter
  f: File
  testStart: MonoTime

# durations must stay REAL under time travel (the per-test timeout rewrite
# depends on them); the overlay exports the renamed real clock
when declared(checkmateOrigGetMonoTime):
  template checkmateRealMono(): MonoTime = checkmateOrigGetMonoTime()
else:
  template checkmateRealMono(): MonoTime = getMonoTime()

# the overlay tags every in-process loop iteration; carrying the tag in
# events lets aggregation slot runs exactly instead of guessing iterations
# from occurrence order (which duplicate test names would break)
when declared(checkmateCurrentIter):
  template checkmateIter(): int = checkmateCurrentIter
else:
  template checkmateIter(): int = 0

proc emit(cf: CheckmateFormatter, node: JsonNode) =
  cf.f.writeLine($node)
  cf.f.flushFile()

method suiteStarted(cf: CheckmateFormatter, suiteName: string) =
  cf.emit(%*{"e": "suiteStarted", "suite": suiteName})

method testStarted(cf: CheckmateFormatter, testName: string) =
  cf.testStart = checkmateRealMono()
  cf.emit(%*{"e": "testStarted", "test": testName, "iter": checkmateIter()})

method failureOccurred(cf: CheckmateFormatter, checkpoints: seq[string],
                       stackTrace: string) =
  cf.emit(%*{"e": "failure", "checkpoints": checkpoints, "stack": stackTrace})

method testEnded(cf: CheckmateFormatter, testResult: TestResult) =
  let durMs = (checkmateRealMono() - cf.testStart).inNanoseconds.float / 1e6
  cf.emit(%*{"e": "testEnded", "suite": testResult.suiteName,
             "test": testResult.testName, "status": $testResult.status,
             "durMs": durMs, "iter": checkmateIter()})

method suiteEnded(cf: CheckmateFormatter) =
  cf.emit(%*{"e": "suiteEnded"})

let checkmateEventsFile = getEnv("CHECKMATE_EVENTS_FILE")
if checkmateEventsFile.len > 0:
  # bail mode: abort the binary at the first failing test so remaining tests
  # and loop iterations never run (fail() emits failureOccurred, then quits).
  # Gated on the events file: a stray CHECKMATE_BAIL in the environment must
  # not change the behavior of a standalone (stock) run
  if getEnv("CHECKMATE_BAIL") == "1":
    abortOnError = true
  try:
    let cf = CheckmateFormatter(f: open(checkmateEventsFile, fmAppend))
    cf.emit(%*{"e": "init", "pid": getCurrentProcessId()})
    addOutputFormatter(cf)
  except IOError, OSError:
    discard  # never break the test binary
