## Lives under the project's srcDir ("lib", deliberately not "src"). A test can
## only import it if checkmate reads srcDir from the .nimble and puts <root>/lib
## on the compile path ahead of installed packages.
proc greet*(name: string): string =
  "hello " & name
