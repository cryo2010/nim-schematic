# Package

version       = "0.6.0"
author        = "Craig Younker"
description   = "Object validation with type inference"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.10"
requires "regex >= 0.20.0"


# Tasks

task valgrind, "Run the test suite under valgrind (Linux only; set VALGRIND_MM=arc|orc to pick one)":
  # Local convenience only. CI runs these commands directly: nimble does not
  # propagate a failing exit code from a task, so `nimble valgrind` cannot be
  # used as a CI gate (watch the output when running this by hand).
  # -d:useMalloc routes Nim's allocations through malloc/free so valgrind can
  # see them; without it the custom allocator hides errors and leaks.
  let only = getEnv("VALGRIND_MM")
  for mm in ["arc", "orc"]:
    if only.len > 0 and only != mm: continue
    echo "== valgrind (--mm:" & mm & ")"
    exec "nim c --hints:off --mm:" & mm & " -d:useMalloc --debugger:native " &
         "-o:tests/test_valgrind tests/test_schematic.nim"
    exec "valgrind --leak-check=full --errors-for-leak-kinds=definite " &
         "--error-exitcode=1 ./tests/test_valgrind"
