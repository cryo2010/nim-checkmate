import std/[unittest, os]
import checkmate/config

let tmpRoot = getTempDir() / "checkmate_t_config"

suite "config defaults and toml":
  setup:
    removeDir(tmpRoot)
    createDir(tmpRoot)
  teardown:
    removeDir(tmpRoot)

  test "defaults":
    let cfg = defaultConfig()
    check cfg.dirs == @["tests"]
    check cfg.pattern == "t*.nim"
    check cfg.loop == 1
    check cfg.timeoutSec == 300
    check cfg.color == cmAuto
    check not cfg.allowEmptyTests

  test "load without toml keeps defaults and sets roots":
    let cfg = loadConfig(tmpRoot)
    check cfg.projectRoot == absolutePath(tmpRoot)
    check cfg.cacheDir == absolutePath(tmpRoot) / ".checkmate"
    check cfg.dirs == @["tests"]

  test "toml overrides defaults":
    writeFile(tmpRoot / "checkmate.toml", """
[tests]
dirs = ["spec", "tests"]
exclude = ["spec/fixtures/*"]
[run]
loop = 3
bail = true
timeout = 10
allow_empty_tests = true
[compile]
flags = ["-d:release"]
[output]
color = "never"
""")
    let cfg = loadConfig(tmpRoot)
    check cfg.dirs == @["spec", "tests"]
    check cfg.exclude == @["spec/fixtures/*"]
    check cfg.loop == 3
    check cfg.bail
    check cfg.timeoutSec == 10
    check cfg.nimFlags == @["-d:release"]
    check cfg.color == cmNever
    check cfg.allowEmptyTests

  test "coverage min_lines accepts float, int and negative":
    writeFile(tmpRoot / "checkmate.toml", "[coverage]\nenabled = true\nmin_lines = 80.5\n")
    check loadConfig(tmpRoot).covMinLines == 80.5
    writeFile(tmpRoot / "checkmate.toml", "[coverage]\nmin_lines = -50\n")
    check loadConfig(tmpRoot).covMinLines == -50.0
    check defaultConfig().covMinLines == 0.0
    writeFile(tmpRoot / "checkmate.toml", "[coverage]\nmin_lines = 101\n")
    expect UsageError:
      discard loadConfig(tmpRoot)
    writeFile(tmpRoot / "checkmate.toml", "[coverage]\nmin_lines = \"lots\"\n")
    expect UsageError:
      discard loadConfig(tmpRoot)

  test "invalid toml raises UsageError":
    writeFile(tmpRoot / "checkmate.toml", "[run]\nloop = \"three\"\n")
    expect UsageError:
      discard loadConfig(tmpRoot)

  test "generated init template parses back":
    writeFile(tmpRoot / "checkmate.toml", initTomlTemplate)
    let cfg = loadConfig(tmpRoot)
    check cfg.dirs == @["tests"]
    check cfg.jobs == 0
    check not cfg.covEnabled

  test "cli merge respects sentinels":
    var cfg = defaultConfig()
    cfg.loop = 5
    cfg.mergeCli(loop = 0, jobs = 0, timeout = -1, bail = false,
                 verbose = false, coverage = false, color = "",
                 nimFlags = @[])
    check cfg.loop == 5          # sentinel: untouched
    check cfg.timeoutSec == 300
    cfg.mergeCli(loop = 2, jobs = 4, timeout = 0, bail = true,
                 verbose = true, coverage = false, color = "never",
                 nimFlags = @["--mm:orc"])
    check cfg.loop == 2
    check cfg.jobs == 4
    check cfg.timeoutSec == 0    # explicit 0 disables
    check cfg.bail
    check cfg.color == cmNever
    check cfg.nimFlags == @["--mm:orc"]

  test "bad color mode raises":
    expect UsageError:
      discard parseColorMode("sometimes")

suite "findProjectRoot":
  test "walks up to checkmate.toml":
    removeDir(tmpRoot)
    createDir(tmpRoot / "a" / "b")
    writeFile(tmpRoot / "checkmate.toml", "")
    check findProjectRoot(tmpRoot / "a" / "b") == absolutePath(tmpRoot)
    removeDir(tmpRoot)
  test "falls back to start dir":
    let dir = getTempDir() / "checkmate_t_config_noroot"
    removeDir(dir); createDir(dir)
    check findProjectRoot(dir) == absolutePath(dir)
    removeDir(dir)
