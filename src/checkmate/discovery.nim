## Test file discovery: walk configured dirs, match filename globs,
## apply excludes, honor explicit CLI paths.

import std/[os, algorithm, sequtils, strutils]
import ./config

type
  TestFile* = object
    absPath*: string
    relPath*: string   # relative to project root, '/' separators
    slug*: string      # relPath with separators -> "__", ".nim" stripped

proc globMatch*(s, pattern: string): bool =
  ## Minimal glob: `*` matches any run of characters (including '/'),
  ## `?` matches exactly one character.
  proc gm(s: string, si: int, p: string, pi: int): bool =
    if pi == p.len:
      return si == s.len
    case p[pi]
    of '*':
      for k in si .. s.len:
        if gm(s, k, p, pi + 1):
          return true
      false
    of '?':
      si < s.len and gm(s, si + 1, p, pi + 1)
    else:
      si < s.len and s[si] == p[pi] and gm(s, si + 1, p, pi + 1)
  gm(s, 0, pattern, 0)

proc toTestFile*(cfg: Config, path: string): TestFile =
  let absPath = absolutePath(path)
  var rel = relativePath(absPath, cfg.projectRoot)
  when DirSep != '/':
    rel = rel.replace($DirSep, "/")
  var slug = rel
  slug.removeSuffix(".nim")
  slug = slug.replace("/", "__")
  TestFile(absPath: absPath, relPath: rel, slug: slug)

proc excluded(cfg: Config, relPath: string): bool =
  cfg.exclude.anyIt(globMatch(relPath, it))

proc walkTestDir(cfg: Config, dir: string, into: var seq[TestFile]) =
  for path in walkDirRec(dir, yieldFilter = {pcFile}):
    if globMatch(extractFilename(path), cfg.pattern):
      let tf = toTestFile(cfg, path)
      if not cfg.excluded(tf.relPath):
        into.add tf

proc discoverTests*(cfg: Config, cliPaths: seq[string]): seq[TestFile] =
  ## Without cliPaths: walk cfg.dirs with pattern + exclude.
  ## Explicit file args are included verbatim; dir args are walked.
  if cliPaths.len == 0:
    for d in cfg.dirs:
      let dir = if isAbsolute(d): d else: cfg.projectRoot / d
      if dirExists(dir):
        cfg.walkTestDir(dir, result)
  else:
    for p in cliPaths:
      if fileExists(p):
        result.add cfg.toTestFile(p)
      elif dirExists(p):
        cfg.walkTestDir(p, result)
      else:
        raise newException(UsageError, "no such file or directory: " & p)
  result = result.deduplicate
  result.sort proc(a, b: TestFile): int = cmp(a.relPath, b.relPath)
