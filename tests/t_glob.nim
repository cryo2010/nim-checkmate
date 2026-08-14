import std/unittest
import checkmate/discovery

suite "globMatch":
  test "exact match":
    check globMatch("t_foo.nim", "t_foo.nim")
    check not globMatch("t_foo.nim", "t_bar.nim")
  test "star wildcard":
    check globMatch("t_foo.nim", "t*.nim")
    check globMatch("test_foo.nim", "t*.nim")
    check not globMatch("foo_test.nim", "t*.nim")
    check globMatch("anything", "*")
  test "star crosses separators":
    check globMatch("tests/fixtures/passing/t_ok.nim", "tests/fixtures/*")
  test "question mark":
    check globMatch("t1.nim", "t?.nim")
    check not globMatch("t12.nim", "t?.nim")
  test "multiple stars":
    check globMatch("t_foo_bar.nim", "t*foo*.nim")
    check not globMatch("t_baz.nim", "t*foo*.nim")
  test "empty cases":
    check globMatch("", "")
    check globMatch("", "*")
    check not globMatch("x", "")
