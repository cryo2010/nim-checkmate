import std/[unittest, times, monotimes]
import checkmate  # advanceTime / travelTo

suite "explicit time control":
  test "advanceTime moves both clocks":
    let mono0 = getMonoTime()
    let wall0 = getTime()
    advanceTime(1500)
    advanceTime(initDuration(minutes = 5))
    check (getMonoTime() - mono0).inMilliseconds == 301_500
    check (getTime() - wall0).inMilliseconds == 301_500

  test "travelTo jumps the wall clock backward, monotonic never regresses":
    let mono0 = getMonoTime()
    travelTo(dateTime(1999, mDec, 31, zone = utc()))
    check now().utc.year == 1999
    check getMonoTime() >= mono0
    travelTo(dateTime(2020, mJun, 15, zone = utc()))
    check now().utc.year == 2020
