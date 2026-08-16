## quit(0) from user code mid-test: the truncated run must be reported as
## a failure, never as a pass, even though the exit code is 0.
import std/unittest

test "first passes":
  check true

test "quits mid-test":
  check true
  quit(0)

test "never reached":
  check true
