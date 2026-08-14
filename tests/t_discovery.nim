import std/[unittest, os, algorithm, sequtils]
import checkmate/[config, discovery]

let tmpRoot = getTempDir() / "checkmate_t_discovery"

proc mkCfg(): Config =
  result = defaultConfig()
  result.projectRoot = absolutePath(tmpRoot)
  result.cacheDir = result.projectRoot / ".checkmate"

suite "discoverTests":
  setup:
    removeDir(tmpRoot)
    createDir(tmpRoot / "tests" / "sub")
    createDir(tmpRoot / "tests" / "fixtures" / "x")
    writeFile(tmpRoot / "tests" / "t_a.nim", "")
    writeFile(tmpRoot / "tests" / "test_b.nim", "")
    writeFile(tmpRoot / "tests" / "helper.nim", "")
    writeFile(tmpRoot / "tests" / "sub" / "t_c.nim", "")
    writeFile(tmpRoot / "tests" / "fixtures" / "x" / "t_fix.nim", "")
  teardown:
    removeDir(tmpRoot)

  test "walks dirs with pattern":
    let found = discoverTests(mkCfg(), @[]).mapIt(it.relPath)
    check found == @["tests/sub/t_c.nim", "tests/t_a.nim",
                     "tests/fixtures/x/t_fix.nim", "tests/test_b.nim"].sorted
  test "exclude drops matching paths":
    var cfg = mkCfg()
    cfg.exclude = @["tests/fixtures/*"]
    let found = discoverTests(cfg, @[]).mapIt(it.relPath)
    check "tests/fixtures/x/t_fix.nim" notin found
    check found.len == 3
  test "explicit file bypasses pattern":
    let found = discoverTests(mkCfg(), @[tmpRoot / "tests" / "helper.nim"])
    check found.len == 1
    check found[0].relPath == "tests/helper.nim"
  test "explicit dir applies pattern":
    let found = discoverTests(mkCfg(), @[tmpRoot / "tests" / "sub"]).mapIt(it.relPath)
    check found == @["tests/sub/t_c.nim"]
  test "missing path raises UsageError":
    expect UsageError:
      discard discoverTests(mkCfg(), @[tmpRoot / "nope"])
  test "slugs flatten separators":
    let found = discoverTests(mkCfg(), @[]).filterIt(it.relPath == "tests/sub/t_c.nim")
    check found[0].slug == "tests__sub__t_c"
