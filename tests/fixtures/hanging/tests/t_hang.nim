import std/[unittest, os]

test "quick one":
  check true

test "never finishes":
  sleep(600_000)
  check true
