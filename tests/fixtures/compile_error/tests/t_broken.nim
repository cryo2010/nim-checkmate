import std/unittest

test "does not compile":
  check undeclaredIdentifier == 42
