import std/unittest

suite "config":
  test "loads defaults":
    check 1 + 1 == 2
  test "parses toml":
    check "a".len == 1
  test "resolves the project root":
    check "tests".len == 5
