import std/[unittest, os]

test "sleeps for 2 seconds":
  sleep(2000)   # exceeds the 1 s per-test budget; killed by the watchdog
  check true
