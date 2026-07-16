## nim-tailor: a minimalist object validation & JSON-parsing library for Nim.
##
## Design in one line: a schema is a value of type ``Schema[T]``. Building a
## schema with the combinator API gives you, for free, the static Nim type it
## produces. That is the Zod ``z.infer`` trick, but leaning on Nim's real
## compile-time types instead of faking them.
##
## .. code-block:: nim
##
##   import tailor
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

import std/[json, options, macros, strutils, sequtils]
export json, options   # so `JsonNode`, `Option`, `some`/`none` are in scope
                       # for callers and for `schema`-generated code

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
    ckMinItems, ckMaxItems, ckCustom

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
    of ckCustom:
      predicate: proc(j: JsonNode): bool {.closure.}
    of ckNonEmpty, ckEmail:
      discard

  NodeKind = enum
    nkStr, nkInt, nkFloat, nkBool, nkCheck, nkOptional, nkDefault, nkArray, nkObject

  FieldDef = object
    name: string
    node: Validator

  Validator = ref object
    inner: Validator            ## wrapped node for check/optional/default/array
    case kind: NodeKind
    of nkCheck: check: Check
    of nkDefault: defJson: JsonNode
    of nkObject: fields: seq[FieldDef]
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
  elif T is Option:
    if j.isNil or j.kind == JNull: none(typeof(get(default(T))))
    else: some(extract[typeof(get(default(T)))](j))
  elif T is seq:
    if not j.isNil and j.kind == JArray:
      for e in j.elems: result.add extract[typeof(default(T)[0])](e)
  elif T is (object or tuple):        # Option/seq are matched above
    for key, val in result.fieldPairs:
      let sub = if not j.isNil and j.kind == JObject and j.hasKey(key): j[key]
                else: newJNull()
      val = extract[typeof(val)](sub)
  else:
    {.error: "nim-tailor: cannot extract unsupported type " & $T.}

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
  ## Cheap structural email check (a real one would use std/re).
  s.withCheck(Check(kind: ckEmail, message: "must be a valid email"))
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
  of nkObject:
    if j.isMissing: issues.add Issue(path: here, message: "required")
    elif j.kind != JObject: issues.add Issue(path: here, message: "expected object, got " & $j.kind)
    else:
      for fld in v.fields:
        let sub = if j.hasKey(fld.name): j[fld.name] else: newJNull()
        validate(fld.node, sub, join2(path, fld.name), issues)

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
  of nkObject:
    result = newJObject()
    for fld in v.fields:
      let sub = if not j.isNil and j.kind == JObject and j.hasKey(fld.name): j[fld.name]
                else: newJNull()
      result[fld.name] = normalize(fld.node, sub)
  else:
    result = if j.isNil: newJNull() else: j

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
    # FieldDef(name: "key", node: fieldN.node)
    fieldDefs.add nnkObjConstr.newTree(
      bindSym"FieldDef",
      nnkExprColonExpr.newTree(ident"name", newLit(key)),
      nnkExprColonExpr.newTree(ident"node", newDotExpr(fv, ident"node")))
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
