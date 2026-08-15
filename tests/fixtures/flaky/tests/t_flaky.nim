import std/[unittest, os]

# Deterministic flake: alternates fail/pass across executions via a marker
# file in the fixture root (cwd of the test binary is where checkmate ran).
const marker = "flake_marker"
let x = true

test "sometimes works":
  if fileExists(marker):
    removeFile(marker)
    check true
  else:
    writeFile(marker, "")
    check x == false

test "always works":
  check 1 + 1 == 2
