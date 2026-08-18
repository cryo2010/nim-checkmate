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
  test "positional regex narrows to matching paths":
    let found = discoverTests(mkCfg(), @["sub"]).mapIt(it.relPath)
    check found == @["tests/sub/t_c.nim"]
  test "positional pattern is a regex, not a literal path":
    # a char class matches t_a and t_c but not test_b: proves it is a regex
    let found = discoverTests(mkCfg(), @["t_[ac]"]).mapIt(it.relPath).sorted
    check found == @["tests/sub/t_c.nim", "tests/t_a.nim"].sorted
  test "multiple positional regexes OR together":
    let found = discoverTests(mkCfg(), @["t_a", "test_b"]).mapIt(it.relPath).sorted
    check found == @["tests/t_a.nim", "tests/test_b.nim"].sorted
  test "invalid positional regex raises UsageError":
    expect UsageError:
      discard discoverTests(mkCfg(), @["("])
  test "slugs flatten separators":
    let found = discoverTests(mkCfg(), @[]).filterIt(it.relPath == "tests/sub/t_c.nim")
    check found[0].slug == "tests__sub__t_c"
