## Compile task construction and inject-module materialization.
##
## The inject source is embedded in the checkmate binary via staticRead and
## written into .checkmate/inject/ at runtime: this works identically for
## nimble install, nimble develop, and a bare copied binary, avoiding any
## resolution of nimble package paths.

import std/[os, strutils]
import ./config, ./discovery

const injectSource = staticRead("injected/checkmate_inject.nim")
const InjectModuleName* = "checkmate_inject"

type
  CompileTask* = object
    tf*: TestFile
    cmd*: string
    binPath*: string
    logPath*: string

proc materializeInject*(cacheDir: string): string =
  ## Returns the inject dir. Writes only when content differs, so the file's
  ## mtime stays stable and nimcaches are not invalidated on every run.
  result = cacheDir / "inject"
  createDir(result)
  let path = result / InjectModuleName & ".nim"
  if symlinkExists(path):
    removeFile(path)  # writeFile follows links; never write through one
  if not fileExists(path) or readFile(path) != injectSource:
    writeFile(path, injectSource)

proc prepareCacheDirs*(cfg: Config) =
  for sub in ["bin", "logs", "events", "nimcache"]:
    createDir(cfg.cacheDir / sub)

proc buildCompileTask*(cfg: Config, tf: TestFile,
                       extraFlags: seq[string] = @[]): CompileTask =
  result.tf = tf
  result.binPath = cfg.cacheDir / "bin" / tf.slug
  result.logPath = cfg.cacheDir / "logs" / tf.slug & ".compile.log"
  var parts = @[
    quoteShell(cfg.nimBin), cfg.backend,
    "--nimcache:" & quoteShell(cfg.cacheDir / "nimcache" / tf.slug),
    "--path:" & quoteShell(cfg.cacheDir / "inject"),
    "--import:" & InjectModuleName,
  ]
  # the project's own source dir, searched before installed packages so a
  # globally-installed copy of this package cannot shadow the code under test
  if cfg.srcPath.len > 0:
    parts.add "--path:" & quoteShell(cfg.srcPath)
  for p in cfg.extraPaths:
    let abs = if isAbsolute(p): p else: cfg.projectRoot / p
    parts.add "--path:" & quoteShell(abs)
  for d in cfg.defines:
    parts.add "-d:" & d
  for f in cfg.nimFlags:
    parts.add f
  for f in extraFlags:
    parts.add f
  parts.add "--colors:off"
  parts.add "--hints:off"
  parts.add "--out:" & quoteShell(result.binPath)
  # relative to projectRoot (the compile task's working dir): checkpoint
  # messages, stack traces, and compile errors then print project-relative
  # paths instead of absolute ones
  parts.add quoteShell(tf.relPath)
  result.cmd = parts.join(" ")
