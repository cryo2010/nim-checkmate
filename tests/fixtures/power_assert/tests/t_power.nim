# All tests fail deliberately: this fixture showcases power-assert output
# for boolean connectives (which stock unittest does not decompose at all).
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
