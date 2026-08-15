import std/unittest
import ./helper

suite "empty enforcement":
  test "has no assertions":        # FAILED: the feature under test
    let x = 1 + 1
    discard x
  test "asserts via helper":       # OK: cross-module counting
    helperAssert(3)
  test "skipped":                  # SKIPPED: not flagged
    skip()
  test "uses expect":              # OK
    expect ValueError:
      raise newException(ValueError, "boom")
  test "uses require":             # OK
    require 1 < 2
  test "escape hatch":             # OK: deliberate smoke test says so explicitly
    check true
