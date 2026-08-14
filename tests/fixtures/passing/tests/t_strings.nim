import std/[unittest, strutils]

suite "strings":
  test "upper":
    check "abc".toUpperAscii == "ABC"
  test "skipped one":
    skip()
