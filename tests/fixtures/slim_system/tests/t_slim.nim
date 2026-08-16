## Compiles under -d:nimPreviewSlimSystem (set in this fixture's config).
## The point is the compile: checkmate's injected formatter uses File/open/
## writeLine, which leave `system` under slim system.
import std/unittest

suite "slim system":
  test "runs a real assertion under slim system":
    check 2 + 2 == 4
