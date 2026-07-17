## schematic: a minimalist object validation & JSON-parsing library for Nim.
##
## Design in one line: a schema is a value of type ``Schema[T]``. Building a
## schema with the combinator API gives you, for free, the static Nim type it
## produces. That is the Zod ``z.infer`` trick, but leaning on Nim's real
## compile-time types instead of faking them.
##
## .. code-block:: nim
##
##   import schematic
##
##   let user = schema:
##     name:  string.min(2).max(50)
##     age:   int.min(0).max(150)
##     email: string.email.optional
##     tags:  string.array.default(@[])
##
##   type User = Infer(user)          # object: name: string, age: int,
##                                    #         email: Option[string], tags: seq[string]
##
##   let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io"}""")
##   echo u.name          # statically typed field access
##
## (Nim shares one namespace for types and values, so the schema value and the
## inferred type need different names, e.g. ``user`` and ``User``.)
##
## Internally a schema is a small **data AST** (`Validator`) walked by a single
## recursive interpreter, and the typed value is produced by a generic,
## type-driven `extract`. There are no captured closures in the hot path, so it
## runs correctly under every Nim memory manager, including ORC. See DESIGN.md.

import std/[json, options, tables, times, macros, strutils, sequtils]
import regex           # pure-Nim regex engine, used by `pattern` and friends
export json, options, tables, times   # so `JsonNode`, `Option`, `Table`,
                       # `Time`, etc. are in scope for callers and generated code

# --------------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------------

type
  Issue* = object
    ## A single validation failure.
    path*: string      ## dotted path to the offending value, e.g. ``address.city``
    message*: string   ## human-readable description

  ValidationError* = object of CatchableError
    ## Raised by ``parse`` when validation fails. Carries every issue found,
    ## not just the first (pydantic-style accumulation).
    issues*: seq[Issue]

  ParseResult*[T] = object
    ## Result of ``tryParse``. Either ``ok`` with a ``value`` or a list of ``issues``.
    ok*: bool
    value*: T
    issues*: seq[Issue]

proc `$`*(issue: Issue): string =
  issue.path & ": " & issue.message

proc `$`*(err: ValidationError): string =
  err.issues.mapIt($it).join("\n")

# --------------------------------------------------------------------------
# The validator AST (pure data; no captured closures)
# --------------------------------------------------------------------------

type
  CheckKind = enum
    ckMinInt, ckMaxInt, ckMinFloat, ckMaxFloat,
    ckMinLen, ckMaxLen, ckNonEmpty, ckEmail, ckOneOf,
    ckMinItems, ckMaxItems, ckPattern, ckCustom

  Check = object
    ## One refinement, stored as data. Only `ckCustom` holds a proc, and it is
    ## called directly by the interpreter (never captured into another closure).
    message: string
    case kind: CheckKind
    of ckMinInt, ckMaxInt, ckMinLen, ckMaxLen, ckMinItems, ckMaxItems:
      n: int
    of ckMinFloat, ckMaxFloat:
      f: float
    of ckOneOf:
      choices: seq[string]
    of ckPattern:
      pattern: string           ## regex source (kept for JSON Schema)
      rx: Regex2                 ## compiled once, for validation
    of ckCustom:
      predicate: proc(j: JsonNode): bool {.closure.}
    of ckNonEmpty, ckEmail:
      discard

  NodeKind = enum
    nkStr, nkInt, nkFloat, nkBool, nkJson, nkTimestamp, nkCheck, nkCoerce,
    nkOptional, nkDefault, nkArray, nkRecord, nkTuple, nkObject, nkLazy,
    nkVariant, nkAlias

  FieldDef = object
    name: string                ## Nim field name
    jsonKey: string             ## JSON key to read/write (empty = same as name)
    node: Validator

  VariantBranch = object
    ## One `of` branch of a discriminated union: its discriminator value (as a
    ## string) and the fields active in that branch.
    discValue: string
    fields: seq[FieldDef]

  Validator = ref object
    inner: Validator            ## wrapped node (check/optional/default/array/record/alias)
    case kind: NodeKind
    of nkCheck: check: Check
    of nkDefault: defJson: JsonNode
    of nkObject: fields: seq[FieldDef]
    of nkLazy: resolve: proc(): Validator {.closure.}   ## deferred (recursion)
    of nkVariant:
      discName: string          ## discriminator field name
      common: seq[FieldDef]      ## fields shared by every branch
      branches: seq[VariantBranch]
    of nkAlias: aliasKey: string   ## JSON key this field is read from
    of nkTuple: elems: seq[Validator]   ## positional element schemas
    else: discard

  Schema*[T] = object
    ## A schema producing a ``T``. ``T`` is exactly the type ``parse`` returns.
    ## Carries only the data AST; the type is a compile-time phantom.
    node: Validator

# --------------------------------------------------------------------------
# Type inference
# --------------------------------------------------------------------------

proc inferVal*[T](s: Schema[T]): T = discard
  ## Never executed; used only inside ``typeof`` to recover ``T`` from a schema.

macro Infer*(s: typed): untyped =
  ## Recover the produced type ``T`` from a ``Schema[T]`` value.
  ## ``type User = Infer(userSchema)``.
  getTypeInst(s)[1]

# --------------------------------------------------------------------------
# Typed extraction: JSON -> T, driven purely by the static type
# --------------------------------------------------------------------------

proc fieldOf(j: JsonNode, key: string): JsonNode =
  ## A field, or a JNull node when absent (so leaves see "null" uniformly).
  if not j.isNil and j.kind == JObject and j.hasKey(key): j[key] else: newJNull()

proc extract*[T](j: JsonNode): T    ## forward declaration (buildFromJson calls it)

proc objImpl(T: NimNode): NimNode =
  ## The ``nnkObjectTy`` for a type ``T``, unwrapping the ``typedesc[T]`` bracket
  ## and, for a ``ref object``, the surrounding ``nnkRefTy``. The introspecting
  ## macros share this so ``ref object`` types are accepted wherever a value
  ## object is.
  result = T.getTypeImpl
  if result.kind == nnkBracketExpr: result = result[1].getTypeImpl
  if result.kind == nnkRefTy: result = result[0].getTypeImpl

macro buildFromJson(T: typedesc): untyped =
  ## Construct an object ``T`` from a ``j: JsonNode`` in scope, field by field.
  ## Handles case (variant) objects, which the generic `fieldPairs` loop cannot
  ## build: it dispatches on the discriminator and constructs the right branch.
  ## Everything is generated code that recurses through `extract`, so there are
  ## still no closures anywhere (it stays memory-manager safe under ORC).
  ##
  ## For a ``ref object`` T the object-constructor syntax ``T(field: ...)``
  ## allocates, so the branch-building below carries over unchanged.
  let impl = objImpl(T)
  proc ex(nm: string, ft: NimNode): NimNode =   # extract[ft](fieldOf(j, nm))
    newCall(nnkBracketExpr.newTree(bindSym"extract", ft),
      newCall(bindSym"fieldOf", ident"j", newLit(nm)))
  var common: seq[(string, NimNode)]
  var recCase: NimNode = nil
  for n in impl[2]:                   # RecList
    if n.kind == nnkIdentDefs:
      let ft = n[^2]
      for i in 0 ..< n.len - 2: common.add (n[i].strVal, ft)
    elif n.kind == nnkRecCase:
      recCase = n
  if recCase.isNil:                   # a plain object: T(f0: extract(...), ...)
    result = nnkObjConstr.newTree(T)
    for c in common: result.add nnkExprColonExpr.newTree(ident(c[0]), ex(c[0], c[1]))
  else:                               # variant: case on the tag, build the branch
    let discName = recCase[0][0].strVal
    let discType = recCase[0][1]
    let enumImpl = discType.getTypeImpl
    result = nnkCaseStmt.newTree(
      newCall(nnkBracketExpr.newTree(bindSym"parseEnum", discType),
        newDotExpr(newCall(bindSym"fieldOf", ident"j", newLit(discName)), ident"getStr")))
    for bi in 1 ..< recCase.len:
      let br = recCase[bi]
      if br.kind != nnkOfBranch: continue
      let esym = enumImpl[br[0].intVal.int + 1]
      var oc = nnkObjConstr.newTree(T, nnkExprColonExpr.newTree(ident(discName), esym))
      for c in common: oc.add nnkExprColonExpr.newTree(ident(c[0]), ex(c[0], c[1]))
      var idfs: seq[NimNode]
      if br[^1].kind == nnkRecList: (for f in br[^1]: idfs.add f)
      else: idfs.add br[^1]
      for f in idfs:
        let ft = f[^2]
        for i in 0 ..< f.len - 2:
          oc.add nnkExprColonExpr.newTree(ident(f[i].strVal), ex(f[i].strVal, ft))
      result.add nnkOfBranch.newTree(esym, oc)

proc extract*[T](j: JsonNode): T =
  ## Turn a (already-validated, already-defaulted) JSON node into a ``T``.
  ## Recurses on the type, so it needs no runtime schema and captures nothing.
  when T is string:
    (if not j.isNil and j.kind == JString: j.getStr else: "")
  elif T is bool:
    (if not j.isNil and j.kind == JBool: j.getBool else: false)
  elif T is SomeInteger:
    (if not j.isNil and j.kind == JInt: T(j.getInt) else: T(0))
  elif T is SomeFloat:
    (if not j.isNil and j.kind in {JFloat, JInt}: T(j.getFloat) else: T(0.0))
  elif T is JsonNode:
    (if j.isNil: newJNull() else: j)
  elif T is Time:                     # `timestamp` schemas: Unix seconds -> Time
    (if not j.isNil and j.kind == JInt: fromUnix(j.getInt) else: fromUnix(0))
  elif T is enum:                     # validated JSON string -> enum member
    (if not j.isNil and j.kind == JString: parseEnum[T](j.getStr) else: low(T))
  elif T is Option:
    if j.isNil or j.kind == JNull: none(typeof(get(default(T))))
    else: some(extract[typeof(get(default(T)))](j))
  elif T is seq:
    if not j.isNil and j.kind == JArray:
      for e in j.elems: result.add extract[typeof(default(T)[0])](e)
  elif T is Table:                    # `record` schemas: object -> Table[string, V]
    if not j.isNil and j.kind == JObject:
      for k, v in j: result[k] = extract[typeof(default(T)[""])](v)
  elif T is tuple:
    for key, val in result.fieldPairs:
      let sub = if not j.isNil and j.kind == JObject and j.hasKey(key): j[key]
                else: newJNull()
      val = extract[typeof(val)](sub)
  elif T is ref:                      # ref object: allocate, then fill the payload
    new(result)                       # (JsonNode, also a ref, was handled above)
    result[] = extract[typeof(result[])](j)
  elif T is object:                   # normal or variant object; may need a `case`
    result = buildFromJson(T)
  else:
    {.error: "schematic: cannot extract unsupported type " & $T.}

# --------------------------------------------------------------------------
# Primitive schemas
# --------------------------------------------------------------------------

proc str*(): Schema[string] =
  ## Matches a JSON string.
  Schema[string](node: Validator(kind: nkStr))

proc integer*(): Schema[int] =
  ## Matches a JSON integer.
  Schema[int](node: Validator(kind: nkInt))

proc number*(): Schema[float] =
  ## Matches a JSON number (integer or float).
  Schema[float](node: Validator(kind: nkFloat))

proc boolean*(): Schema[bool] =
  ## Matches a JSON boolean.
  Schema[bool](node: Validator(kind: nkBool))

proc json*(): Schema[JsonNode] =
  ## Matches any JSON value and passes it through unchanged as a ``JsonNode``
  ## (an "any" / passthrough escape hatch). A missing key or ``null`` is still
  ## treated as missing; wrap in ``optional`` if the value may be absent.
  Schema[JsonNode](node: Validator(kind: nkJson))

proc timestamp*(): Schema[Time] =
  ## Matches a JSON integer of Unix seconds and produces a ``times.Time``.
  Schema[Time](node: Validator(kind: nkTimestamp))

# --------------------------------------------------------------------------
# Refinements
# --------------------------------------------------------------------------

proc withCheck[T](s: Schema[T], c: Check): Schema[T] =
  Schema[T](node: Validator(kind: nkCheck, inner: s.node, check: c))

proc refine*[T](s: Schema[T], message: string, ok: proc(v: T): bool): Schema[T] =
  ## Add a custom predicate. The check is skipped if the inner parse already
  ## failed, so you never get a spurious "invalid" on top of "expected string".
  let pred = proc(j: JsonNode): bool = ok(extract[T](j))
  s.withCheck(Check(kind: ckCustom, message: message, predicate: pred))

proc min*(s: Schema[int], n: int): Schema[int] =
  s.withCheck(Check(kind: ckMinInt, n: n, message: "must be >= " & $n))
proc max*(s: Schema[int], n: int): Schema[int] =
  s.withCheck(Check(kind: ckMaxInt, n: n, message: "must be <= " & $n))
proc min*(s: Schema[float], n: float): Schema[float] =
  s.withCheck(Check(kind: ckMinFloat, f: n, message: "must be >= " & $n))
proc max*(s: Schema[float], n: float): Schema[float] =
  s.withCheck(Check(kind: ckMaxFloat, f: n, message: "must be <= " & $n))

proc min*(s: Schema[string], n: int): Schema[string] =
  ## Minimum string length.
  s.withCheck(Check(kind: ckMinLen, n: n, message: "must be at least " & $n & " chars"))
proc max*(s: Schema[string], n: int): Schema[string] =
  ## Maximum string length.
  s.withCheck(Check(kind: ckMaxLen, n: n, message: "must be at most " & $n & " chars"))
proc nonempty*(s: Schema[string]): Schema[string] =
  s.withCheck(Check(kind: ckNonEmpty, message: "must not be empty"))
proc email*(s: Schema[string]): Schema[string] =
  ## Cheap structural email check (a real one would use `pattern`).
  s.withCheck(Check(kind: ckEmail, message: "must be a valid email"))
proc patternCheck(p, message: string): Check =
  Check(kind: ckPattern, pattern: p, rx: re2(p), message: message)

proc pattern*(s: Schema[string], p: string): Schema[string] =
  ## The whole string must match the regular expression ``p`` (anchored, via the
  ## `regex` package). ``p`` is compiled once, when the schema is built.
  s.withCheck(patternCheck(p, "must match pattern " & p))

const
  uuidPattern = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  datePattern = r"\d{4}-\d{2}-\d{2}"
  datetimePattern = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?"

proc uuid*(s: Schema[string]): Schema[string] =
  ## The string must be a UUID (any version, hyphenated form).
  s.withCheck(patternCheck(uuidPattern, "must be a UUID"))
proc date*(s: Schema[string]): Schema[string] =
  ## The string must be an ISO date, ``YYYY-MM-DD`` (kept as a string).
  s.withCheck(patternCheck(datePattern, "must be a date (YYYY-MM-DD)"))
proc datetime*(s: Schema[string]): Schema[string] =
  ## The string must be an ISO 8601 date-time (kept as a string).
  s.withCheck(patternCheck(datetimePattern, "must be an ISO 8601 datetime"))

proc oneOf*(s: Schema[string], choices: openArray[string]): Schema[string] =
  ## Enum-style constraint: value must be one of ``choices``.
  s.withCheck(Check(kind: ckOneOf, choices: @choices,
    message: "must be one of " & @choices.join(", ")))

proc min*[T](s: Schema[seq[T]], n: int): Schema[seq[T]] =
  ## Minimum array length.
  s.withCheck(Check(kind: ckMinItems, n: n, message: "must have at least " & $n & " items"))
proc max*[T](s: Schema[seq[T]], n: int): Schema[seq[T]] =
  ## Maximum array length.
  s.withCheck(Check(kind: ckMaxItems, n: n, message: "must have at most " & $n & " items"))

# --------------------------------------------------------------------------
# Modifiers & composition
# --------------------------------------------------------------------------

proc optional*[T](s: Schema[T]): Schema[Option[T]] =
  ## A missing key or JSON ``null`` becomes ``none(T)``; otherwise ``some``.
  ## Changes the produced type to ``Option[T]``.
  Schema[Option[T]](node: Validator(kind: nkOptional, inner: s.node))

proc default*[T](s: Schema[T], d: T): Schema[T] =
  ## Substitute ``d`` when the key is missing or ``null``. Keeps type ``T``.
  Schema[T](node: Validator(kind: nkDefault, inner: s.node, defJson: %d))

proc array*[T](s: Schema[T]): Schema[seq[T]] =
  ## Matches a JSON array of ``s``, producing ``seq[T]``.
  Schema[seq[T]](node: Validator(kind: nkArray, inner: s.node))

proc record*[V](s: Schema[V]): Schema[Table[string, V]] =
  ## Matches a JSON object with arbitrary string keys whose values all match
  ## ``s``, producing a ``Table[string, V]``.
  Schema[Table[string, V]](node: Validator(kind: nkRecord, inner: s.node))

proc coerce*[T](s: Schema[T]): Schema[T] =
  ## Coerce a convertible JSON scalar to the target primitive before validating
  ## (opt-in, Zod's ``z.coerce``). Numbers accept numeric strings and whole
  ## floats; booleans accept ``"true"``/``"false"``; strings accept any scalar.
  ## Apply to a scalar schema, before other refinements matter, e.g.
  ## ``id: integer().coerce`` or ``n: integer().min(0).coerce``.
  Schema[T](node: Validator(kind: nkCoerce, inner: s.node))

proc alias*[T](s: Schema[T], jsonKey: string): Schema[T] =
  ## Read/write this field under ``jsonKey`` in the JSON, while keeping the Nim
  ## field name from the schema. Apply it last in a field's chain, e.g.
  ## ``userName: string.min(1).alias("user_name")``.
  Schema[T](node: Validator(kind: nkAlias, aliasKey: jsonKey, inner: s.node))

template lazy*(schemaVar: untyped): untyped =
  ## Defer a reference to a schema so a schema can refer to itself (recursion).
  ## Pass the *name* of a ``Schema`` variable declared with ``var``; it is read
  ## lazily, at parse time, once the variable has been assigned:
  ##
  ## .. code-block:: nim
  ##   var tree: Schema[Node]
  ##   tree = schema(Node):
  ##     value:    int
  ##     children: lazy(tree).array
  ##
  ## The one stored ``resolve`` proc is called by the interpreter, never
  ## captured into another closure, so it stays memory-manager safe.
  Schema[typeof(inferVal(schemaVar))](node: Validator(kind: nkLazy,
    resolve: proc(): Validator = schemaVar.node))

macro enumChoices(T: typedesc): untyped =
  ## ``@[$m0, $m1, ...]`` for the members of enum ``T``. Emitting ``$`` calls
  ## (rather than the member names) honours explicit string values such as
  ## ``red = "red-ish"``, so the choices match what appears in JSON.
  var impl = T.getTypeImpl
  if impl.kind == nnkBracketExpr: impl = impl[1].getTypeImpl
  impl.expectKind(nnkEnumTy)
  var arr = nnkBracket.newTree()
  for i in 1 ..< impl.len:            # [0] is an empty node, [1..] are the members
    arr.add newCall(ident"$", impl[i])
  result = prefix(arr, "@")

proc enumNode[T: enum](): Validator =
  ## An enum is validated as a JSON string constrained to the member values, and
  ## `extract` turns that string back into ``T`` with `parseEnum`.
  let cs = enumChoices(T)
  Validator(kind: nkCheck, inner: Validator(kind: nkStr),
    check: Check(kind: ckOneOf, choices: cs,
                 message: "must be one of " & cs.join(", ")))

proc nodeOf[T](): Validator =
  ## Derive a validator tree from the structure of type ``T``.
  when T is string:      result = Validator(kind: nkStr)
  elif T is bool:        result = Validator(kind: nkBool)
  elif T is SomeInteger: result = Validator(kind: nkInt)
  elif T is SomeFloat:   result = Validator(kind: nkFloat)
  elif T is JsonNode:    result = Validator(kind: nkJson)
  elif T is enum:        result = enumNode[T]()
  elif T is Option:
    result = Validator(kind: nkOptional, inner: nodeOf[typeof(get(default(T)))]())
  elif T is seq:
    result = Validator(kind: nkArray, inner: nodeOf[typeof(default(T)[0])]())
  elif T is ref:                      # derive from the pointed-to object type
    result = nodeOf[typeof(default(T)[])]()
  elif T is (object or tuple):
    var fields: seq[FieldDef]
    var probe: T
    for fname, val in probe.fieldPairs:
      fields.add FieldDef(name: fname, node: nodeOf[typeof(val)]())
    result = Validator(kind: nkObject, fields: fields)
  else:
    {.error: "schematic: schemaOf cannot derive a schema for " & $T.}

proc schemaOf*[T](t: typedesc[T]): Schema[T] =
  ## Derive a structural schema straight from an existing type ``T``: every
  ## field is required and type-checked against the JSON, with no custom
  ## constraints. Handy for dropping a plain object type into a `schema:` field
  ## (``location: schemaOf(Point)``) or parsing a type as-is.
  ##
  ## For non-recursive types only; a self-referential type would build an
  ## infinite validator. Use `schema(T):` with `lazy` for recursive/tree types.
  Schema[T](node: nodeOf[T]())

proc enumOf*[T: enum](t: typedesc[T]): Schema[T] =
  ## A schema for a Nim ``enum``: the JSON must be a string equal to one of the
  ## enum's members (their ``$`` form, so explicit values like ``red = "red"``
  ## are honoured), and it is parsed straight into ``T``. Use it in the DSL as
  ## ``status: enumOf(Status)``. Enum-typed fields are also picked up
  ## automatically by `schemaOf` and `schema(T):`.
  Schema[T](node: enumNode[T]())

# --------------------------------------------------------------------------
# Interpreter: validate (accumulating issues with paths) and normalize (defaults)
# --------------------------------------------------------------------------

proc join2(prefix, seg: string): string =
  if prefix.len == 0: seg
  elif seg.len > 0 and seg[0] == '[': prefix & seg     # array index
  else: prefix & "." & seg

proc validEmail(s: string): bool =
  let at = s.find('@')
  at > 0 and at < s.high and s.rfind('.') > at

proc isMissing(j: JsonNode): bool =
  j.isNil or j.kind == JNull

proc keyOf(fld: FieldDef): string =
  ## The JSON key for a field (its alias if set, else the field name).
  if fld.jsonKey.len > 0: fld.jsonKey else: fld.name

proc fieldDefOf*(name: string, node: Validator): FieldDef =
  ## Build a field def, unwrapping an `alias` node into a JSON key. Used by the
  ## object-schema macros so `x: string.alias("y")` reads `y` but writes `x`.
  if not node.isNil and node.kind == nkAlias:
    FieldDef(name: name, jsonKey: node.aliasKey, node: node.inner)
  else:
    FieldDef(name: name, jsonKey: name, node: node)

proc primKind(v: Validator): NodeKind =
  ## Peel refinement wrappers to the underlying primitive node kind.
  var n = v
  while not n.isNil and n.kind == nkCheck: n = n.inner
  if n.isNil: nkJson else: n.kind

proc primName(k: NodeKind): string =
  case k
  of nkInt: "integer"
  of nkFloat: "number"
  of nkBool: "boolean"
  of nkStr: "string"
  else: $k

proc coerceValue(target: NodeKind, j: JsonNode): JsonNode =
  ## Coerce ``j`` to ``target``'s JSON kind, or ``nil`` if not coercible.
  if j.isNil: return nil
  case target
  of nkInt:
    case j.kind
    of JInt: j
    of JString: (try: newJInt(parseInt(j.getStr)) except ValueError: nil)
    of JFloat: (let f = j.getFloat; (if f == f.int.float: newJInt(f.int) else: nil))
    else: nil
  of nkFloat:
    case j.kind
    of JFloat, JInt: newJFloat(j.getFloat)
    of JString: (try: newJFloat(parseFloat(j.getStr)) except ValueError: nil)
    else: nil
  of nkBool:
    case j.kind
    of JBool: j
    of JInt:                          # 0 -> false, any positive -> true
      let n = j.getInt
      if n == 0: newJBool(false)
      elif n > 0: newJBool(true)
      else: nil
    of JString:
      case j.getStr.toLowerAscii      # "true"/"false" (case-insensitive)
      of "true": newJBool(true)
      of "false": newJBool(false)
      else:                           # else "0" -> false, positive int -> true
        try:
          let n = parseInt(j.getStr)
          if n == 0: newJBool(false)
          elif n > 0: newJBool(true)
          else: nil
        except ValueError: nil
    else: nil
  of nkStr:
    case j.kind
    of JString: j
    of JInt: newJString($j.getInt)
    of JFloat: newJString($j.getFloat)
    of JBool: newJString($j.getBool)
    else: nil
  else: j              # non-scalar target: nothing to coerce

proc applyCheck(c: Check, j: JsonNode, path: string, issues: var seq[Issue]) =
  let ok =
    case c.kind
    of ckMinInt:   j.getInt >= c.n
    of ckMaxInt:   j.getInt <= c.n
    of ckMinFloat: j.getFloat >= c.f
    of ckMaxFloat: j.getFloat <= c.f
    of ckMinLen:   j.getStr.len >= c.n
    of ckMaxLen:   j.getStr.len <= c.n
    of ckNonEmpty: j.getStr.len > 0
    of ckEmail:    validEmail(j.getStr)
    of ckOneOf:    j.getStr in c.choices
    of ckMinItems: j.len >= c.n
    of ckMaxItems: j.len <= c.n
    of ckPattern:  j.getStr.match(c.rx)
    of ckCustom:   c.predicate(j)
  if not ok:
    issues.add Issue(path: (if path.len == 0: "(root)" else: path), message: c.message)

proc validate(v: Validator, j: JsonNode, path: string, issues: var seq[Issue]) =
  ## Walk the AST, appending an issue per problem. A refinement is only applied
  ## if its inner node validated cleanly.
  let here = if path.len == 0: "(root)" else: path
  case v.kind
  of nkStr:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JString: issues.add Issue(path: here, message: "expected string, got " & $j.kind)
  of nkInt:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JInt: issues.add Issue(path: here, message: "expected integer, got " & $j.kind)
  of nkFloat:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind notin {JFloat, JInt}: issues.add Issue(path: here, message: "expected number, got " & $j.kind)
  of nkBool:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JBool: issues.add Issue(path: here, message: "expected boolean, got " & $j.kind)
  of nkJson:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    # any present JSON value is accepted as-is
  of nkTimestamp:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JInt: issues.add Issue(path: here, message: "expected integer (unix seconds), got " & $j.kind)
  of nkAlias:
    validate(v.inner, j, path, issues)     # key remap only matters inside objects
  of nkCoerce:
    if j.isMissing:
      validate(v.inner, j, path, issues)   # inner reports "required"
    else:
      let target = primKind(v.inner)
      let c = coerceValue(target, j)
      if c.isNil:
        issues.add Issue(path: here, message: "cannot coerce " & $j.kind & " to " & primName(target))
      else:
        validate(v.inner, c, path, issues) # validate the coerced value (refinements apply)
  of nkCheck:
    let before = issues.len
    validate(v.inner, j, path, issues)
    if issues.len == before:
      applyCheck(v.check, j, path, issues)
  of nkOptional, nkDefault:
    if not j.isMissing:
      validate(v.inner, j, path, issues)
  of nkArray:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JArray: issues.add Issue(path: here, message: "expected array, got " & $j.kind)
    else:
      for i, el in j.elems:
        validate(v.inner, el, join2(path, "[" & $i & "]"), issues)
  of nkRecord:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JObject: issues.add Issue(path: here, message: "expected object, got " & $j.kind)
    else:
      for k, val in j: validate(v.inner, val, join2(path, k), issues)
  of nkTuple:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JArray: issues.add Issue(path: here, message: "expected array, got " & $j.kind)
    elif j.len != v.elems.len:
      issues.add Issue(path: here, message: "expected array of length " & $v.elems.len & ", got " & $j.len)
    else:
      for i in 0 ..< v.elems.len:
        validate(v.elems[i], j.elems[i], join2(path, "[" & $i & "]"), issues)
  of nkObject:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JObject: issues.add Issue(path: here, message: "expected object, got " & $j.kind)
    else:
      for fld in v.fields:
        let jk = fld.keyOf
        let sub = if j.hasKey(jk): j[jk] else: newJNull()
        validate(fld.node, sub, join2(path, jk), issues)
  of nkLazy:
    validate(v.resolve(), j, path, issues)
  of nkVariant:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JObject: issues.add Issue(path: here, message: "expected object, got " & $j.kind)
    else:
      let dPath = join2(path, v.discName)
      let dNode = if j.hasKey(v.discName): j[v.discName] else: newJNull()
      if dNode.isMissing:
        issues.add Issue(path: dPath, message: "required")
      elif dNode.kind != JString:
        issues.add Issue(path: dPath, message: "expected string, got " & $dNode.kind)
      else:
        var branch: ptr VariantBranch = nil
        for i in 0 ..< v.branches.len:
          if v.branches[i].discValue == dNode.getStr: branch = addr v.branches[i]
        if branch == nil:
          issues.add Issue(path: dPath, message: "must be one of " &
            v.branches.mapIt(it.discValue).join(", "))
        else:
          for fld in v.common & branch[].fields:
            let jk = fld.keyOf
            let sub = if j.hasKey(jk): j[jk] else: newJNull()
            validate(fld.node, sub, join2(path, jk), issues)

proc normalize(v: Validator, j: JsonNode): JsonNode =
  ## Return a JSON tree with defaults filled in, ready for `extract`.
  ## Only called after validation succeeds, so present values are valid.
  case v.kind
  of nkDefault:
    result = if j.isMissing: v.defJson else: normalize(v.inner, j)
  of nkOptional, nkCheck:
    result = if j.isMissing: newJNull() else: normalize(v.inner, j)
  of nkArray:
    result = newJArray()
    if not j.isNil and j.kind == JArray:
      for el in j.elems: result.add normalize(v.inner, el)
  of nkRecord:
    result = newJObject()
    if not j.isNil and j.kind == JObject:
      for k, val in j: result[k] = normalize(v.inner, val)
  of nkTuple:                                  # array -> object keyed like an
    result = newJObject()                      # anonymous tuple's fields (Field0..)
    if not j.isNil and j.kind == JArray and j.len == v.elems.len:
      for i in 0 ..< v.elems.len:
        result["Field" & $i] = normalize(v.elems[i], j.elems[i])
  of nkObject:
    result = newJObject()
    for fld in v.fields:                       # read the alias key, write the field name
      let jk = fld.keyOf
      let sub = if not j.isNil and j.kind == JObject and j.hasKey(jk): j[jk]
                else: newJNull()
      result[fld.name] = normalize(fld.node, sub)
  of nkLazy:
    result = normalize(v.resolve(), j)
  of nkAlias:
    result = normalize(v.inner, j)
  of nkCoerce:
    if j.isMissing: result = normalize(v.inner, j)
    else:
      let c = coerceValue(primKind(v.inner), j)
      result = normalize(v.inner, if c.isNil: j else: c)
  else:
    result = if j.isNil: newJNull() else: j

# --------------------------------------------------------------------------
# JSON Schema generation: walk the Validator tree into a JSON Schema document
# --------------------------------------------------------------------------

proc applyCheckToSchema(c: Check, schema: JsonNode) =
  case c.kind
  of ckMinInt:   schema["minimum"] = %c.n
  of ckMaxInt:   schema["maximum"] = %c.n
  of ckMinFloat: schema["minimum"] = %c.f
  of ckMaxFloat: schema["maximum"] = %c.f
  of ckMinLen:   schema["minLength"] = %c.n
  of ckMaxLen:   schema["maxLength"] = %c.n
  of ckNonEmpty: schema["minLength"] = %1
  of ckEmail:    schema["format"] = %"email"
  of ckOneOf:    schema["enum"] = %c.choices
  of ckMinItems: schema["minItems"] = %c.n
  of ckMaxItems: schema["maxItems"] = %c.n
  of ckPattern:  schema["pattern"] = %c.pattern
  of ckCustom:   discard          # a predicate has no JSON Schema representation

proc isOptionalField(node: Validator): bool =
  not node.isNil and node.kind in {nkOptional, nkDefault}

proc nodeToSchema(v: Validator): JsonNode =
  if v.isNil: return newJObject()
  case v.kind
  of nkStr:       result = %*{"type": "string"}
  of nkInt:       result = %*{"type": "integer"}
  of nkFloat:     result = %*{"type": "number"}
  of nkBool:      result = %*{"type": "boolean"}
  of nkJson:      result = newJObject()       # {} accepts any JSON
  of nkTimestamp: result = %*{"type": "integer", "description": "Unix timestamp (seconds)"}
  of nkAlias:     result = nodeToSchema(v.inner)
  of nkCoerce:    result = nodeToSchema(v.inner)   # coercion isn't expressible
  of nkCheck:
    result = nodeToSchema(v.inner)
    applyCheckToSchema(v.check, result)
  of nkOptional:
    result = nodeToSchema(v.inner)
  of nkDefault:
    result = nodeToSchema(v.inner)
    result["default"] = v.defJson
  of nkArray:
    result = %*{"type": "array", "items": nodeToSchema(v.inner)}
  of nkRecord:
    result = %*{"type": "object", "additionalProperties": nodeToSchema(v.inner)}
  of nkTuple:
    var items = newJArray()
    for e in v.elems: items.add nodeToSchema(e)
    result = %*{"type": "array", "prefixItems": items, "items": false,
                "minItems": v.elems.len, "maxItems": v.elems.len}
  of nkObject:
    var props = newJObject()
    var required = newJArray()
    for fld in v.fields:
      props[fld.keyOf] = nodeToSchema(fld.node)
      if not isOptionalField(fld.node): required.add %fld.keyOf
    result = %*{"type": "object", "properties": props, "additionalProperties": false}
    if required.len > 0: result["required"] = required
  of nkLazy:
    result = %*{"$ref": "#"}      # assume self-reference (the recursion case)
  of nkVariant:
    var branches = newJArray()
    for br in v.branches:
      var props = %*{v.discName: {"const": br.discValue}}
      var required = %*[v.discName]
      for fld in v.common & br.fields:
        props[fld.keyOf] = nodeToSchema(fld.node)
        if not isOptionalField(fld.node): required.add %fld.keyOf
      branches.add %*{"type": "object", "properties": props,
                      "required": required, "additionalProperties": false}
    result = %*{"oneOf": branches}

proc toJsonSchema*[T](s: Schema[T]): JsonNode =
  ## Emit a JSON Schema (draft 2020-12) document describing what ``s`` accepts.
  ## Custom `refine` predicates have no JSON Schema form and are simply omitted.
  result = nodeToSchema(s.node)
  result["$schema"] = %"https://json-schema.org/draft/2020-12/schema"

# --------------------------------------------------------------------------
# Object schema DSL
# --------------------------------------------------------------------------

proc dslRewrite(n: NimNode): NimNode =
  ## Inside the DSL, let a bare *leading* type name read as a schema
  ## constructor: ``string`` -> ``str()``, ``int`` -> ``integer()``, etc.
  ## Only the leftmost atom of the field's ``a.b(c).d`` chain is rewritten, so
  ## type names inside arguments (e.g. a lambda's ``v: int``) are left alone.
  case n.kind
  of nnkIdent:
    result =
      case n.strVal
      of "string": newCall(ident"str")
      of "int": newCall(ident"integer")
      of "float": newCall(ident"number")
      of "bool": newCall(ident"boolean")
      of "JsonNode": newCall(ident"json")
      else: n
  of nnkDotExpr:                       # left.member  -> rewrite left only
    result = newTree(nnkDotExpr, dslRewrite(n[0]), n[1])
  of nnkCall, nnkCommand:              # callee(args) -> rewrite callee only
    result = copyNimNode(n)
    result.add dslRewrite(n[0])
    for i in 1 ..< n.len: result.add n[i]
  else:
    result = n

macro schema*(body: untyped): untyped =
  ## Build an object schema. Each ``key: schemaExpr`` line contributes a field;
  ## the produced type is an ``object`` whose field types are inferred from the
  ## schema expressions. Recover that type with ``Infer(theSchema)``.
  var recFields = nnkRecList.newTree()   # fields of the generated object type
  var lets = newStmtList()
  var fieldDefs = nnkBracket.newTree()   # array of FieldDef, spliced into @[...]

  var idx = 0
  for f in body:
    f.expectKind(nnkCall)                # key: expr  ->  Call(Ident, StmtList(expr))
    let key = f[0].strVal
    let expr = dslRewrite(f[1][0])
    let fv = genSym(nskLet, "field" & $idx)
    lets.add newLetStmt(fv, expr)
    # object field:  key*: typeof(inferVal(fieldN))   (exported, like a tuple's)
    recFields.add nnkIdentDefs.newTree(
      nnkPostfix.newTree(ident"*", ident(key)),
      newCall(ident"typeof", newCall(bindSym"inferVal", fv)),
      newEmptyNode())
    # fieldDefOf("key", fieldN.node)  (unwraps a `.alias(...)` into the JSON key)
    fieldDefs.add newCall(bindSym"fieldDefOf", newLit(key), newDotExpr(fv, ident"node"))
    inc idx

  let recSym = genSym(nskType, "Rec")
  let objTy = nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recFields)
  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(
    lets,
    nnkTypeSection.newTree(nnkTypeDef.newTree(recSym, newEmptyNode(), objTy)),
    nnkObjConstr.newTree(
      nnkBracketExpr.newTree(bindSym"Schema", recSym),
      nnkExprColonExpr.newTree(ident"node",
        nnkObjConstr.newTree(bindSym"Validator",
          nnkExprColonExpr.newTree(ident"kind", bindSym"nkObject"),
          nnkExprColonExpr.newTree(ident"fields",
            prefix(fieldDefs, "@")))))))

macro deriveSchema(T: typedesc, body: untyped): untyped =
  ## Internal worker for the two-argument `schema`. Kept separate (and typed) so
  ## the public `schema(T, body)` can stay `untyped`; a typed first parameter on
  ## `schema` itself breaks overload resolution against the one-argument
  ## `schema:` block form.

  # 1. Collect the explicitly listed fields.
  var listedNames: seq[string]
  var listedExprs: seq[NimNode]
  for f in body:
    f.expectKind(nnkCall)              # key: expr  ->  Call(Ident, StmtList(expr))
    listedNames.add f[0].strVal
    listedExprs.add dslRewrite(f[1][0])

  # 2. Introspect T's fields (unwrap typedesc[T] -> T -> object, ref or value).
  let impl = objImpl(T)
  if impl.kind != nnkObjectTy:
    error("schema(" & T.repr & "): expected an object type", body)
  var allNames: seq[string]
  var allTypes: seq[NimNode]
  for idf in impl[2]:                  # RecList of IdentDefs
    if idf.kind != nnkIdentDefs: continue          # skip variant/case parts
    let ftype = idf[^2]
    for i in 0 ..< idf.len - 2:        # `x, y: int` yields several names
      allNames.add idf[i].strVal
      allTypes.add ftype

  # 3. Reject listed fields that don't exist on T (catches typos at compile time).
  for name in listedNames:
    if name notin allNames:
      error("schema(" & T.repr & "): field '" & name & "' is not a field of the type", body)

  # 4. One FieldDef per field of T: listed -> custom schema, else -> structural.
  var fieldDefs = nnkBracket.newTree()
  for fi, fname in allNames:
    var nodeExpr: NimNode
    let idx = listedNames.find(fname)
    if idx >= 0:
      nodeExpr = newDotExpr(listedExprs[idx], ident"node")
    else:
      nodeExpr = newCall(nnkBracketExpr.newTree(bindSym"nodeOf", allTypes[fi]))
    fieldDefs.add newCall(bindSym"fieldDefOf", newLit(fname), nodeExpr)

  result = nnkObjConstr.newTree(
    nnkBracketExpr.newTree(bindSym"Schema", T),
    nnkExprColonExpr.newTree(ident"node",
      nnkObjConstr.newTree(bindSym"Validator",
        nnkExprColonExpr.newTree(ident"kind", bindSym"nkObject"),
        nnkExprColonExpr.newTree(ident"fields", prefix(fieldDefs, "@")))))

macro schema*(T, body: untyped): untyped =
  ## Build an object schema for an *existing* type ``T``, which may be recursive.
  ## Unlike the one-argument form it does not synthesize a type: fields are
  ## validated by the given schema expressions and the value is produced by
  ## ``extract[T]``. Combine with ``lazy`` for self-referential / tree types:
  ##
  ## .. code-block:: nim
  ##   type Node = object
  ##     value*: int
  ##     children*: seq[Node]
  ##
  ##   var node: Schema[Node]
  ##   node = schema(Node):
  ##     value:    int.min(0)
  ##     children: lazy(node).array
  ##
  ## Any field of ``T`` you do *not* list is auto-derived structurally from its
  ## type (required and type-checked, same as `schemaOf`), so omitting a field
  ## never silently drops or zeroes it. A recursive field must be listed (via
  ## `lazy`), since auto-deriving a self-referential field would not terminate.
  newCall(bindSym"deriveSchema", T, body)

macro discriminated*(T: typedesc, disc: untyped): untyped =
  ## Build a discriminated-union schema for a Nim **variant object** ``T``,
  ## dispatching on its enum discriminator field ``disc``. All fields (the ones
  ## shared by every branch and the ones per branch) are validated structurally,
  ## like `schemaOf`, and the correct variant is constructed.
  ##
  ## .. code-block:: nim
  ##   type
  ##     ShapeKind = enum skCircle = "circle", skSquare = "square"
  ##     Shape = object
  ##       label*: string
  ##       case kind*: ShapeKind
  ##       of skCircle: radius*: float
  ##       of skSquare: side*: float
  ##
  ##   let shape = discriminated(Shape, kind)
  ##   let s = shape.parse("""{"kind":"circle","label":"c","radius":2.0}""")
  ##
  ## The JSON discriminator is matched against each enum value's string form
  ## (``$value``), so give the enum explicit string values for clean JSON names.
  disc.expectKind({nnkIdent, nnkSym})
  let discName = disc.strVal

  let impl = objImpl(T)
  if impl.kind != nnkObjectTy:
    error("discriminated(" & T.repr & "): expected a variant object type", disc)

  # FieldDef(name: nm, node: nodeOf[ftype]()) for structural validation
  proc fieldDef(nm: string, ftype: NimNode): NimNode =
    nnkObjConstr.newTree(bindSym"FieldDef",
      nnkExprColonExpr.newTree(ident"name", newLit(nm)),
      nnkExprColonExpr.newTree(ident"node",
        newCall(nnkBracketExpr.newTree(bindSym"nodeOf", ftype))))

  # gather common fields and the case section
  var commonDefs = nnkBracket.newTree()
  var recCase: NimNode = nil
  for n in impl[2]:
    if n.kind == nnkIdentDefs:
      let ftype = n[^2]
      for i in 0 ..< n.len - 2:
        commonDefs.add fieldDef(n[i].strVal, ftype)
    elif n.kind == nnkRecCase:
      recCase = n
  if recCase.isNil:
    error("discriminated(" & T.repr & "): not a variant object (no case field)", disc)
  if recCase[0][0].strVal != discName:
    error("discriminated(" & T.repr & "): discriminator is '" &
      recCase[0][0].strVal & "', not '" & discName & "'", disc)
  let enumImpl = recCase[0][1].getTypeImpl   # EnumTy(Empty, val, val, ...)

  # one VariantBranch per `of` (validation only; `extract` does construction)
  var branchesArr = nnkBracket.newTree()
  for bi in 1 ..< recCase.len:
    let br = recCase[bi]
    if br.kind != nnkOfBranch:
      error("discriminated(" & T.repr & "): `else` branches are not supported", disc)
    let enumSym = enumImpl[br[0].intVal.int + 1]
    var brFieldDefs = nnkBracket.newTree()
    var idfs: seq[NimNode]
    if br[^1].kind == nnkRecList: (for f in br[^1]: idfs.add f)
    else: idfs.add br[^1]
    for f in idfs:
      let ftype = f[^2]
      for i in 0 ..< f.len - 2:
        brFieldDefs.add fieldDef(f[i].strVal, ftype)
    branchesArr.add nnkObjConstr.newTree(bindSym"VariantBranch",
      nnkExprColonExpr.newTree(ident"discValue", prefix(enumSym, "$")),
      nnkExprColonExpr.newTree(ident"fields", prefix(brFieldDefs, "@")))

  result = nnkObjConstr.newTree(
    nnkBracketExpr.newTree(bindSym"Schema", T),
    nnkExprColonExpr.newTree(ident"node",
      nnkObjConstr.newTree(bindSym"Validator",
        nnkExprColonExpr.newTree(ident"kind", bindSym"nkVariant"),
        nnkExprColonExpr.newTree(ident"discName", newLit(discName)),
        nnkExprColonExpr.newTree(ident"common", prefix(commonDefs, "@")),
        nnkExprColonExpr.newTree(ident"branches", prefix(branchesArr, "@")))))

macro tup*(elems: varargs[untyped]): untyped =
  ## A fixed-length, heterogeneous JSON **array** as an anonymous tuple:
  ## ``tup(number(), integer())`` accepts ``[1.5, 2]`` and yields ``(float, int)``
  ## (accessed by index, ``t[0]``). (Named `tuple` is a reserved word, hence `tup`.)
  var tupleTy = nnkTupleConstr.newTree()   # (T0, T1, ...)
  var lets = newStmtList()
  var nodeArr = nnkBracket.newTree()
  var idx = 0
  for e in elems:
    let fv = genSym(nskLet, "el" & $idx)
    lets.add newLetStmt(fv, dslRewrite(e))
    tupleTy.add newCall(ident"typeof", newCall(bindSym"inferVal", fv))
    nodeArr.add newDotExpr(fv, ident"node")
    inc idx
  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(lets,
    nnkObjConstr.newTree(nnkBracketExpr.newTree(bindSym"Schema", tupleTy),
      nnkExprColonExpr.newTree(ident"node",
        nnkObjConstr.newTree(bindSym"Validator",
          nnkExprColonExpr.newTree(ident"kind", bindSym"nkTuple"),
          nnkExprColonExpr.newTree(ident"elems", prefix(nodeArr, "@")))))))

macro namedTuple*(fields: varargs[untyped]): untyped =
  ## A JSON **object** as a *named* tuple; each argument is ``name = schema``:
  ## ``namedTuple(lat = number(), lng = number())`` accepts
  ## ``{"lat":1.0,"lng":2.0}`` and yields ``tuple[lat: float, lng: float]``.
  var tupleTy = nnkTupleTy.newTree()       # tuple[x: T0, y: T1]
  var lets = newStmtList()
  var fieldDefs = nnkBracket.newTree()
  var idx = 0
  for f in fields:
    f.expectKind(nnkExprEqExpr)            # name = schema
    let nm = f[0].strVal
    let fv = genSym(nskLet, "nf" & $idx)
    lets.add newLetStmt(fv, dslRewrite(f[1]))
    tupleTy.add nnkIdentDefs.newTree(ident(nm),
      newCall(ident"typeof", newCall(bindSym"inferVal", fv)), newEmptyNode())
    fieldDefs.add newCall(bindSym"fieldDefOf", newLit(nm), newDotExpr(fv, ident"node"))
    inc idx
  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(lets,
    nnkObjConstr.newTree(nnkBracketExpr.newTree(bindSym"Schema", tupleTy),
      nnkExprColonExpr.newTree(ident"node",
        nnkObjConstr.newTree(bindSym"Validator",
          nnkExprColonExpr.newTree(ident"kind", bindSym"nkObject"),
          nnkExprColonExpr.newTree(ident"fields", prefix(fieldDefs, "@")))))))

# --------------------------------------------------------------------------
# Object algebra: derive a new object schema from existing ones
# --------------------------------------------------------------------------

proc rawNode*[T](s: Schema[T]): Validator = s.node
  ## Expose a schema's validator tree so the algebra macros can transform it.

proc objFields(n: Validator): seq[FieldDef] =
  if not n.isNil and n.kind == nkObject: n.fields else: @[]

proc pickNode*(n: Validator, keep: openArray[string]): Validator =
  result = Validator(kind: nkObject)
  for f in n.objFields:
    if f.name in keep: result.fields.add f

proc omitNode*(n: Validator, drop: openArray[string]): Validator =
  result = Validator(kind: nkObject)
  for f in n.objFields:
    if f.name notin drop: result.fields.add f

proc partialNode*(n: Validator): Validator =
  result = Validator(kind: nkObject)
  for f in n.objFields:                        # already-optional fields stay as-is
    if f.node.kind == nkOptional: result.fields.add f
    else: result.fields.add FieldDef(name: f.name, jsonKey: f.jsonKey,
      node: Validator(kind: nkOptional, inner: f.node))

proc concatNodes*(a, b: Validator): Validator =
  result = Validator(kind: nkObject, fields: a.objFields & b.objFields)

proc objectImpl(node: NimNode): NimNode =
  ## Unwrap `Schema[T]`-typed `node` to T's ObjectTy (compile-time helper).
  var t = getTypeInst(node)[1].getTypeImpl
  if t.kind == nnkBracketExpr: t = t[1].getTypeImpl
  if t.kind == nnkRefTy:
    error("schematic: object algebra (pick/omit/partial/merge/extend) does not " &
          "support ref-object schemas; it derives new value-object types", node)
  t.expectKind(nnkObjectTy)
  t

proc field(nm, ty: NimNode): NimNode =         # `nm*: ty`  (exported field)
  nnkIdentDefs.newTree(nnkPostfix.newTree(ident"*", nm), ty, newEmptyNode())

proc schemaOfType(recFields, nodeExpr: NimNode): NimNode =
  ## block: type Rec = object <recFields>; Schema[Rec](node: nodeExpr)
  let recSym = genSym(nskType, "Rec")
  nnkBlockStmt.newTree(newEmptyNode(), newStmtList(
    nnkTypeSection.newTree(nnkTypeDef.newTree(recSym, newEmptyNode(),
      nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recFields))),
    nnkObjConstr.newTree(nnkBracketExpr.newTree(bindSym"Schema", recSym),
      nnkExprColonExpr.newTree(ident"node", nodeExpr))))

macro pick*(s: typed, keep: varargs[untyped]): untyped =
  ## Derive an object schema keeping only the named fields of ``s``.
  let impl = objectImpl(s)
  var wanted: seq[string]
  var lits = nnkBracket.newTree()
  for k in keep: wanted.add k.strVal; lits.add newLit(k.strVal)
  var recFields = nnkRecList.newTree()
  var seen: seq[string]
  for idf in impl[2]:
    if idf.kind != nnkIdentDefs: continue
    for i in 0 ..< idf.len - 2:
      if idf[i].strVal in wanted:
        seen.add idf[i].strVal
        recFields.add field(ident(idf[i].strVal), idf[^2])
  for w in wanted:
    if w notin seen: error("pick: '" & w & "' is not a field of the schema", s)
  schemaOfType(recFields,
    newCall(bindSym"pickNode", newCall(bindSym"rawNode", s), prefix(lits, "@")))

macro omit*(s: typed, drop: varargs[untyped]): untyped =
  ## Derive an object schema dropping the named fields of ``s``.
  let impl = objectImpl(s)
  var unwanted: seq[string]
  var lits = nnkBracket.newTree()
  for d in drop: unwanted.add d.strVal; lits.add newLit(d.strVal)
  var recFields = nnkRecList.newTree()
  var all: seq[string]
  for idf in impl[2]:
    if idf.kind != nnkIdentDefs: continue
    for i in 0 ..< idf.len - 2:
      all.add idf[i].strVal
      if idf[i].strVal notin unwanted:
        recFields.add field(ident(idf[i].strVal), idf[^2])
  for u in unwanted:
    if u notin all: error("omit: '" & u & "' is not a field of the schema", s)
  schemaOfType(recFields,
    newCall(bindSym"omitNode", newCall(bindSym"rawNode", s), prefix(lits, "@")))

macro partial*(s: typed): untyped =
  ## Derive an object schema with every field made optional (``Option[T]``).
  let impl = objectImpl(s)
  var recFields = nnkRecList.newTree()
  for idf in impl[2]:
    if idf.kind != nnkIdentDefs: continue
    let ft = idf[^2]
    let opt = if ft.kind == nnkBracketExpr and ft[0].strVal == "Option": ft
              else: nnkBracketExpr.newTree(ident"Option", ft)
    for i in 0 ..< idf.len - 2:
      recFields.add field(ident(idf[i].strVal), opt)
  schemaOfType(recFields, newCall(bindSym"partialNode", newCall(bindSym"rawNode", s)))

macro merge*(a, b: typed): untyped =
  ## Combine two object schemas into one (fields of ``a`` then ``b``).
  var recFields = nnkRecList.newTree()
  for impl in [objectImpl(a), objectImpl(b)]:
    for idf in impl[2]:
      if idf.kind != nnkIdentDefs: continue
      for i in 0 ..< idf.len - 2:
        recFields.add field(ident(idf[i].strVal), idf[^2])
  schemaOfType(recFields,
    newCall(bindSym"concatNodes", newCall(bindSym"rawNode", a), newCall(bindSym"rawNode", b)))

macro extend*(s: typed, body: untyped): untyped =
  ## Derive an object schema with the fields of ``s`` plus the new ones in the
  ## block (written with the same DSL as ``schema:``).
  var recFields = nnkRecList.newTree()
  for idf in objectImpl(s)[2]:                 # base fields, kept as-is
    if idf.kind != nnkIdentDefs: continue
    for i in 0 ..< idf.len - 2:
      recFields.add field(ident(idf[i].strVal), idf[^2])
  var lets = newStmtList()                     # new fields, like `schema:`
  var newDefs = nnkBracket.newTree()
  var idx = 0
  for f in body:
    f.expectKind(nnkCall)
    let key = f[0].strVal
    let fv = genSym(nskLet, "ext" & $idx)
    lets.add newLetStmt(fv, dslRewrite(f[1][0]))
    recFields.add field(ident(key), newCall(ident"typeof", newCall(bindSym"inferVal", fv)))
    newDefs.add newCall(bindSym"fieldDefOf", newLit(key), newDotExpr(fv, ident"node"))
    inc idx
  let recSym = genSym(nskType, "Rec")
  let extraNode = nnkObjConstr.newTree(bindSym"Validator",
    nnkExprColonExpr.newTree(ident"kind", bindSym"nkObject"),
    nnkExprColonExpr.newTree(ident"fields", prefix(newDefs, "@")))
  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(lets,
    nnkTypeSection.newTree(nnkTypeDef.newTree(recSym, newEmptyNode(),
      nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recFields))),
    nnkObjConstr.newTree(nnkBracketExpr.newTree(bindSym"Schema", recSym),
      nnkExprColonExpr.newTree(ident"node",
        newCall(bindSym"concatNodes", newCall(bindSym"rawNode", s), extraNode)))))

# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

proc tryParse*[T](s: Schema[T], j: JsonNode): ParseResult[T] =
  ## Parse without raising: inspect ``.ok`` / ``.value`` / ``.issues``.
  var issues: seq[Issue]
  validate(s.node, j, "", issues)
  if issues.len == 0:
    ParseResult[T](ok: true, value: extract[T](normalize(s.node, j)))
  else:
    ParseResult[T](ok: false, issues: issues)

proc tryParse*[T](s: Schema[T], data: string): ParseResult[T] =
  ## Parse a JSON string without raising.
  var node: JsonNode
  try: node = parseJson(data)
  except JsonParsingError as e:
    return ParseResult[T](ok: false,
      issues: @[Issue(path: "(root)", message: "invalid JSON: " & e.msg)])
  s.tryParse(node)

proc raiseIssues(issues: seq[Issue]) {.noreturn.} =
  var e = newException(ValidationError, "validation failed with " &
    $issues.len & " issue(s):\n" & issues.mapIt($it).join("\n"))
  e.issues = issues
  raise e

proc parse*[T](s: Schema[T], j: JsonNode): T =
  ## Parse and validate, raising ``ValidationError`` with all issues on failure.
  let r = s.tryParse(j)
  if r.ok: r.value else: raiseIssues(r.issues)

proc parse*[T](s: Schema[T], data: string): T =
  ## Parse a JSON string and validate, raising on failure.
  let r = s.tryParse(data)
  if r.ok: r.value else: raiseIssues(r.issues)

proc tryValidate*[T](s: Schema[T], value: T): ParseResult[T] =
  ## Re-validate an existing (e.g. mutated) value against the schema, without
  ## raising. Parsing yields a plain object, so constraints are *not* re-checked
  ## on later field assignment; call this to re-check on demand. Equivalent to
  ## round-tripping through JSON: ``s.tryParse(%value)``.
  s.tryParse(%value)

proc validate*[T](s: Schema[T], value: T): T =
  ## Re-validate an existing value, raising ``ValidationError`` on failure and
  ## returning the (validated) value otherwise.
  s.parse(%value)
