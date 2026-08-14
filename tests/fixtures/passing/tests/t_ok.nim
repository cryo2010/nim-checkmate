import std/unittest

suite "math ops":
  test "addition works":
    check 1 + 1 == 2
  test "subtraction works":
    check 3 - 1 == 2

test "bare test passes":
  check true
