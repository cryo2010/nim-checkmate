# 10 virtual seconds of sleeping; the file must finish in real milliseconds
import std/[unittest, os, times, monotimes]

test "sleep advances all clocks consistently":
  let mono0 = getMonoTime()
  let wall0 = getTime()
  let epoch0 = epochTime()
  sleep(10_000)
  check (getMonoTime() - mono0).inMilliseconds == 10_000
  check (getTime() - wall0).inMilliseconds == 10_000
  check epochTime() - epoch0 == 10.0
