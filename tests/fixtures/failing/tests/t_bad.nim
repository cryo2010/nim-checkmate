import std/unittest

suite "broken":
  test "wrong sum":
    let a = 2
    let b = 2
    check a + b == 5
  test "raises":
    raise newException(ValueError, "boom")

test "still ok":
  check true
