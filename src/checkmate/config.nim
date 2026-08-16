## Configuration: defaults <- checkmate.toml <- CLI flags.

import std/[os, strutils, terminal, times]
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
    loopInProcess*: bool  # loop inside one process per file (fast, lower fidelity)
    bail*: bool
    timeoutSec*: int    # per-test budget (progress-based); 0 disables
    passWithNoTests*: bool  # zero tests run is a pass instead of a failure
    allowEmptyTests*: bool  # don't fail tests that execute zero assertions
    timeTravel*: bool       # virtualize clocks: sleep instant, time frozen
    timeStart*: string      # ISO 8601 pin for the virtual wall clock; "" = now
    # [compile]
    nimBin*: string
    backend*: string
    nimFlags*: seq[string]
    defines*: seq[string]
    extraPaths*: seq[string]
    # [output]
    color*: ColorMode
    verbose*: bool
    # [format] display lengths; 0 disables the respective truncation
    fmtMaxPath*: int    # rendered file paths (preceding ellipsis)
    fmtMaxSuite*: int   # suite names (trailing ellipsis)
    fmtMaxTest*: int    # test names (trailing ellipsis)
    fmtMaxValue*: int   # printed operand values in check failures
    fmtContext*: int    # source lines of context around failing lines
    # [coverage]
    covEnabled*: bool
    covMinLines*: float  # >0: min percent; <0: max uncovered lines; 0: no gate
    # resolved at load time
    projectRoot*: string
    cacheDir*: string

const ConfigFileName* = "checkmate.toml"

proc defaultConfig*(): Config =
  Config(
    dirs: @["tests"], pattern: "t*.nim", exclude: @[],
    jobs: 0, loop: 1, bail: false, timeoutSec: 300,
    nimBin: "nim", backend: "c",
    fmtMaxPath: 44, fmtMaxSuite: 60, fmtMaxTest: 60, fmtMaxValue: 400,
    fmtContext: 3,
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

proc findFileProjectRoot*(startDir, fallback: string): string =
  ## Nearest directory at or above startDir containing checkmate.toml, so a
  ## positional test file belonging to a nested project runs under that
  ## project's config and cache; fallback when none is found.
  var dir = absolutePath(startDir)
  while true:
    if fileExists(dir / ConfigFileName):
      return dir
    let parent = parentDir(dir)
    if parent == dir or parent.len == 0:
      return fallback
    dir = parent

proc parseColorMode*(s: string): ColorMode =
  case s.toLowerAscii
  of "auto": cmAuto
  of "always": cmAlways
  of "never": cmNever
  else: raise newException(UsageError, "invalid color mode: '" & s & "' (expected auto|always|never)")

proc autoColorAllowed*(isTty: bool; noColor, term, ci: string): bool =
  ## The cmAuto decision, pure for testability. CI=false/0/empty does not
  ## count as CI (some environments export CI=false to opt out).
  if not isTty or noColor.len > 0 or term == "dumb":
    return false
  let ciNorm = ci.toLowerAscii
  ciNorm.len == 0 or ciNorm in ["false", "0"]

proc colorsEnabled*(cfg: Config): bool =
  case cfg.color
  of cmAlways: true
  of cmNever: false
  of cmAuto:
    autoColorAllowed(isatty(stdout), getEnv("NO_COLOR"), getEnv("TERM"),
                     getEnv("CI"))

proc parseTimeStartNs*(s: string): int64 =
  ## time_start value to Unix epoch nanoseconds; UsageError on bad input.
  ## Accepts ISO 8601 forms or a unix epoch in seconds (optional fraction).
  const maxEpochSecs = 9_000_000_000'i64  # ~year 2255; ns fits in int64
  var digitsOnly = s.len > 0
  var dots = 0
  for c in s:
    if c == '.': inc dots
    elif c notin {'0' .. '9'}: digitsOnly = false
  if digitsOnly and dots <= 1:
    if dots == 0:
      let secs =
        try: parseBiggestInt(s)
        except ValueError: -1'i64  # absurd lengths overflow: reject below
      if secs < 0 or secs > maxEpochSecs:
        raise newException(UsageError, "time_start epoch out of range: " & s)
      return secs * 1_000_000_000'i64
    else:
      let secs = parseFloat(s)
      if secs > maxEpochSecs.float:
        raise newException(UsageError, "time_start epoch out of range: " & s)
      return int64(secs * 1e9)
  var t: Time
  var parsed = false
  for fmt in ["yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]:
    try:
      t = parse(s, fmt).toTime
      parsed = true
      break
    except CatchableError:
      discard
  if not parsed:
    raise newException(UsageError, "invalid time_start '" & s &
      "' (accepted: 2020-06-15T12:00:00Z, 2020-06-15T12:00:00, 2020-06-15, " &
      "or unix epoch seconds)")
  let secs = t.toUnix
  if secs < 0:
    raise newException(UsageError, "time_start must not be before 1970")
  if secs > maxEpochSecs:
    # same bound as the numeric branch: without it the ns multiplication
    # overflows int64 for dates past ~2262 (OverflowDefect, not UsageError)
    raise newException(UsageError, "time_start epoch out of range: " & s)
  result = secs * 1_000_000_000'i64 + t.nanosecond

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

proc getFloat(v: TomlValueRef, ctx: string, default: float): float =
  if v == nil: return default
  case v.kind
  of TomlValueKind.Float: v.floatVal
  of TomlValueKind.Int: v.intVal.float
  else:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be a number")

proc getBool(v: TomlValueRef, ctx: string, default: bool): bool =
  if v == nil: return default
  if v.kind != TomlValueKind.Bool:
    raise newException(UsageError, ConfigFileName & ": " & ctx & " must be a boolean")
  v.boolVal

proc warnUnknownKeys(toml: TomlValueRef) =
  const known = {
    "tests": @["dirs", "pattern", "exclude"],
    "run": @["jobs", "loop", "loop_in_process", "bail", "timeout",
             "pass_with_no_tests", "allow_empty_tests", "time_travel",
             "time_start"],
    "compile": @["nim", "backend", "flags", "defines", "paths"],
    "output": @["color", "verbose"],
    "format": @["max_path", "max_suite", "max_test", "max_value", "context"],
    "coverage": @["enabled", "min_lines"],
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
  result.loopInProcess = run.tget("loop_in_process").getBool(
    "run.loop_in_process", result.loopInProcess)
  result.bail = run.tget("bail").getBool("run.bail", result.bail)
  result.timeoutSec = run.tget("timeout").getInt("run.timeout", result.timeoutSec)
  result.passWithNoTests = run.tget("pass_with_no_tests").getBool(
    "run.pass_with_no_tests", result.passWithNoTests)
  result.allowEmptyTests = run.tget("allow_empty_tests").getBool(
    "run.allow_empty_tests", result.allowEmptyTests)
  result.timeTravel = run.tget("time_travel").getBool(
    "run.time_travel", result.timeTravel)
  result.timeStart = run.tget("time_start").getStr(
    "run.time_start", result.timeStart)
  if result.timeStart.len > 0:
    discard parseTimeStartNs(result.timeStart)  # validate early

  let compile = toml.tget("compile")
  result.nimBin = compile.tget("nim").getStr("compile.nim", result.nimBin)
  result.backend = compile.tget("backend").getStr("compile.backend", result.backend)
  result.nimFlags = compile.tget("flags").getStrSeq("compile.flags")
  result.defines = compile.tget("defines").getStrSeq("compile.defines")
  result.extraPaths = compile.tget("paths").getStrSeq("compile.paths")

  let output = toml.tget("output")
  result.color = parseColorMode(output.tget("color").getStr("output.color", $result.color))
  result.verbose = output.tget("verbose").getBool("output.verbose", result.verbose)

  let format = toml.tget("format")
  result.fmtMaxPath = format.tget("max_path").getInt("format.max_path", result.fmtMaxPath)
  result.fmtMaxSuite = format.tget("max_suite").getInt("format.max_suite", result.fmtMaxSuite)
  result.fmtMaxTest = format.tget("max_test").getInt("format.max_test", result.fmtMaxTest)
  result.fmtMaxValue = format.tget("max_value").getInt("format.max_value", result.fmtMaxValue)
  result.fmtContext = format.tget("context").getInt("format.context", result.fmtContext)
  for (key, val) in [("max_path", result.fmtMaxPath),
                     ("max_suite", result.fmtMaxSuite),
                     ("max_test", result.fmtMaxTest),
                     ("max_value", result.fmtMaxValue),
                     ("context", result.fmtContext)]:
    if val < 0:
      raise newException(UsageError,
        ConfigFileName & ": format." & key & " must be >= 0 (0 disables)")

  let coverage = toml.tget("coverage")
  result.covEnabled = coverage.tget("enabled").getBool("coverage.enabled", result.covEnabled)
  result.covMinLines = coverage.tget("min_lines").getFloat(
    "coverage.min_lines", result.covMinLines)
  if result.covMinLines > 100:
    raise newException(UsageError, ConfigFileName & ": coverage.min_lines cannot exceed 100")

  if result.loop < 1:
    raise newException(UsageError, ConfigFileName & ": run.loop must be >= 1")
  if result.backend notin ["c", "cpp"]:
    raise newException(UsageError, ConfigFileName & ": compile.backend must be c or cpp")

# --- CLI merge ------------------------------------------------------------

proc mergeCli*(cfg: var Config; loop, jobs, timeout: int; bail, verbose, coverage: bool;
               color: string; nimFlags: seq[string]; passWithNoTests = false;
               allowEmptyTests = false; minLines = 0.0;
               loopInProcess = false; timeTravel = false; timeStart = "") =
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
  if loopInProcess: cfg.loopInProcess = true
  if timeTravel: cfg.timeTravel = true
  if timeStart.len > 0:
    discard parseTimeStartNs(timeStart)  # validate
    cfg.timeStart = timeStart
  if minLines != 0:
    if minLines > 100:
      raise newException(UsageError, "--min-lines cannot exceed 100")
    cfg.covMinLines = minLines
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
loop_in_process = false   # loop each test inside one process per file:
                          # much faster, but iterations share process state
bail = false              # stop everything at the first failing test
timeout = 300             # seconds a single test may run; hung or overlong
                          # tests fail and their file's process is killed
                          # (0 disables)
pass_with_no_tests = false  # exit 0 even when zero tests were run
allow_empty_tests = false   # don't fail tests that execute zero check/require/expect
time_travel = false       # virtualize clocks: sleep() is instant, time is frozen
                          # and only advances via sleep/advanceTime/travelTo
time_start = ""           # pin the virtual wall clock: ISO 8601 like
                          # "2020-06-15T12:00:00Z" or unix epoch seconds like
                          # "1592222400" (empty = current time at run start)

[compile]
nim = "nim"               # compiler executable
backend = "c"             # nim backend: c | cpp
flags = []                # extra nim flags, e.g. ["-d:release", "--mm:orc"]
defines = []              # shorthand for -d: defines
paths = []                # extra --path entries

[output]
color = "auto"            # auto | always | never
verbose = false           # also show per-test lines and passing tests' output

[format]
max_path = 44             # rendered file paths, preceding ellipsis (0 = unlimited)
max_suite = 60            # suite names, trailing ellipsis (0 = unlimited)
max_test = 60             # test names, trailing ellipsis (0 = unlimited)
max_value = 400           # printed values in check failures (0 = unlimited)
context = 3               # source lines shown around a failing line (0 = just it)

[coverage]
enabled = false           # line coverage via gcov (needs xcrun, llvm-cov or gcov)
min_lines = 0             # coverage gate: minimum percent (e.g. 80.0) or, if
                          # negative, max uncovered lines (e.g. -50); 0 disables
"""

proc writeInitToml*(dir: string, force: bool): string =
  ## Writes checkmate.toml into dir; returns the path.
  result = dir / ConfigFileName
  if fileExists(result) and not force:
    raise newException(UsageError, result & " already exists (use --force to overwrite)")
  writeFile(result, initTomlTemplate)
