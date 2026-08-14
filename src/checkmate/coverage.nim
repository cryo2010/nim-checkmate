## Test coverage via gcov-style instrumentation.
##
## LLVM source-based coverage (-fcoverage-mapping) maps regions to the
## generated C files in nimcache, which is useless for Nim. gcov
## instrumentation (--coverage) builds its line table from debug info,
## which honors the #line directives emitted by --lineDir:on, so reports
## reference real .nim sources (verified empirically on this toolchain).
##
## .gcda files land next to the objects in .checkmate/nimcache/<slug>/;
## loop iterations accumulate counts automatically. We run `llvm-cov gcov`
## per slug dir, parse the .gcov outputs, and merge line hits across all
## test binaries (a line is covered if any binary executed it).

import std/[algorithm, os, osproc, strutils, tables]
import ./config

proc covCompileFlags*(): seq[string] =
  @["--lineDir:on", "--passC:--coverage", "--passL:--coverage"]

proc covClean*(cfg: Config) =
  ## Drop counts from previous runs so the report reflects this run only.
  let ncRoot = cfg.cacheDir / "nimcache"
  if not dirExists(ncRoot): return
  for path in walkDirRec(ncRoot, yieldFilter = {pcFile}):
    if path.endsWith(".gcda"):
      removeFile(path)

proc gcovCmd(): string =
  if findExe("xcrun").len > 0: "xcrun llvm-cov gcov"
  elif findExe("llvm-cov").len > 0: "llvm-cov gcov"
  elif findExe("gcov").len > 0: "gcov"
  else: ""

type CovLines = Table[string, Table[int, bool]]  # file -> line -> executed

proc parseGcovFile(path: string, into: var CovLines, projectRoot, cacheDir: string) =
  var source = ""
  var keep = false
  for line in lines(path):
    let parts = line.split(':', maxsplit = 2)
    if parts.len < 3: continue
    let count = parts[0].strip
    let lineNo = try: parseInt(parts[1].strip) except ValueError: -1
    if lineNo == 0 and parts[2].startsWith("Source:"):
      source = parts[2][len("Source:") .. ^1]
      if not isAbsolute(source):
        source = projectRoot / source
      source = normalizedPath(source)
      # only project sources; never the cache (inject module, generated files)
      keep = source.startsWith(projectRoot & $DirSep) and
             not source.startsWith(cacheDir & $DirSep)
      if keep and not into.hasKey(source):
        into[source] = initTable[int, bool]()
      continue
    if not keep or lineNo <= 0 or count == "-": continue
    let executed = count != "#####" and count != "====="
    into[source][lineNo] = into[source].getOrDefault(lineNo, false) or executed

proc covReport*(cfg: Config): bool =
  ## Prints a per-file coverage table; returns false if no data was found.
  let tool = gcovCmd()
  if tool.len == 0:
    stderr.writeLine "checkmate: coverage: no gcov tool found (need xcrun, llvm-cov or gcov)"
    return false
  var merged: CovLines
  let ncRoot = cfg.cacheDir / "nimcache"
  # gcov must run from the project root: Nim emits #line paths relative to
  # the compile cwd, and llvm-cov gcov silently writes empty reports when it
  # cannot open the source file. Snapshot pre-existing *.gcov so only ours
  # are cleaned up.
  var preexisting: seq[string]
  for f in walkFiles(cfg.projectRoot / "*.gcov"):
    preexisting.add f
  for kind, slugDir in walkDir(ncRoot):
    if kind != pcDir: continue
    var cmd = tool
    var found = false
    for f in walkFiles(slugDir / "*.gcda"):
      cmd.add " " & quoteShell(f)
      found = true
    if not found: continue
    discard execCmdEx(cmd, workingDir = cfg.projectRoot)
    for gcovFile in walkFiles(cfg.projectRoot / "*.gcov"):
      if gcovFile in preexisting: continue
      parseGcovFile(gcovFile, merged, cfg.projectRoot, cfg.cacheDir)
      removeFile(gcovFile)
  if merged.len == 0:
    stderr.writeLine "checkmate: coverage: no coverage data produced"
    return false

  var files = newSeq[string]()
  for f in merged.keys: files.add f
  files.sort
  var totalCovered, totalLines = 0
  echo ""
  echo "Coverage (executed lines):"
  for f in files:
    var covered, total = 0
    for _, hit in merged[f]:
      inc total
      if hit: inc covered
    totalCovered += covered
    totalLines += total
    let pct = if total > 0: 100.0 * covered.float / total.float else: 0.0
    echo "  ", relativePath(f, cfg.projectRoot).alignLeft(44), " ",
         formatFloat(pct, ffDecimal, 1).align(5), "%  (", covered, "/", total, ")"
  let totalPct = if totalLines > 0: 100.0 * totalCovered.float / totalLines.float else: 0.0
  echo "  ", "TOTAL".alignLeft(44), " ",
       formatFloat(totalPct, ffDecimal, 1).align(5), "%  (", totalCovered, "/", totalLines, ")"
  true
