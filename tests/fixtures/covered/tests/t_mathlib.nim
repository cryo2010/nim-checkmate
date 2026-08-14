import std/unittest
import mathlib

suite "mathlib":
  test "double":
    check double(21) == 42
  test "sign of positive":
    check sign(5) == 1
  # sign's negative/zero branches and neverCalled stay uncovered
