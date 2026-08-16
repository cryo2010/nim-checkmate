## Spawns a long-lived helper child, records its pid, then hangs: the
## watchdog must kill the WHOLE process tree, not just the test binary.
import std/[unittest, os, osproc]

test "spawns a helper and hangs":
  let child = startProcess("sleep", args = @["300"], options = {poUsePath})
  writeFile("child.pid", $child.processID)
  check true
  sleep(600_000)
