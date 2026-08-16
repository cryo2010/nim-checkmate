import std/unittest

suite "math ops":
  test "multiplication works":
    check 6 * 7 == 42

  test "subtraction works":
    check 9 - 4 == 5

  test "addition works":
    let (a, b) = (2, 2)
    check a + b == 5
