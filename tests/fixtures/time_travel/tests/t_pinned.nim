import std/[unittest, times]
import checkmate  # timeTravelActive

test "wall clock is pinned to the configured start":
  check timeTravelActive()
  let d = now().utc
  check d.year == 2020
  check d.month == mJun
  check d.monthday == 15
