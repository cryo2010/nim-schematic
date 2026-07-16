# nim-tailor — design

A minimalist object-validation and JSON-parsing library for Nim, borrowing the
best ideas from [Zod](https://zod.dev) (TypeScript) and
[Pydantic](https://docs.pydantic.dev) (Python).

The goal: **define a schema once, and get both runtime validation and a
statically-typed Nim value out of it** — with an API small enough to hold in
your head.

```nim
import nim_tailor

let user = schema:
  name:  string.min(2).max(50)
  age:   int.min(0).max(150)
  email: string.email.optional
  tags:  string.array.default(@[])

type User = Infer(user)        # tuple[name: string, age: int,
                               #       email: Option[string], tags: seq[string]]

let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io"}""")
echo u.name                    # statically typed, no casts, no `JsonNode`
```

---

## 1. What we borrow, and why

| Idea | From | How it appears here |
| --- | --- | --- |
| Schema is a first-class value; parsing and validation are one step | Zod | `Schema[T]`, `parse` |
| **Static type inference from a schema** (`z.infer`) | Zod | `Infer(schema)` |
| Fluent, chainable refinements | Zod | `.min().max().email()` |
| Composable modifiers that change the type | Zod | `.optional` → `Option[T]`, `.array` → `seq[T]` |
| Safe parse vs. throwing parse | Zod | `tryParse` / `parse` |
| **Accumulate every error, not just the first** | Pydantic | `ParseResult.issues: seq[Issue]` |
| Errors carry a **path** to the offending value | Pydantic | `Issue.path` (`owner.address.city`, `tags[2]`) |
| Coercion / defaults / enums | both | `.default(x)`, `.oneOf([...])` |

## 2. The core insight: inference, inverted

Zod's headline feature is `type X = z.infer<typeof Schema>`. It exists because
TypeScript has **no runtime types** — Zod builds a runtime schema object and
then *reconstructs* a compile-time type from it via conditional types.

Nim has the opposite situation: it has real, first-class compile-time types.
So we can do the same thing far more directly.

Every schema value has type `Schema[T]`, where **`T` is exactly the type the
schema produces on success**:

```nim
str()                       # Schema[string]
integer().min(0)            # Schema[int]
str().optional              # Schema[Option[string]]
str().array                 # Schema[seq[string]]
```

The type flows automatically through the combinators, because each combinator's
*return type* encodes the transformation:

```nim
proc optional*[T](s: Schema[T]): Schema[Option[T]]
proc array*[T]   (s: Schema[T]): Schema[seq[T]]
proc min*        (s: Schema[int], n: int): Schema[int]
```

Recovering the type is then a one-line macro that reads the generic argument
back off the value's type:

```nim
macro Infer*(s: typed): untyped =
  getTypeInst(s)[1]         # Schema[T]  ->  T
```

For object schemas, the `schema:` macro builds a **named tuple** type whose
field types are inferred from each field's schema expression — so
`Infer(user)` is `tuple[name: string, age: int, ...]`. No manual type
declaration, no drift between schema and type.

> Nim shares one namespace for types and values, so (unlike TypeScript) the
> schema value and the inferred type must have different names. The convention
> is a lowercase value and a capitalized type: `let user = ...` / `type User =
> Infer(user)`.

## 3. Architecture

Everything is built from one tiny type:

```nim
type Schema*[T] = object
  run*: proc(j: JsonNode, ctx: var Ctx): T {.closure.}
```

A schema is just "a function from JSON to `T` that may record issues in a
context". Three layers sit on top:

**Primitives** produce a leaf value and type-check the JSON node:
`str()`, `integer()`, `number()`, `boolean()`.

**Refinements** wrap a schema of the *same* type with an extra predicate. They
are all one helper:

```nim
proc refine*[T](s: Schema[T], message: string, ok: proc(v: T): bool): Schema[T]
```

`min`, `max`, `nonempty`, `email`, `oneOf`, ... are two-line calls to `refine`.
A refinement is **skipped if the inner parse already failed**, so you never see
`"must be a valid email"` stacked on top of `"expected string"`.

**Modifiers & combinators** change the type: `optional` (→ `Option[T]`),
`default(d)` (keeps `T`, substitutes on null/missing), `array` (→ `seq[T]`),
and the `schema:` object macro (→ named tuple).

### The object DSL

```nim
schema:
  name: string.min(2)
  age:  int
```

The macro:

1. Rewrites bare type names inside the DSL so `string` reads as `str()`,
   `int` as `integer()`, etc. (`dslRewrite`). This is purely cosmetic sugar;
   outside the macro you call the constructors directly.
2. Binds each field's schema expression to a local (`let`), and derives the
   tuple field type from it via `typeof`.
3. Generates a single `run` closure that, for each field, descends the error
   path, pulls the field's JSON node (missing keys become `null` uniformly),
   and assigns the typed result into the tuple.

Because the per-field parsing code is *generated at compile time*, it is fully
typed and monomorphic — there is no runtime reflection.

### Errors

Parsing threads a `Ctx { path, issues }`. On a problem, a schema appends an
`Issue { path, message }` and returns a zero value, letting sibling fields
continue — so one `tryParse` reports *all* problems at once, each with a path:

```
name: must be at least 2 chars
age: must be <= 150
role: must be one of admin, user
```

Two entry points:

- `tryParse(schema, json) -> ParseResult[T]` — never raises; inspect
  `.ok` / `.value` / `.issues`. (Zod's `safeParse`.)
- `parse(schema, json) -> T` — returns `T` or raises `ValidationError`
  (which still carries the full `issues` seq). (Zod's `parse`.)

Both accept either a `JsonNode` or a raw JSON `string`.

## 4. API surface

```
Constructors : str  integer  number  boolean
Refinements  : min  max  nonempty  email  oneOf  refine
Modifiers    : optional  default  array
Objects      : schema:  (DSL)      Infer(schema)
Parsing      : parse  tryParse     (JsonNode or string)
Errors       : Issue  ValidationError  ParseResult
```

That is the whole library. New constraints are one call to `refine`; new
container types are one small combinator returning `Schema[...]`.

## 5. Design decisions & trade-offs

- **Type-inference direction.** We could have gone "type-first" (annotate a Nim
  `object` and derive a parser, like Pydantic derives from class fields). We
  chose "schema-first" because it reproduces Zod's inference story, keeps
  validation constraints and the type in one place, and composes better
  (`.optional`, unions, arrays). A type-first `fromJson[T]` adapter could be
  added later for people who already have their types.

- **Accumulate vs. fail-fast.** We accumulate (Pydantic) rather than throw on
  the first error (naive Zod), because for JSON-from-the-wire "here is
  everything wrong" is far more useful than "the first thing wrong".

- **Generated code, not reflection.** The object macro emits typed field
  assignments, so parsing is monomorphic and allocation-light; the cost is that
  object schemas are a macro rather than a plain value.

- **Minimal core.** `refine` is the single extension point for constraints, so
  the primitive/refinement surface stays tiny and everything is uniform.

## 6. Roadmap (not in the prototype)

- Unions / discriminated unions (`oneOfSchema(a, b)` → `object variant`), and
  literal singletons.
- Coercion mode (`string` → `int`, etc.) à la Pydantic's lax mode.
- `transform` (post-parse mapping) and `refineAsync`-style effectful checks.
- `table` / `Table[K, V]` combinator; `regex` via `std/re`.
- Serialization: derive `toJson` from the same schema.
- A type-first adapter that reads an existing `object`/`enum`.

## 7. Known limitation: ORC memory manager

The prototype **must be compiled with `--mm:refc`** (set in `nim.cfg` and
`tests/config.nims`). Under Nim 2.2.x's default `--mm:orc`, the library
SIGSEGVs at runtime.

This is a **compiler codegen bug, not a design flaw** — the same source is
correct under `--mm:refc` and `--mm:markAndSweep`. It was isolated as follows:

- Object schemas build a `run` closure that **captures several sub-schema
  closures** and threads a `var Ctx`.
- Under ORC, the moment that closure **mutates a `seq` reachable through the
  captured `ctx`** (e.g. pushing an error path) *before* invoking a captured
  sub-schema closure, the sub-schema's own captured environment is read as
  `nil` — its refcount has been dropped incorrectly.
- Reproducible with a hand-written equivalent (no macros involved); disappears
  entirely under `refc`/`markAndSweep`; unaffected by `--opt`, `--exceptions`,
  or `--cursorInference` flags.

The design is independent of this: it only assumes closures capture correctly,
which they do under every memory manager except the current ORC. The proper
fixes are (a) an upstream ORC fix, or (b) re-expressing the validator as a
`ref`-object AST walked by a single non-capturing interpreter, which sidesteps
bulk closure capture at the cost of some of the elegance shown above. That
rewrite is noted here rather than done, to keep the prototype a faithful
illustration of the intended API.
