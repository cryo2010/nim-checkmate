import std/unittest

test "with checks":
  check 1 + 1 == 2
  check 2 + 2 == 4

test "no checks":
  discard

test "one failing check":
  check 1 == 2

test "skipped":
  skip()
  check false
