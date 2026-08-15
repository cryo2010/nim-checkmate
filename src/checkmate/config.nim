## Configuration: defaults <- checkmate.toml <- CLI flags.

import std/[os, strutils, terminal]
import parsetoml

type
  UsageError* = object of CatchableError

  ColorMode* = enum
    cmAuto = "auto", cmAlways = "always", cmNever = "never"

  Config* = object
    # [tests]
    dirs*: seq[string]
    pattern*: string
    exclude*: seq[string]
    # [run]
    jobs*: int          # 0 = CPU cores
    loop*: int
    bail*: bool
    timeoutSec*: int    # 0 disables
    passWithNoTests*: bool  # zero tests run is a pass instead of a failure
    allowEmptyTests*: bool  # don't fail tests that execute zero assertions
    # [compile]
    nimBin*: string
    backend*: string
    nimFlags*: seq[string]
    defines*: seq[string]
    extraPaths*: seq[string]
    # [output]
    color*: ColorMode
    verbose*: bool
    # [coverage]
    covEnabled*: bool
    # resolved at load time
    projectRoot*: string
    cacheDir*: string

const ConfigFileName* = "checkmate.toml"

proc defaultConfig*(): Config =
  Config(
    dirs: @["tests"], pattern: "t*.nim", exclude: @[],
    jobs: 0, loop: 1, bail: false, timeoutSec: 300,
    nimBin: "nim", backend: "c",
    color: cmAuto, verbose: false, covEnabled: false)

proc findProjectRoot*(startDir: string): string =
  var dir = absolutePath(startDir)
  while true:
    if fileExists(dir / ConfigFileName):
      return dir
    let parent = parentDir(dir)
    if parent == dir or parent.len == 0:
      return absolutePath(startDir)
    dir = parent

proc parseColorMode*(s: string): ColorMode =
  case s.toLowerAscii
  of "auto": cmAuto
  of "always": cmAlways
  of "never": cmNever
  else: raise newException(UsageError, "invalid color mode: '" & s & "' (expected auto|always|never)")

proc colorsEnabled*(cfg: Config): bool =
  case cfg.color
  of cmAlways: true
  of cmNever: false
  of cmAuto:
    isatty(stdout) and getEnv("NO_COLOR").len == 0 and getEnv("TERM") != "dumb"

# --- TOML loading ---------------------------------------------------------

proc tget(t: TomlValueRef, key: string): TomlValueRef =
  if t != nil and t.kind == TomlValueKind.Table and t.tableVal.hasKey(key):
    t.tableVal[key]
  else:
    nil

proc getStrSeq(v: TomlValueRef, ctx: string): seq[string] =
  if v == nil: return
  if v.kind != TomlValueKind.Array:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be an array of strings")
  for e in v.arrayVal:
    if e.kind != TomlValueKind.String:
      raise newException(UsageError, ConfigFileName & ": " & ctx & " must be an array of strings")
    result.add e.stringVal

proc getStr(v: TomlValueRef, ctx: string, default: string): string =
  if v == nil: return default
  if v.kind != TomlValueKind.String:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be a string")
  v.stringVal

proc getInt(v: TomlValueRef, ctx: string, default: int): int =
  if v == nil: return default
  if v.kind != TomlValueKind.Int:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be an integer")
  v.intVal.int

proc getBool(v: TomlValueRef, ctx: string, default: bool): bool =
  if v == nil: return default
  if v.kind != TomlValueKind.Bool:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be a boolean")
  v.boolVal

proc warnUnknownKeys(toml: TomlValueRef) =
  const known = {
    "tests": @["dirs", "pattern", "exclude"],
    "run": @["jobs", "loop", "bail", "timeout", "pass_with_no_tests",
             "allow_empty_tests"],
    "compile": @["nim", "backend", "flags", "defines", "paths"],
    "output": @["color", "verbose"],
    "coverage": @["enabled"],
  }.toOrderedTable
  if toml.kind != TomlValueKind.Table: return
  for section, node in toml.tableVal:
    if not known.hasKey(section):
      stderr.writeLine "checkmate: warning: unknown section [" & section & "] in " & ConfigFileName
    elif node.kind == TomlValueKind.Table:
      for key in node.tableVal.keys:
        if key notin known[section]:
          stderr.writeLine "checkmate: warning: unknown key '" & section & "." & key & "' in " & ConfigFileName

proc loadConfig*(root: string): Config =
  ## Defaults overlaid with checkmate.toml (if present in root).
  result = defaultConfig()
  result.projectRoot = absolutePath(root)
  result.cacheDir = result.projectRoot / ".checkmate"
  let path = result.projectRoot / ConfigFileName
  if not fileExists(path):
    return
  var toml: TomlValueRef
  try:
    toml = parsetoml.parseFile(path)
  except TomlError as e:
    raise newException(UsageError, ConfigFileName & ": " & e.msg)
  warnUnknownKeys(toml)

  let tests = toml.tget("tests")
  if tests.tget("dirs") != nil: result.dirs = tests.tget("dirs").getStrSeq("tests.dirs")
  result.pattern = tests.tget("pattern").getStr("tests.pattern", result.pattern)
  result.exclude = tests.tget("exclude").getStrSeq("tests.exclude")

  let run = toml.tget("run")
  result.jobs = run.tget("jobs").getInt("run.jobs", result.jobs)
  result.loop = run.tget("loop").getInt("run.loop", result.loop)
  result.bail = run.tget("bail").getBool("run.bail", result.bail)
  result.timeoutSec = run.tget("timeout").getInt("run.timeout", result.timeoutSec)
  result.passWithNoTests = run.tget("pass_with_no_tests").getBool(
    "run.pass_with_no_tests", result.passWithNoTests)
  result.allowEmptyTests = run.tget("allow_empty_tests").getBool(
    "run.allow_empty_tests", result.allowEmptyTests)

  let compile = toml.tget("compile")
  result.nimBin = compile.tget("nim").getStr("compile.nim", result.nimBin)
  result.backend = compile.tget("backend").getStr("compile.backend", result.backend)
  result.nimFlags = compile.tget("flags").getStrSeq("compile.flags")
  result.defines = compile.tget("defines").getStrSeq("compile.defines")
  result.extraPaths = compile.tget("paths").getStrSeq("compile.paths")

  let output = toml.tget("output")
  result.color = parseColorMode(output.tget("color").getStr("output.color", $result.color))
  result.verbose = output.tget("verbose").getBool("output.verbose", result.verbose)

  let coverage = toml.tget("coverage")
  result.covEnabled = coverage.tget("enabled").getBool("coverage.enabled", result.covEnabled)

  if result.loop < 1:
    raise newException(UsageError, ConfigFileName & ": run.loop must be >= 1")
  if result.backend notin ["c", "cpp"]:
    raise newException(UsageError, ConfigFileName & ": compile.backend must be c or cpp")

# --- CLI merge ------------------------------------------------------------

proc mergeCli*(cfg: var Config; loop, jobs, timeout: int; bail, verbose, coverage: bool;
               color: string; nimFlags: seq[string]; passWithNoTests = false;
               allowEmptyTests = false) =
  ## Sentinels mark "not passed": loop=0, jobs=0 means unset only when 0 is
  ## also the config default meaning (cores), timeout=-1, color="".
  if loop > 0: cfg.loop = loop
  if jobs > 0: cfg.jobs = jobs
  if timeout >= 0: cfg.timeoutSec = timeout
  if bail: cfg.bail = true
  if verbose: cfg.verbose = true
  if coverage: cfg.covEnabled = true
  if color.len > 0: cfg.color = parseColorMode(color)
  if passWithNoTests: cfg.passWithNoTests = true
  if allowEmptyTests: cfg.allowEmptyTests = true
  cfg.nimFlags.add nimFlags

# --- checkmate init -------------------------------------------------------

const initTomlTemplate* = """# checkmate.toml - configuration for the checkmate test runner
# CLI flags override these values.

[tests]
dirs = ["tests"]          # directories scanned recursively for test files
pattern = "t*.nim"        # filename glob; covers t_*.nim and test_*.nim conventions
exclude = []              # path globs to skip, e.g. ["tests/fixtures/*"]

[run]
jobs = 0                  # parallel workers; 0 = number of CPU cores
loop = 1                  # run the whole suite N times (flake detection)
bail = false              # stop on first failing test file
timeout = 300             # seconds per test binary; 0 disables
pass_with_no_tests = false  # exit 0 even when zero tests were run
allow_empty_tests = false   # don't fail tests that execute zero check/require/expect

[compile]
nim = "nim"               # compiler executable
backend = "c"             # nim backend: c | cpp
flags = []                # extra nim flags, e.g. ["-d:release", "--mm:orc"]
defines = []              # shorthand for -d: defines
paths = []                # extra --path entries

[output]
color = "auto"            # auto | always | never
verbose = false           # also show per-test lines and passing tests' output

[coverage]
enabled = false           # line coverage via gcov (needs xcrun, llvm-cov or gcov)
"""

proc writeInitToml*(dir: string, force: bool): string =
  ## Writes checkmate.toml into dir; returns the path.
  result = dir / ConfigFileName
  if fileExists(result) and not force:
    raise newException(UsageError, result & " already exists (use --force to overwrite)")
  writeFile(result, initTomlTemplate)
