# The importable `checkmate` module compiles everywhere and degrades loudly
# without an active virtual clock. This runs green under BOTH `checkmate`
# (overlay present, but --time-travel not enabled here) and a plain
# `nimble test` (no overlay at all) -- in both, time travel is inactive.
import std/[unittest, times]
import checkmate

suite "checkmate public API (inactive time travel)":
  test "timeTravelActive is false without --time-travel":
    check not timeTravelActive()

  test "advanceTime(int) raises CheckmateError when inactive":
    expect CheckmateError:
      advanceTime(1)

  test "advanceTime(Duration) raises CheckmateError when inactive":
    expect CheckmateError:
      advanceTime(initDuration(seconds = 1))

  test "travelTo raises CheckmateError when inactive":
    expect CheckmateError:
      travelTo(dateTime(2020, mJan, 1, zone = utc()))
