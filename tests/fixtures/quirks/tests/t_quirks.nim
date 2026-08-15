# std/unittest edge cases that a formatter-based observer can misreport;
# checkmate repairs each of these (all tests here fail deliberately except
# the first duplicate).
import std/unittest

proc helperBareFail*() =
  fail()   # cannot see testStatusIMPL from here; no checkpoint either

test "bare fail in helper":
  helperBareFail()

test "duplicate name":
  check true

test "duplicate name":
  check false

test "skips after failing":
  check false
  skip()   # stock unittest reports SKIPPED despite the failure
