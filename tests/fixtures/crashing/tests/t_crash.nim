import std/unittest

test "fine before the crash":
  check true

suite "danger zone":
  test "dies mid test":
    var p: ptr int = nil
    p[] = 42          # SIGSEGV: no testEnded event is ever written
    check true

test "never reached":
  check true
