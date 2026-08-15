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
