# async timers auto-advance: 65+ virtual seconds must pass in real ms
import std/[unittest, asyncdispatch, monotimes, times]

test "sleepAsync completes instantly":
  let mono0 = getMonoTime()
  waitFor sleepAsync(5000)
  check (getMonoTime() - mono0).inMilliseconds >= 5000

test "racing sleeps resolve in order":
  proc race(): Future[int] {.async.} =
    var winner = 0
    let slow = sleepAsync(2000)
    let fast = sleepAsync(100)
    await fast
    if winner == 0: winner = 1
    await slow
    return winner
  check waitFor(race()) == 1

test "withTimeout on a sleep":
  check waitFor withTimeout(sleepAsync(100), 60_000)
