import std/unittest
import localgreet  # from ../lib, on the path only via checkmate's --path:<srcDir>

test "uses the project's own source module":
  check greet("bob") == "hello bob"
