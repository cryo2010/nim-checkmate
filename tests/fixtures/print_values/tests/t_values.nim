# Both tests fail deliberately: this fixture exists to show what failing
# checks PRINT under the overlay (repr fallback, value truncation).
import std/[unittest, strutils]

type Point = object
  x, y: int

proc `==`(a, b: Point): bool = a.x == b.x and a.y == b.y
# no `$` for Point on purpose: stock unittest would print nothing for it

test "object without a dollar operator":
  let a = Point(x: 1, y: 2)
  let b = Point(x: 1, y: 3)
  check a == b

test "huge values are truncated":
  let big = 'x'.repeat(2000)
  check big == "small"

test "long strings show the first difference":
  let lhs = 'a'.repeat(100) & "X" & 'a'.repeat(100)
  let rhs = 'a'.repeat(100) & "Y" & 'a'.repeat(100)
  check lhs == rhs

test "seqs show the first mismatching index":
  check @[1, 2, 3, 4] == @[1, 2, 9, 4]

test "difference beyond the truncation window":
  # both printed values truncate to identical 400-char prefixes; only the
  # diff line reveals where they diverge
  var expected = "the quick brown fox jumps over the lazy dog. ".repeat(45)[0 ..< 2000]
  var actual = expected
  actual[1500] = 'Z'
  actual[1504] = 'Z'
  check actual == expected

test "seqs of different lengths":
  check @[1, 2, 3] == @[1, 2, 3, 4, 5]
