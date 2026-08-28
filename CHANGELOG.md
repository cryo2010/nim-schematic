# Changelog

All notable changes to schematic are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- CI runs the unit tests with the `checkmate` runner (10 loops per memory
  manager with `--bail`, for flake detection), configured by the committed
  `.checkmate.toml`.
- README: added a table of contents (feature and API sections are now real,
  linkable headings), a serialization (`toJson`) example, and an intro
  paragraph positioning schematic as a boundary library.

## [0.6.0] - 2026-07-24

No functional changes: realigns the package version with the release tags
(the nimble version had stayed at 0.3.0 through the 0.4.0 and 0.5.0 tags).

## [0.5.0] - 2026-07-24

### Added
- String formats: `url` (parser-based via `std/uri`), `ipv4`, `ipv6`,
  `hostname`, `e164`, `base64`, `base64url`, `hex(n)`, `ulid`, `nanoid(len)`,
  `jwt`, `semver`, and `slug`, all with the standard `message` override.
- `describe(text)` and `title(text)` metadata modifiers: invisible to
  validation, emitted by `toJsonSchema` (a titled recursive schema names its
  `$defs` entry). The built-in `timestamp()` description became overridable.
- `toJsonSchema` emits JSON Schema `format` names (`uuid`, `date`,
  `date-time`, `uri`, `ipv4`, `ipv6`, `hostname`) alongside patterns.

### Changed
- Examples refreshed to exercise the full feature set, and CI now compiles
  and runs every example on each build.
- CI runs the test suite under valgrind (arc and orc): zero errors, zero
  definite leaks.
- CI steps invoke `nim` directly instead of `nimble`, whose swallowed exit
  codes made failing steps show green.

## [0.4.0] - 2026-07-23

### Added
- Optional `message` overrides on every built-in refinement, e.g.
  `int.min(0, message = "age cannot be negative")`.
- `nullable` modifier: the key must be present but `null` becomes `none(T)`,
  completing the tri-state alongside `optional` (missing and `null` are now
  distinguishable).
- `transform(f[, back])`: post-parse mapping that changes the produced type
  (`Schema[A] -> Schema[B]`); a raising transform reports a normal issue, and
  `back` enables `toJson`/re-validation through the inverse.
- `distinct` types supported in extraction, serialization, and structural
  derivation (e.g. `UserId = distinct string`).
- `literal(v)`: a schema accepting exactly one value (`const` in JSON Schema).
- `oneOfSchema(a, b, ...)`: untagged try-each unions; first clean match wins,
  closest-branch issues reported on no match, `anyOf` in JSON Schema.

### Changed
- **Breaking:** `.coerce` on a non-scalar schema is now a compile-time error,
  and `.coerce` after a `transform` (or doubled) is a build-time `ValueError`;
  both were silent no-ops before.

## [0.3.0] - 2026-07-22

### Added
- Sized numeric constructors: `integer(T)` for any integer type and
  `number(T)` for `float32`/`float64`, with `T`'s own range enforced as
  validation issues and emitted as JSON Schema `minimum`/`maximum`. Bare
  sized type names (`port: uint16.min(1024)`) work in the `schema:` DSL.
- Numeric `min`/`max` became constrained generics taking `n: T`: an
  out-of-range bound literal fails at compile time; an unenforceable
  `uint64` bound raises at schema build.

## [0.2.0] - 2026-07-17

Hardening release. Note: the tag predates the version-bump workflow, so the
package version inside it still reads 0.1.0.

### Added
- `toJson(schema, value)`: schema-driven serialization (aliases written under
  their JSON keys, timestamps as unix seconds, tuples as arrays), also fixing
  `tryValidate`/`validate` round trips.
- `schematicMaxDepth` (default 256, `-d:schematicMaxDepth=N`): validation
  depth limit replacing a stack-overflow crash on deeply nested input.

### Changed
- **Breaking:** string `min`/`max` count unicode characters instead of bytes,
  matching JSON Schema semantics.
- **Breaking:** an invalid `default` value raises `ValueError` when the
  schema is built instead of being silently accepted.
- `strict()` on a schema that does not produce an object is a compile-time
  error instead of a runtime `ValueError`.
- Variant objects are rejected at compile time by `schemaOf`/`schema(T):`
  (pointing at `discriminated`) instead of silently dropping case fields.

### Fixed
- Invalid UTF-8 into regex checks (`pattern`/`uuid`/`date`/`datetime`) no
  longer aborts the process with an `AssertionDefect`.
- Sized integer fields (`int8`, `uint16`, ...) reject out-of-range input as
  issues instead of crashing (`RangeDefect`) or silently wrapping.
- Checks apply to normalized values: refinements after `.default`/`.coerce`
  and `refine` predicates now see the defaulted/coerced value, independent of
  chain order.
- `tryValidate`/`validate` work with aliased fields, `timestamp()` fields,
  and tuple schemas (previously always-failing or non-compiling).
- `toJsonSchema` emits `$defs` references for recursive schemas nested inside
  other schemas instead of an incorrect root `"$ref": "#"`.
- Multi-label `of` branches (`of a, b:`) work in variant objects.
- The email check rejects empty domains and TLDs (`a@.`, `a@b.`).
- String-to-number coercion rejects non-finite results (`"nan"`, `"1e999"`).

## [0.1.0] - 2026-07-16

Initial release: `schema:` DSL with type inference (`Infer`), refinements,
`optional`/`default`/`array`/`strict`/`record`/`alias`/`coerce`/`lazy`,
`schemaOf`/`schema(T):`/`enumOf`/`discriminated`, object algebra
(`pick`/`omit`/`partial`/`merge`/`extend`), tuples, `parse`/`tryParse`,
re-validation, and `toJsonSchema`.

[Unreleased]: https://github.com/cryo2010/nim-schematic/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/cryo2010/nim-schematic/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/cryo2010/nim-schematic/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/cryo2010/nim-schematic/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/cryo2010/nim-schematic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/cryo2010/nim-schematic/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cryo2010/nim-schematic/releases/tag/v0.1.0
