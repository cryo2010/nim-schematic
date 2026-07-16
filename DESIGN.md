# schematic design

A minimalist object-validation and JSON-parsing library for Nim, borrowing the
best ideas from [Zod](https://zod.dev) (TypeScript) and
[Pydantic](https://docs.pydantic.dev) (Python).

The goal: **define a schema once, and get both runtime validation and a
statically-typed Nim value out of it**, with an API small enough to hold in
your head.

```nim
import schematic

let user = schema:
  name:  string.min(2).max(50)
  age:   int.min(0).max(150)
  email: string.email.optional
  tags:  string.array.default(@[])

type User = Infer(user)        # object: name: string, age: int,
                               #         email: Option[string], tags: seq[string]

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
TypeScript has **no runtime types**, so Zod builds a runtime schema object and
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

For object schemas, the `schema:` macro builds an **object** type whose field
types are inferred from each field's schema expression, so `Infer(user)` is a
nominal `object` with fields `name: string`, `age: int`, ... No manual type
declaration, no drift between schema and type. (An earlier cut synthesized a
structural named *tuple*; an object was chosen for nominal identity (distinct
`User` vs `Point` types you can define procs on) at no extra cost, since the
generic `extract` walks objects and tuples identically via `fieldPairs`.)

> Nim shares one namespace for types and values, so (unlike TypeScript) the
> schema value and the inferred type must have different names. The convention
> is a lowercase value and a capitalized type: `let user = ...` / `type User =
> Infer(user)`.

## 3. Architecture

`Schema[T]` is a thin typed handle over an untyped **data AST**:

```nim
type Schema*[T] = object
  node: Validator      # ref-object tree describing constraints & structure
```

`T` is a compile-time phantom (it exists only in the type, carrying the
inference); all runtime information lives in the `Validator` tree. Parsing is
then two closure-free passes:

1. **Validate**: one recursive interpreter walks the `Validator` tree against
   the JSON, accumulating `Issue`s with paths.
2. **Extract**: a generic, type-driven `extract[T](json): T` turns the
   validated JSON into the statically-typed value.

Keeping these separate is what makes the library robust (see §7): there are no
closures capturing other closures anywhere in the hot path.

### Building schemas (the `Validator` tree)

Every combinator just constructs a node:

```nim
proc str*(): Schema[string]                    = Schema[string](node: Validator(kind: nkStr))
proc optional*[T](s: Schema[T]): Schema[Option[T]] = Schema[Option[T]](node: Validator(kind: nkOptional, inner: s.node))
proc array*[T](s: Schema[T]): Schema[seq[T]]       = Schema[seq[T]](node: Validator(kind: nkArray, inner: s.node))
```

The static type flows through the *return types* of the combinators (Zod's
trick); the node carries the runtime behaviour. Refinements (`min`, `max`,
`email`, `oneOf`, ...) are stored as plain **data** (`Check` records), so the
constraint set stays tiny and inspectable. Only a user's custom `refine`
predicate is a stored `proc(JsonNode): bool`, and the interpreter *calls* it
directly rather than capturing it. A refinement is **skipped if its inner node
failed**, so you never see `"must be a valid email"` on top of `"expected
string"`.

### Typed extraction, for free

`extract[T]` recurses on the *type*, not on a schema:

```nim
proc extract*[T](j: JsonNode): T =
  when T is string:      ...
  elif T is Option:      (if j null -> none  else some(extract[Inner](j)))
  elif T is seq:         (for e in j: result.add extract[Elem](e))
  elif T is (object or tuple):
                         (for k, v in result.fieldPairs: v = extract[typeof(v)](j[k]))
  ...
```

Because it is driven by `T`, objects (object schemas), `Option`, and `seq`
"just work" with no runtime schema and nothing captured. Defaults are the one
thing the type can't know, so before extracting we run a small `normalize`
pass that injects each `default(d)` value (stored as a `JsonNode`) into the
tree.

The one shape the `fieldPairs` loop can't build is a **variant object**: you
can't assign a case object's discriminator through `fieldPairs`, and the right
branch has to be chosen at construction. So for objects, `extract` doesn't use
`fieldPairs` at all; it calls a small `buildFromJson(T)` macro that generates
the constructor from the type: `T(f: extract[..](..), ...)` for a plain object,
or a `case parseEnum(tag): of ...: T(kind: ..., ...)` for a variant. Because it
is still generated code that recurses through `extract`, there are no closures
anywhere, so variants compose and nest (fields, `seq`, `Option`, deeper objects)
and it all stays correct under ORC. `discriminated(T, field)` only supplies the
validator side (the `nkVariant` node that dispatches on the tag); construction
falls out of `extract` for free.

### The object DSL

```nim
schema:
  name: string.min(2)
  age:  int
```

The macro:

1. Rewrites the *leading* bare type name of each field so `string` reads as
   `str()`, `int` as `integer()`, etc. (`dslRewrite`). Type names inside
   arguments (a lambda's `v: int`) are left alone. This is cosmetic sugar;
   outside the macro you call the constructors directly.
2. Binds each field's schema expression to a local (`let`) and derives the
   object field type from it via `typeof(inferVal(field))`. Fields are emitted
   exported (`*`), so the inferred type's fields are public like a tuple's.
3. Emits a `Validator(kind: nkObject, fields: @[...])` built from each field's
   `.node`, wrapped as `Schema[Rec]`.

No closures are generated; the macro produces a data value and a type.

### Errors

Validation threads a plain `var seq[Issue]`. On a problem the interpreter
appends an `Issue { path, message }` and keeps going, so one `tryParse` reports
*all* problems at once, each with a path:

```
name: must be at least 2 chars
age: must be <= 150
role: must be one of admin, user
```

Two entry points:

- `tryParse(schema, json) -> ParseResult[T]`: never raises; inspect
  `.ok` / `.value` / `.issues`. (Zod's `safeParse`.)
- `parse(schema, json) -> T`: returns `T` or raises `ValidationError`
  (which still carries the full `issues` seq). (Zod's `parse`.)

Both accept either a `JsonNode` or a raw JSON `string`.

## 4. API surface

```
Constructors : str  integer  number  boolean  json
Refinements  : min  max  nonempty  email  pattern  oneOf  refine
Modifiers    : optional  default  array  lazy
Objects      : schema:  (infers type)   schema(T):  (binds to T)   Infer(schema)
Type-first   : schemaOf(T)               (derive a schema from an existing type)
Unions       : discriminated(T, field)   (variant object, tagged by an enum field)
Parsing      : parse  tryParse            (JsonNode or string)
Re-validate  : validate  tryValidate      (an existing/mutated value)
Errors       : Issue  ValidationError  ParseResult
```

Constraints run at parse time; the result is a plain object, so later field
assignment is unchecked (Nim has no assignment hook for public fields, unlike
Pydantic's `validate_assignment`). `validate`/`tryValidate` re-check an existing
value on demand by round-tripping it through JSON.

That is the whole library. New constraints are one call to `refine`; new
container types are one small combinator returning `Schema[...]`.

### Recursive (tree) schemas

A synthesized type can't refer to itself, so recursion uses the two-argument
`schema(T):` form against a type *you* declare (which Nim already lets you make
recursive via `seq`/`ref`), plus `lazy` to defer the self-reference:

```nim
type Comment = object
  text*:    string
  replies*: seq[Comment]

var comment: Schema[Comment]
comment = schema(Comment):
  text:    string.min(1)
  replies: lazy(comment).array.default(@[])   # leaves may omit `replies`

let c = comment.parse(payload)                # arbitrarily deep, paths like replies[0].text
```

`lazy(comment)` stores a single `resolve: proc(): Validator` in an `nkLazy`
node; the interpreter *calls* it when it reaches that node (never captures it),
so recursion terminates on the finite JSON and stays memory-manager safe.
`extract[Comment]` already recurses on the type for free.

Any field of `T` you leave out of a `schema(T):` body is not dropped: the macro
introspects `T` (via `getTypeImpl`) and auto-derives a structural validator for
each unlisted field with the same `nodeOf` machinery as `schemaOf`, so it stays
required and type-checked. Listed fields (including the recursive one, via
`lazy`) are never auto-derived, which is what keeps recursion from looping.
Because a typed first parameter on `schema` would break overload resolution
against the `schema:` block form, the two-argument `schema` stays `untyped` and
forwards to a typed `deriveSchema` helper that does the introspection.

## 5. Design decisions & trade-offs

- **Type-inference direction.** The default is "schema-first" (`schema:` +
  `Infer`), reproducing Zod's inference story and keeping constraints and the
  type in one place. The two-argument `schema(T):` form is the "type-first"
  escape hatch (Pydantic-style: you own the type, the schema validates it) and
  is what makes recursion possible, since a synthesized type can't name itself.

- **Accumulate vs. fail-fast.** We accumulate (Pydantic) rather than throw on
  the first error (naive Zod), because for JSON-from-the-wire "here is
  everything wrong" is far more useful than "the first thing wrong".

- **Data + interpreter, not closures.** Schemas are a `ref`-object AST walked
  by one recursive interpreter, and the typed value comes from a generic
  `extract[T]`. This keeps the runtime simple and inspectable, and, crucially,
  avoids closures capturing other closures, which a closure-based first cut hit
  a compiler bug on (see §7).

- **Minimal core.** Built-in refinements are `Check` data records; `refine` is
  the single escape hatch for custom predicates. The primitive/refinement
  surface stays tiny and uniform.

## 6. Roadmap (not in the prototype)

- Non-discriminated unions (`oneOfSchema(a, b)`, try-each) and literal
  singletons. (Discriminated unions are done via `discriminated`.)
- Coercion mode (`string` → `int`, etc.) à la Pydantic's lax mode.
- `transform` (post-parse mapping) and `refineAsync`-style effectful checks.
- `table` / `Table[K, V]` combinator.
- Serialization: derive `toJson` from the same schema.

## 7. A compiler bug we designed around (ORC)

The library works under **every** Nim memory manager, including the default
`--mm:orc`. Getting there shaped the architecture, so it is worth recording.

The natural first cut made `Schema[T]` a closure:

```nim
type Schema[T] = object
  run: proc(j: JsonNode, ctx: var Ctx): T {.closure.}
```

Combinators wrapped closures, and the object macro generated a `run` closure
that **captured several sub-schema closures** and threaded a `var Ctx`. That
version is correct under `--mm:refc` and `--mm:markAndSweep`, but SIGSEGVs
under ORC. Isolated (reproducible in hand-written, macro-free code):

- The trigger is an object `run` closure that **mutates a `seq` reachable
  through the threaded `ctx`** (e.g. pushing an error-path segment) *before*
  invoking one of its captured sub-schema closures. The sub-schema's own
  captured environment is then read as `nil`; ORC has dropped its refcount
  incorrectly. `default(array(...))` also triggers it independent of `ctx`.
- Unaffected by `--opt`, `--exceptions`, or `--cursorInference`; a plain
  allocation (no `ctx` mutation) does *not* trigger it, which is what pointed
  at closure-environment lifetime.

Rather than pin the whole library to `refc`, the design was moved off closures
entirely (§3): schemas are a `ref`-object **data AST** walked by a single
recursive interpreter, and the typed value comes from a generic `extract[T]`.
Nothing captures a closure, so there is no bulk-capture for ORC to mishandle.
The only stored `proc` is a user's custom `refine` predicate, which the
interpreter calls directly (never captures), verified by test.

This turned out better than a workaround: the data AST is inspectable, the
interpreter is easy to reason about, and typed extraction falls out of the type
system for free. The upstream ORC bug remains worth reporting, but the library
no longer depends on its resolution.
