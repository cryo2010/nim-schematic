switch("path", "$projectDir/../src")

# The reference prototype relies on Nim's `--mm:refc`. Nim 2.2.x's ORC memory
# manager currently miscompiles the library's deeply-nested generic closures
# (see DESIGN.md, "Known limitation: ORC"). refc and markAndSweep are correct.
switch("mm", "refc")
