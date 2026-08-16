## Two DISTINCT test blocks sharing one name: they must never merge into a
## phantom flake, in plain runs or under --loop-in-process.
import std/unittest

test "roundtrip":
  check true

test "roundtrip":
  check 1 == 2
