# exercises the [format] caps configured in this fixture's checkmate.toml
import std/unittest

suite "this suite name is quite long and rambles on about nothing":
  test "this test name is also excessively long and overly detailed":
    check false

  test "long value with configured cap":
    var v = ""
    for _ in 1 .. 20:
      v.add "0123456789"   # 200 chars
    check v == "x"
