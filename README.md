# schematic

[![CI](https://github.com/cryo2010/nim-schematic/actions/workflows/ci.yml/badge.svg)](https://github.com/cryo2010/nim-schematic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A object validation library with type inference for Nim, inspired by [Zod](https://zod.dev). Define a schema once and get **both** runtime validation and a statically typed Nim value out of it, with the inferred type coming straight from the schema.

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

let payload = %*{"name": "Ada", "age": 36, "email": "ada@x.io"}
let u = user.parse(payload)   # parse a JsonNode (or pass a raw string)
echo u.name          # "Ada", a statically typed field (no JsonNode, no casts)
```

`schematic` re-exports `std/json` and `std/options`, so `JsonNode`, `%*`, `Option`, `some`, and `none` are available just by importing it. `parse` accepts either a `JsonNode` or a raw JSON string.

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

**Ref objects.** The type-first forms (`schemaOf(T)`, `schema(T):`, `discriminated(T, field)`) accept a `ref object` too. Parsing allocates the ref and fills it; `Infer` recovers the `ref` type. A missing required field raises, exactly as for a value object:

```nim
type User = ref object
  name*: string
  age*:  int

let user = schema(User):
  name: string.min(2)
  age:  int.min(0)

let u = user.parse("""{"name":"Ada","age":36}""")   # u is a non-nil `User` ref
echo u.name

type U = Infer(user)                                 # U is the ref type `User`
```

The `schema:` inference form always produces a value `object`, and object algebra (`pick`/`omit`/...) derives value-object types; ref support is limited to the type-first forms above.

**Enums.** `enumOf(T)` matches a JSON string against the members of a Nim `enum` and parses it straight into `T`. Enum-typed fields are also picked up automatically by `schemaOf` and `schema(T):`:

```nim
type Status = enum stActive = "active", stPaused = "paused", stArchived = "archived"

let ticket = schema:
  status: enumOf(Status)               # JSON string -> Status
  note:   string.optional

let t = ticket.parse("""{"status":"paused"}""")
echo t.status                          # stPaused
```

The JSON string is matched against each member's `$` form, so explicit values (`stActive = "active"`) control the JSON names; a member without one uses its identifier. An unknown value reports `must be one of active, paused, archived`.

**Discriminated unions.** Declare a Nim variant object (with an enum discriminator) and `discriminated(T, field)` dispatches on the tag and builds the right branch:

```nim
type
  ShapeKind = enum skCircle = "circle", skSquare = "square"
  Shape = object
    label*: string                  # shared by every branch
    case kind*: ShapeKind
    of skCircle: radius*: float
    of skSquare: side*:   float

let shape = discriminated(Shape, kind)
let s = shape.parse("""{"kind":"circle","label":"c","radius":2.0}""")
echo s.radius                        # 2.0; s.kind == skCircle
```

The JSON tag is matched against each enum value's string form (`$value`), so give the enum explicit string values (`skCircle = "circle"`) for clean names.

**Strict objects.** By default extra keys pass validation and are dropped. Add `strict` to reject them instead, one issue per undeclared key. It applies to that object level only, so nested objects keep their own strictness:

```nim
let account = schema:
  id:   string
  name: string

let strict = account.strict
strict.tryParse("""{"id":"1","name":"A","role":"admin"}""").issues
# @[role: unexpected key]
```

`strict` also works on a discriminated union, where the allowed keys are the discriminator plus the selected branch's fields.

**Object algebra.** Derive new object schemas (each with its own inferred type) from existing ones, like Zod's `.pick`/`.omit`/`.partial`/`.merge`/`.extend`:

```nim
let user = schema:
  name:  string.min(2)
  age:   int.min(0)
  email: string.email.optional

let credentials = pick(user, name, email)   # keep only name, email
let publicUser  = omit(user, email)         # drop email
let userPatch   = partial(user)             # every field Option[...]

let admin = extend(user):                   # add fields via the DSL
  role: string.oneOf(["admin"])
```

**Maps.** `record` matches an object with arbitrary keys, validating every value against the same schema; the field type becomes `Table[string, V]`:

```nim
let quotas = schema:
  limits: record(integer().min(0))            # -> Table[string, int]

let q = quotas.parse("""{"limits":{"cpu":4,"mem":8}}""")
echo q.limits["cpu"]                          # 4
```

**Field aliases.** When the JSON key differs from the Nim field name, `alias` reads (and reports errors) under the JSON key while keeping the field name:

```nim
let creds = schema:
  apiKey: string.min(1).alias("api_key")      # field apiKey <- JSON "api_key"

let c = creds.parse("""{"api_key":"secret"}""")
echo c.apiKey                                 # "secret"
```

**String formats.** Built-in refinements for common shapes, plus `timestamp` for Unix-seconds to `times.Time`:

```nim
let event = schema:
  id:      string.uuid
  day:     string.date                        # ISO date, kept as a string
  created: timestamp()                        # -> times.Time from Unix seconds

let e = event.parse("""
  {"id":"12345678-1234-1234-1234-123456789abc","day":"2026-07-16","created":1700000000}
""")
```

**JSON Schema.** Emit a JSON Schema (draft 2020-12) document from any schema:

```nim
import std/json
echo toJsonSchema(event).pretty
```

**Coercion** is opt-in and strict by default. Add `.coerce` to a scalar to accept convertible JSON; refinements still run on the coerced value:

- **number/integer**: numeric strings and whole floats (`"36"`, `36.0`).
- **boolean**: `"true"`/`"false"` (case-insensitive), and `0`/`"0"` → false, any positive int / `"1"` → true.
- **string**: any scalar to its string form (`42` → `"42"`).

```nim
let form = schema:
  age:    integer().min(0).coerce   # accepts 36 or "36"
  active: boolean().coerce          # accepts true, "true", 1, "0", ...

echo form.parse("""{"age":"36","active":1}""").active   # true
```

**Tuples.** `tup` reads a fixed-length JSON array into a positional tuple; `namedTuple` reads a JSON object into a named tuple:

```nim
let route = schema:
  origin: tup(number(), number())                    # [lat, lng] -> (float, float)
  dest:   namedTuple(lat = number(), lng = number()) # {lat, lng} -> tuple[lat, lng]

let r = route.parse("""
  {"origin":[40.7,-74.0],"dest":{"lat":34.0,"lng":-118.2}}""")
echo r.origin[0], " -> ", r.dest.lat               # positional and named access
```

## Complex Example

A single schema pulling in most of the library at once: nested objects, arrays of objects, optionals, defaults, enums, length/email/regex/custom refinements, a plain type validated with `schemaOf`, a recursive comment thread, an arbitrary JSON passthrough, a discriminated union, and type inference. The runnable version lives at [`examples/complex.nim`](examples/complex.nim).

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
  metadata:   JsonNode.optional                 # arbitrary passthrough JSON

# The inferred Nim type, straight from the schema.
type Project = Infer(project)

let p: Project = project.parse(payload)
echo p.owner.email                              # statically typed access
echo p.thread.get.replies[0].author            # deep into the recursive tree
echo p.metadata.get["team"]                     # arbitrary JSON, kept as a JsonNode
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

A discriminated union nests inside an object schema like any other schema value. Declare the variant object, build its schema with `discriminated`, and compose it:

```nim
type
  DeployKind = enum dkStatic = "static", dkContainer = "container"
  Deploy = object
    env*: string                         # shared by every branch
    case kind*: DeployKind
    of dkStatic: dir*: string
    of dkContainer:
      image*: string
      port*:  int

let deploy = discriminated(Deploy, kind)

let service = schema:
  name:   string
  deploy: deploy.optional              # nested discriminated union
let s = service.parse("""{"name":"web","deploy":{"kind":"container","env":"prod","image":"app:1.2","port":8080}}""")
echo s.deploy.get.image                # "app:1.2"; s.deploy.get.kind == dkContainer
```

## API

Every combinator returns a `Schema[T]`, where `T` is exactly the type produced on success. Refinements and modifiers thread that type through automatically.

**Objects and inference**

| Form | Purpose |
| --- | --- |
| `schema:` | build an object schema and infer its `object` type |
| `schema(T):` | build a schema for an existing type `T` (your own or recursive); fields you don't list are auto-derived structurally (required and type-checked) |
| `schemaOf(T)` | auto-derive a structural schema from a type `T` (every field required and type-checked; non-recursive types) |
| `enumOf(T)` | schema for a Nim `enum` `T`: a JSON string matched against the members (`$` form) and parsed into `T` |
| `discriminated(T, field)` | discriminated union over a variant object `T`, dispatching on the enum `field` |
| `Infer(schema)` | recover the produced type: `type User = Infer(user)` |

**Constructors**

| Call | Produces |
| --- | --- |
| `str()` | `Schema[string]` |
| `integer()` | `Schema[int]` |
| `integer(T)` | `Schema[T]` for any integer type, with `T`'s range enforced: `integer(uint16)` rejects values outside `0..65535` |
| `number()` | `Schema[float]` |
| `number(T)` | `Schema[T]` for `float32`/`float64` |
| `boolean()` | `Schema[bool]` |
| `json()` | `Schema[JsonNode]` (any JSON value, passed through unchanged) |
| `timestamp()` | `Schema[Time]` (Unix seconds from a JSON integer) |

**Tuples** (compose child schemas into a tuple type)

| Call | Produces |
| --- | --- |
| `tup(a, b, ...)` | positional tuple from a JSON array; type becomes `(A, B, ...)` |
| `namedTuple(x = a, y = b)` | named tuple from a JSON object; type becomes `tuple[x: A, y: B]` |

**Refinements** (keep the type; skipped if the inner value already failed)

| Call | Applies to | Checks |
| --- | --- | --- |
| `min(n)` / `max(n)` | any integer or float schema | numeric bound |
| `min(n)` / `max(n)` | string, seq | length bound |
| `nonempty` | string | non-empty |
| `email` | string | structural email shape |
| `pattern(re)` | string | whole string matches regex `re` (via the `regex` package) |
| `uuid` | string | is a UUID |
| `date` | string | is an ISO date `YYYY-MM-DD` (kept as a string) |
| `datetime` | string | is an ISO 8601 date-time (kept as a string) |
| `oneOf(choices)` | string | value is one of `choices` |
| `refine(message, pred)` | any | custom `proc(v: T): bool` |

**Modifiers**

| Call | Effect |
| --- | --- |
| `optional` | missing/`null` becomes `none`; type becomes `Option[T]` |
| `default(d)` | missing/`null` becomes `d`; type stays `T` |
| `array` | matches a JSON array; type becomes `seq[T]` |
| `strict` | on an object or union schema, reject undeclared keys instead of ignoring them (this level only) |
| `record` | matches an object with arbitrary keys; type becomes `Table[string, V]` |
| `alias(key)` | read/write this field under a different JSON `key` |
| `coerce` | coerce a convertible JSON scalar to the target primitive before validating (opt-in) |
| `lazy(schemaVar)` | defers a reference to a schema for recursion |

**Object algebra** (derive a new object schema, with a new inferred type, from existing ones)

| Call | Result |
| --- | --- |
| `pick(s, a, b)` | keep only fields `a`, `b` |
| `omit(s, a, b)` | drop fields `a`, `b` |
| `partial(s)` | make every field optional (`Option[T]`) |
| `merge(a, b)` | combine two object schemas |
| `extend(s):` block | add new fields (written with the `schema:` DSL) |

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

**Serialization**

| Call | Behaviour |
| --- | --- |
| `toJson(schema, value: T): JsonNode` | serialize a value through the schema: aliased fields are written under their JSON key, tuples as arrays, timestamps as unix seconds |

**JSON Schema**

| Call | Behaviour |
| --- | --- |
| `toJsonSchema(schema): JsonNode` | emit a JSON Schema (draft 2020-12) document for `schema` |

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
