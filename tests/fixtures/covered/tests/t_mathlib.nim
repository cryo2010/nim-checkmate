import std/unittest
import mathlib
import stringlib

suite "mathlib":
  test "double":
    check double(21) == 42
  test "sign of positive":
    check sign(5) == 1
  # sign's negative/zero branches and neverCalled stay uncovered
  test "shout is fully covered":
    # stringlib has no uncovered lines, so it sorts ABOVE mathlib
    check shout("hi") == "hi!"
