# does not match t*.nim: not discovered as a test file. Its failing check
# demonstrates the filename:line header for checks outside the test file.
import std/unittest

proc assertPositive*(x: int) =
  check x > 0
