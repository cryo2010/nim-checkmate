# Total runtime (4.5 s) exceeds the fixture's 2 s timeout, but no SINGLE
# test does: the per-test progress watchdog must let this file pass.
import std/[unittest, os]

test "slow but steady 1":
  sleep(1500)
  check true

test "slow but steady 2":
  sleep(1500)
  check true

test "slow but steady 3":
  sleep(1500)
  check true
