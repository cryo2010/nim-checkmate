## Empty-test enforcement via a stdlib overlay.
##
## Passing checks are invisible to OutputFormatters, so counting assertions
## requires intercepting the unittest module itself. `--lib` pointed at a
## symlink farm (real toolchain lib dir mirrored 1:1, with pure/unittest.nim
## replaced) intercepts BOTH `import unittest` and `import std/unittest`,
## which plain --path shadowing cannot.
##
## The overlay is NOT a vendored fork: it is a copy of the user's own
## toolchain unittest.nim with a handful of anchored textual patches (rename
## check/test/expect to checkmateOrig*, count inside require) plus an
## appended wrapper block that counts check/require/expect executions in a
## threadvar and fails a still-OK test whose counter did not move. Each
## anchor must match exactly once; otherwise the feature auto-disables with
## a warning and compilation stays fully stock (no --lib at all).

import std/[json, os, osproc, strutils]
import ./config

const OverlayVersion = 1

const anchorPatches: seq[(string, string)] = @[
  # 1: declare the counter before every later reference, rename check
  ("macro check*(conditions: untyped): untyped =",
   """# --- checkmate: empty-test enforcement (generated overlay, part 1) --------
const checkmateEmptyTestGuard* = true
var checkmateAssertions* {.threadvar.}: int

macro checkmateOrigCheck*(conditions: untyped): untyped ="""),
  # 2: rename test
  ("template test*(name, body) {.dirty.} =",
   "template checkmateOrigTest*(name, body) {.dirty.} ="),
  # 3: rename expect
  ("macro expect*(exceptions: varargs[typed], body: untyped): untyped =",
   "macro checkmateOrigExpect*(exceptions: varargs[typed], body: untyped): untyped ="),
  # 4: count inside require (not renamed, no wrapper; both referenced
  #    symbols are declared before require via patch 1)
  ("""  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    check conditions
  abortOnError = savedAbortOnError""",
   """  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    inc checkmateAssertions
    checkmateOrigCheck conditions
  abortOnError = savedAbortOnError"""),
]

const wrapperBlock = """

# --- checkmate: empty-test enforcement (generated overlay, part 2) --------

template check*(conditions: untyped): untyped =
  inc checkmateAssertions
  checkmateOrigCheck(conditions)

macro expect*(exceptions: varargs[typed], body: untyped): untyped =
  var origCall = newCall(newIdentNode("checkmateOrigExpect"))
  for e in exceptions:
    origCall.add e
  origCall.add body
  result = quote do:
    inc checkmateAssertions
    `origCall`

template test*(name, body) {.dirty.} =
  checkmateOrigTest name:
    let checkmateAssertionsBefore {.used.} = checkmateAssertions
    body
    if checkmateAssertions == checkmateAssertionsBefore and
        testStatusIMPL == TestStatus.OK:
      checkpoint("Test has no assertions (checkmate: add a check, or run with --allow-empty-tests)")
      fail()
"""

proc resolveNimLib*(cfg: Config): string =
  ## Toolchain lib dir via `nim dump`; honors the project's own nim config
  ## because it runs in projectRoot. "" on any failure.
  try:
    let (output, code) = execCmdEx(
      quoteShell(cfg.nimBin) & " dump --dump.format:json --hints:off checkmate_dump",
      options = {poUsePath, poEvalCommand},  # no poStdErrToStdOut: keep JSON clean
      workingDir = cfg.projectRoot)
    if code != 0: return ""
    let jsonStart = output.find('{')
    if jsonStart < 0: return ""
    let node = parseJson(output[jsonStart .. ^1])
    result = node{"libpath"}.getStr
    if not dirExists(result): result = ""
  except CatchableError:
    result = ""

proc patchUnittest*(source: string): string =
  ## Applies the anchored patches; "" if any anchor does not occur exactly
  ## once (unknown unittest layout, e.g. a future Nim version).
  result = source
  for (anchor, replacement) in anchorPatches:
    if result.count(anchor) != 1:
      return ""
    result = result.replace(anchor, replacement)
  result.add wrapperBlock

proc buildFarm(libDir, farm, overlay: string) =
  removeDir(farm)
  createDir(farm / "pure")
  for entry in walkDir(libDir):
    let name = extractFilename(entry.path)
    if name != "pure":
      createSymlink(entry.path, farm / name)
  for entry in walkDir(libDir / "pure"):
    let name = extractFilename(entry.path)
    if name != "unittest.nim":
      createSymlink(entry.path, farm / "pure" / name)
  writeFile(farm / "pure" / "unittest.nim", overlay)

proc prepareLibFarm*(cfg: Config): tuple[ok: bool, dir, warning: string] =
  const disabled = "empty-test enforcement disabled: "
  let libDir = resolveNimLib(cfg)
  if libDir.len == 0:
    return (false, "", disabled & "could not resolve the nim lib dir via '" &
            cfg.nimBin & " dump'")
  let unittestPath = libDir / "pure" / "unittest.nim"
  var source: string
  try:
    source = readFile(unittestPath)
  except IOError:
    return (false, "", disabled & "cannot read " & unittestPath)
  let overlay = patchUnittest(source)
  if overlay.len == 0:
    return (false, "", disabled & unittestPath &
            " does not match the expected layout; set allow_empty_tests = true to silence")
  result.dir = cfg.cacheDir / "libfarm"
  let stampPath = cfg.cacheDir / "libfarm.stamp"
  let stamp = libDir & "\n" & $OverlayVersion
  let overlayPath = result.dir / "pure" / "unittest.nim"
  # rebuild only when stale; stable overlay mtime keeps nimcaches valid
  let fresh =
    fileExists(stampPath) and readFile(stampPath) == stamp and
    fileExists(overlayPath) and readFile(overlayPath) == overlay
  if not fresh:
    try:
      createDir(cfg.cacheDir)
      buildFarm(libDir, result.dir, overlay)
      writeFile(stampPath, stamp)
    except OSError as e:
      return (false, "", disabled & "cannot build lib overlay: " & e.msg)
  result.ok = true
