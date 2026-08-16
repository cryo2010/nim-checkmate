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

  test "time travel config parses and validates":
    writeFile(tmpRoot / "checkmate.toml",
      "[run]\ntime_travel = true\ntime_start = \"2020-06-15T12:00:00Z\"\n")
    let cfg = loadConfig(tmpRoot)
    check cfg.timeTravel
    check cfg.timeStart == "2020-06-15T12:00:00Z"
    check not defaultConfig().timeTravel
    writeFile(tmpRoot / "checkmate.toml", "[run]\ntime_start = \"soonish\"\n")
    expect UsageError:
      discard loadConfig(tmpRoot)

  test "parseTimeStartNs accepts the documented formats":
    check parseTimeStartNs("2020-06-15T12:00:00Z") ==
      1_592_222_400'i64 * 1_000_000_000'i64
    check parseTimeStartNs("2020-06-15T12:00:00") > 0
    check parseTimeStartNs("2020-06-15") > 0
    expect UsageError:
      discard parseTimeStartNs("June 15th 2020")
    expect UsageError:
      discard parseTimeStartNs("1930-01-01")  # pre-1970

  test "parseTimeStartNs accepts unix epoch seconds":
    check parseTimeStartNs("1592222400") ==
      1_592_222_400'i64 * 1_000_000_000'i64   # same instant as the ISO form
    check parseTimeStartNs("0") == 0          # 1970-01-01T00:00:00Z
    check parseTimeStartNs("1592222400.5") ==
      int64(1_592_222_400.5 * 1e9)
    expect UsageError:
      discard parseTimeStartNs("99999999999")  # ~year 5138: out of range
    expect UsageError:
      discard parseTimeStartNs("1.2.3")

  test "format caps parse with defaults and validate":
    let defaults = defaultConfig()
    check defaults.fmtMaxPath == 44
    check defaults.fmtMaxSuite == 60
    check defaults.fmtMaxTest == 60
    check defaults.fmtMaxValue == 400
    writeFile(tmpRoot / "checkmate.toml",
      "[format]\nmax_path = 0\nmax_suite = 30\nmax_value = 1000\n")
    let cfg = loadConfig(tmpRoot)
    check cfg.fmtMaxPath == 0        # 0 = unlimited
    check cfg.fmtMaxSuite == 30
    check cfg.fmtMaxTest == 60       # untouched key keeps default
    check cfg.fmtMaxValue == 1000
    writeFile(tmpRoot / "checkmate.toml", "[format]\nmax_test = -1\n")
    expect UsageError:
      discard loadConfig(tmpRoot)
    check defaults.fmtContext == 3
    writeFile(tmpRoot / "checkmate.toml", "[format]\ncontext = 0\n")
    check loadConfig(tmpRoot).fmtContext == 0
    writeFile(tmpRoot / "checkmate.toml", "[format]\ncontext = -2\n")
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

  test "auto color respects tty, NO_COLOR, TERM and CI":
    check autoColorAllowed(true, "", "xterm-256color", "")
    check not autoColorAllowed(false, "", "xterm-256color", "")
    check not autoColorAllowed(true, "1", "xterm-256color", "")
    check not autoColorAllowed(true, "", "dumb", "")
    check not autoColorAllowed(true, "", "xterm-256color", "true")
    check not autoColorAllowed(true, "", "xterm-256color", "1")
    check not autoColorAllowed(true, "", "xterm-256color", "woodpecker")
    # explicit CI opt-outs do not disable color
    check autoColorAllowed(true, "", "xterm-256color", "false")
    check autoColorAllowed(true, "", "xterm-256color", "0")

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
