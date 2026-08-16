import std/unittest
import std/[os, strutils]

# Deterministic flake for the demo: a per-file counter increments once per
# iteration (a file's iterations are serialized, so no races), failing on
# iterations 5 and 10 -> passes 8/10. run.sh deletes the counter first.
let counterFile = getCurrentDir() / "net_counter"
var n = 0
if fileExists(counterFile): n = parseInt(readFile(counterFile).strip)
inc n
writeFile(counterFile, $n)

suite "net":
  test "connection is stable":
    check n mod 5 != 0
