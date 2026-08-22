# Package

version       = "0.3.0"
author        = "Craig Younker"
description   = "A jest-like test runner for Nim"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["checkmate"]


# Dependencies

requires "nim >= 2.0.0"
requires "cligen >= 1.7.0"
requires "parsetoml >= 0.7.0"
requires "regex >= 0.20.0"
