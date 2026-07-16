# schematic

[![CI](https://github.com/cryo2010/nim-schematic/actions/workflows/ci.yml/badge.svg)](https://github.com/cryo2010/nim-schematic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A object validation library with type inference for Nim. Define a schema once and get **both** runtime validation and a statically typed Nim value out of it, with the inferred type coming straight from the schema.

- **Schema-first with real type inference.** `Infer(schema)` gives you a nominal Nim `object` type derived from the schema, so the schema and the type never drift apart.
- **Fluent, chainable refinements:** `min`, `max`, `nonempty`, `email`, `oneOf`, and custom `refine` predicates.
- **Type-changing modifiers:** `optional` produces `Option[T]`, `array` produces `seq[T]`, `default` fills in missing values.
- **Nested and recursive (tree) schemas** via `lazy` and the `schema(T):` form.
- **Errors accumulate with paths.** One parse reports every problem at once, each tagged with a path like `owner.address.city` or `tags[2]`.
- **Safe and raising entry points**, plus re-validation of already-built values.

## Install

```nim
nimble install schematic
```

## Quick Start

Describe your data with the `schema` DSL, recover the type with `Infer`, and parse straight into it:

```nim
import schematic

let user = schema:
  name:  string.min(2).max(50)
  age:   int.min(0).max(150)
  email: string.email.optional          # -> Option[string]
  tags:  string.array.default(@[])       # -> seq[string]

type User = Infer(user)
# object: name: string, age: int, email: Option[string], tags: seq[string]

let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io"}""")
echo u.name          # "Ada", a statically typed field (no JsonNode, no casts)
```

`schematic` re-exports `std/json` and `std/options`, so `JsonNode`, `Option`, `some`, and `none` are available just by importing it.

### Basic Examples

**Parse and validate** (raises `ValidationError` on bad input):

```nim
let u = user.parse("""{"name":"Ada","age":36}""")
echo u.tags.len      # 0, the default was applied
```

**Safe parsing** (never raises; inspect the result):

```nim
let r = user.tryParse("""{"name":"A","age":999,"email":"nope"}""")
if r.ok:
  use(r.value)
else:
  for issue in r.issues:
    echo issue
# name: must be at least 2 chars
# age: must be <= 150
# email: must be a valid email
```

**Recursive (tree) schemas.** Declare the recursive type yourself and use the `schema(T):` form with `lazy` for the self-reference:

```nim
type Comment = object
  text*:    string
  replies*: seq[Comment]

var comment: Schema[Comment]
comment = schema(Comment):
  text:    string.min(1)
  replies: lazy(comment).array.default(@[])   # leaves may omit `replies`

let tree = comment.parse(payload)             # arbitrarily deep; paths like replies[0].text
```

## Complex Example

A single schema pulling in most of the library at once: nested objects, arrays of objects, optionals, defaults, enums, length/email/regex/custom refinements, a plain type validated with `schemaOf`, a recursive comment thread, and type inference. The runnable version lives at [`examples/complex.nim`](examples/complex.nim).

```nim
import schematic
import std/strutils   # for the custom refine predicates

# A plain type we validate structurally with `schemaOf` (no custom rules).
type GeoPoint = object
  lat*: float
  lng*: float

# A recursive (tree) type: a comment with nested replies.
type Comment = object
  author*:  string
  body*:    string
  replies*: seq[Comment]

var comment: Schema[Comment]
comment = schema(Comment):
  author:  string.min(1)
  body:    string.min(1).max(2000)
  replies: lazy(comment).array.default(@[])   # leaves may omit `replies`

# Reusable nested schemas, composed by value into the top-level schema.
let owner = schema:
  name:  string.min(2).max(50)
  email: string.email
  age:   int.min(0).max(150).optional          # -> Option[int]

let member = schema:
  name: string.min(1)
  role: string.oneOf(["admin", "maintainer", "viewer"])

# The top-level schema, inference-first.
let project = schema:
  name:       string.min(1).max(100)
  slug:       string.refine("must be kebab-case", proc(v: string): bool =
                v.len > 0 and v.allCharsInSet({'a'..'z', '0'..'9', '-'}))
  version:    string.pattern(r"\d+\.\d+\.\d+")   # regex refinement
  visibility: string.oneOf(["public", "private", "internal"]).default("private")
  stars:      int.min(0).default(0)
  location:   schemaOf(GeoPoint).optional       # optional plain-type field
  owner:      owner                             # nested inferred object
  members:    member.array.default(@[])         # array of nested objects
  tags:       string.array.default(@[])
  thread:     comment.optional                  # optional recursive tree

# The inferred Nim type, straight from the schema.
type Project = Infer(project)

let p: Project = project.parse(payload)
echo p.owner.email                              # statically typed access
echo p.thread.get.replies[0].author            # deep into the recursive tree
```

Anything omitted falls back to its `default`/`optional`, and one `tryParse` on an invalid payload reports every problem at once, each with a path into the nested/array/recursive structure:

```
9 validation issue(s):
  - name: must be at least 1 chars
  - slug: must be kebab-case
  - version: must match pattern \d+\.\d+\.\d+
  - visibility: must be one of public, private, internal
  - owner.name: must be at least 2 chars
  - owner.email: must be a valid email
  - members[0].role: must be one of admin, maintainer, viewer
  - thread.author: must be at least 1 chars
  - thread.replies[0].body: must be at least 1 chars
```

## API

Every combinator returns a `Schema[T]`, where `T` is exactly the type produced on success. Refinements and modifiers thread that type through automatically.

**Constructors**

| Call | Produces |
| --- | --- |
| `str()` | `Schema[string]` |
| `integer()` | `Schema[int]` |
| `number()` | `Schema[float]` |
| `boolean()` | `Schema[bool]` |
| `json()` | `Schema[JsonNode]` (any JSON value, passed through unchanged) |

**Refinements** (keep the type; skipped if the inner value already failed)

| Call | Applies to | Checks |
| --- | --- | --- |
| `min(n)` / `max(n)` | int, float | numeric bound |
| `min(n)` / `max(n)` | string, seq | length bound |
| `nonempty` | string | non-empty |
| `email` | string | structural email shape |
| `pattern(re)` | string | whole string matches regex `re` (via the `regex` package) |
| `oneOf(choices)` | string | value is one of `choices` |
| `refine(message, pred)` | any | custom `proc(v: T): bool` |

**Modifiers**

| Call | Effect |
| --- | --- |
| `optional` | missing/`null` becomes `none`; type becomes `Option[T]` |
| `default(d)` | missing/`null` becomes `d`; type stays `T` |
| `array` | matches a JSON array; type becomes `seq[T]` |
| `lazy(schemaVar)` | defers a reference to a schema for recursion |

**Objects and inference**

| Form | Purpose |
| --- | --- |
| `schema:` | build an object schema and infer its `object` type |
| `schema(T):` | build a schema for an existing type `T` (your own or recursive); fields you don't list are auto-derived structurally (required and type-checked) |
| `schemaOf(T)` | auto-derive a structural schema from a type `T` (every field required and type-checked; non-recursive types) |
| `Infer(schema)` | recover the produced type: `type User = Infer(user)` |

**Parsing** (each accepts a `JsonNode` or a JSON `string`)

| Call | Behaviour |
| --- | --- |
| `parse(schema, data): T` | validate and return `T`, or raise `ValidationError` |
| `tryParse(schema, data): ParseResult[T]` | never raises; inspect `.ok` / `.value` / `.issues` |

**Re-validation.** Constraints run at parse time and the result is a plain
object, so later field assignment is unchecked. Re-check a value on demand:

| Call | Behaviour |
| --- | --- |
| `validate(schema, value: T): T` | re-validate an existing value, raising on failure |
| `tryValidate(schema, value: T): ParseResult[T]` | re-validate without raising |

**Error types**

| Type | Fields |
| --- | --- |
| `Issue` | `path`, `message` |
| `ValidationError` | `issues: seq[Issue]` (raised by `parse` / `validate`) |
| `ParseResult[T]` | `ok`, `value`, `issues` |

## Thanks

schematic borrows its best ideas from projects that proved them first.

- **[Zod](https://zod.dev)** - schema-first design and the `z.infer` type inference this library mirrors, plus the safe-vs-throwing parse split.
- **[Pydantic](https://docs.pydantic.dev)** - accumulating every validation error at once, each carrying a path to the offending field.

## License

MIT
