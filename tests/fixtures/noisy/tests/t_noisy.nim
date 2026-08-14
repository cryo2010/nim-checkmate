import std/unittest

echo "setup chatter on stdout"
stderr.writeLine "setup chatter on stderr"

test "noisy failure":
  echo "inside the failing test"
  check false

test "noisy pass":
  echo "inside the passing test"
  check true
