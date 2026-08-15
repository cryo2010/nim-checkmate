# does not match t*.nim, so not discovered as a test file
import std/unittest

proc helperAssert*(x: int) =
  check x > 0
