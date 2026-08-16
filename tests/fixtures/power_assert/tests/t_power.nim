# Nearly all tests fail deliberately: this fixture showcases power-assert
# output for boolean connectives (which stock unittest does not decompose
# at all). The final test PASSES to prove == operands evaluate only once.
import std/unittest

type User = object
  age: int
  name: string

type Conn = ref object
  port: int

test "and chain shows the failing side and skips the rest":
  let user = User(age: 16, name: "sam")
  check user.age >= 18 and user.name.len > 0

test "nil guard short-circuits safely":
  var conn: Conn = nil
  check conn != nil and conn.port == 443

test "or chain shows every attempted alternative":
  let code = 500
  check code == 200 or code == 201 or code == 204

test "not shows the operand value":
  let shuttingDown = true
  check not (shuttingDown == false) and false

test "string diff windows appear inside boolean chains":
  var expected = ""
  for _ in 1 .. 5:
    expected.add "the quick brown fox jumps over the lazy dog. "
  var actual = expected
  actual[100] = 'Q'
  check actual == expected and true

test "seq diffs appear inside boolean chains":
  let want = @[1, 2, 3]
  let got = @[1, 2, 4]
  check got == want or false

test "sized-int literals unify inside boolean chains":
  # regression: comparing inside a generic recorder bound the literal 0 as
  # int and uint8 == int failed to COMPILE; the comparison must be emitted
  # verbatim so the literal adapts to uint8
  let flags: uint8 = 0b101
  check (flags and 1'u8) == 0 and true

var evals = 0
proc bumped(): uint8 =
  inc evals
  5'u8

test "== records the failing operand from a side-effecting call":
  check bumped() == 7 and true

test "side effects ran once":
  # PASSES: the let-bound == operand above must evaluate exactly once
  check evals == 1
