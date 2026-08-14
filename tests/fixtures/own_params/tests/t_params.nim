# Documents a known limitation: std/unittest ingests ALL command-line
# params as test-name filters. A binary that also reads its own params
# (like this one) will misbehave under `checkmate -t PAT`, because the
# filter args reach paramStr here too. Without -t, checkmate passes no
# args and this file behaves normally.
import std/[unittest, os]

test "reads its own params":
  check paramCount() == 0
