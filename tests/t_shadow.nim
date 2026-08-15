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
    check "checkmateTrim" in patched  # repr-fallback/truncation print patch
    check "checkmateExplainDiff" in patched  # ==-aware diff injection

  test "rejects unknown layout":
    check patchUnittest("template test*(name: string) = discard").len == 0

  test "rejects duplicated anchors":
    let source = readFile(libDir / "pure" / "unittest.nim")
    check patchUnittest(source & "\n" & source).len == 0

  test "patches the real toolchain time modules":
    let times = patchTimes(readFile(libDir / "pure" / "times.nim"))
    check times.len > 0
    check "checkmateOrigGetTime" in times
    check "checkmateOrigEpochTime" in times
    let mono = patchMonotimes(readFile(libDir / "std" / "monotimes.nim"))
    check mono.len > 0
    check "checkmateOrigGetMonoTime" in mono
    let osP = patchOs(readFile(libDir / "pure" / "os.nim"))
    check osP.len > 0
    check "checkmateOrigSleep" in osP
    let ad = patchAsyncdispatch(readFile(libDir / "pure" / "asyncdispatch.nim"))
    check ad.len > 0
    check ad.count("checkmateAdvanceMonoToTicks") == 2  # posix + windows runOnce

  test "time patchers reject unknown layouts":
    check patchTimes("nothing here").len == 0
    check patchMonotimes("nothing here").len == 0
    check patchOs("nothing here").len == 0
    check patchAsyncdispatch("nothing here").len == 0

  test "buildOverlays is all-or-nothing for time patches":
    let ovs = buildOverlays(libDir)
    check ovs.unittestOk
    check ovs.timeOk
    check ovs.overlays.len == 6  # unittest + 4 time modules + timebase

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
    check first.timeOk
    let farm = cfg.cacheDir / "libfarm"
    let overlay = farm / "pure" / "unittest.nim"
    check fileExists(overlay)
    check symlinkExists(farm / "system.nim")
    check symlinkExists(farm / "pure" / "strutils.nim")
    # time overlays: std/ is per-entry mirrored, overlays are real files
    check fileExists(farm / "pure" / "checkmate_timebase.nim")
    check not symlinkExists(farm / "std" / "monotimes.nim")
    check fileExists(farm / "std" / "monotimes.nim")
    check symlinkExists(farm / "std" / "assertions.nim")
    check "time=true" in readFile(cfg.cacheDir / "libfarm.stamp")
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
