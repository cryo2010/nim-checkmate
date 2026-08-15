import std/[unittest, os, strutils]
import checkmate/[config, shadow]

proc mkCfg(root: string): Config =
  result = defaultConfig()
  result.projectRoot = absolutePath(root)
  result.cacheDir = result.projectRoot / ".checkmate"

let tmpRoot = getTempDir() / "checkmate_t_shadow"

suite "patchUnittest":
  # the real toolchain file is the ground truth: if this fails after a
  # toolchain bump, the anchor list in shadow.nim needs updating
  let libDir = resolveNimLib(mkCfg(getCurrentDir()))

  test "resolves the toolchain lib dir":
    check libDir.len > 0
    check fileExists(libDir / "pure" / "unittest.nim")

  test "patches the real toolchain unittest":
    let patched = patchUnittest(readFile(libDir / "pure" / "unittest.nim"))
    check patched.len > 0
    check "checkmateOrigTest" in patched
    check "checkmateOrigCheck" in patched
    check "checkmateOrigExpect" in patched
    check "checkmateAssertions" in patched
    check "Test has no assertions" in patched

  test "rejects unknown layout":
    check patchUnittest("template test*(name: string) = discard").len == 0

  test "rejects duplicated anchors":
    let source = readFile(libDir / "pure" / "unittest.nim")
    check patchUnittest(source & "\n" & source).len == 0

suite "prepareLibFarm":
  setup:
    removeDir(tmpRoot)
    createDir(tmpRoot)
  teardown:
    removeDir(tmpRoot)

  test "builds the farm once, then no-ops":
    let cfg = mkCfg(tmpRoot)
    let first = prepareLibFarm(cfg)
    check first.ok
    let overlay = cfg.cacheDir / "libfarm" / "pure" / "unittest.nim"
    check fileExists(overlay)
    check symlinkExists(cfg.cacheDir / "libfarm" / "system.nim")
    check symlinkExists(cfg.cacheDir / "libfarm" / "pure" / "strutils.nim")
    let mtimeBefore = getLastModificationTime(overlay)
    let second = prepareLibFarm(cfg)
    check second.ok
    check second.dir == first.dir
    check getLastModificationTime(overlay) == mtimeBefore

  test "unresolvable nim binary disables with warning":
    var cfg = mkCfg(tmpRoot)
    cfg.nimBin = "checkmate-no-such-nim"
    let res = prepareLibFarm(cfg)
    check not res.ok
    check "disabled" in res.warning
