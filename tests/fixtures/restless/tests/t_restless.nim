## One test failing checks in an endless loop: the event stream keeps
## growing, but no test boundary is ever reached, so the 1 s per-test
## timeout must still kill the file.
import std/[unittest, os]

test "fails forever":
  while true:
    check false
    sleep(50)
