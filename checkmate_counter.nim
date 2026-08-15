import std/unittest
import std/strutils

type CountingFormatter* = ref object of OutputFormatter
  failedAssertions*: int
  testFailures*: int

method failureOccurred*(formatter: CountingFormatter,
    checkpoints: seq[string], stackTrace: string) =
  for checkpoint in checkpoints:
    if "Check failed:" in checkpoint:
      inc formatter.failedAssertions
      echo "[assertion_failed] ", checkpoint
  if checkpoints.len > 0:
    inc formatter.testFailures

method testEnded*(formatter: CountingFormatter, testResult: TestResult) =
  echo "[test_ended] ", testResult.testName, " status=", testResult.status

let counterFormatter = CountingFormatter(failedAssertions: 0, testFailures: 0)
addOutputFormatter(counterFormatter)
echo "[checkmate] Assertion counter initialized"
