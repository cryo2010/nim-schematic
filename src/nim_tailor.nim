## nim-tailor: a minimalist object validation & JSON-parsing library for Nim.
##
## Design in one line: a schema is a value of type ``Schema[T]``. Building a
## schema with the combinator API gives you, for free, the static Nim type it
## produces. That is the Zod ``z.infer`` trick, but leaning on Nim's real
## compile-time types instead of faking them.
##
## .. code-block:: nim
##
##   import nim_tailor
##
##   let user = schema:
##     name:  string.min(2).max(50)
##     age:   int.min(0).max(150)
##     email: string.email.optional
##     tags:  string.array.default(@[])
##
##   type User = Infer(user)          # tuple[name: string, age: int,
##                                    #       email: Option[string], tags: seq[string]]
##
##   let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io"}""")
##   echo u.name          # statically typed field access
##
## (Nim shares one namespace for types and values, so the schema value and the
## inferred type need different names, e.g. ``user`` and ``User``.)
##
## See ``DESIGN.md`` for the rationale.

import std/[json, options, macros, strutils, sequtils]
export json, options   # so `JsonNode`, `Option`, `some`/`none` are in scope
                       # for callers and for `schema`-generated code

# --------------------------------------------------------------------------
# Errors & validation context
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

  Ctx* = object
    ## Internal parsing context: the current path and accumulated issues.
    path: seq[string]
    issues: seq[Issue]

  Schema*[T] = object
    ## A validator that turns a ``JsonNode`` into a ``T`` (or records issues).
    ## ``T`` is exactly the static type produced on success.
    run*: proc(j: JsonNode, ctx: var Ctx): T {.closure.}

  ParseResult*[T] = object
    ## Result of ``tryParse``. Either ``ok`` with a ``value`` or a list of ``issues``.
    ok*: bool
    value*: T
    issues*: seq[Issue]

proc curPath(ctx: Ctx): string =
  for i, p in ctx.path:
    if p.len > 0 and p[0] == '[': result.add p        # array index, no dot
    elif i == 0: result.add p
    else: result.add "." & p
  if result.len == 0: result = "(root)"

proc fail*(ctx: var Ctx, msg: string) =
  ## Record a validation issue at the current path.
  ctx.issues.add Issue(path: ctx.curPath, message: msg)

proc pushPath*(ctx: var Ctx, seg: string) =
  ## Descend into a field or array element (used by combinators and the DSL).
  ctx.path.add seg

proc popPath*(ctx: var Ctx) =
  ## Ascend back out of the last `pushPath`.
  discard ctx.path.pop

template withPath(ctx: var Ctx, seg: string, body: untyped) =
  ctx.pushPath seg
  body
  ctx.popPath()

proc `$`*(issue: Issue): string =
  issue.path & ": " & issue.message

proc `$`*(err: ValidationError): string =
  err.issues.mapIt($it).join("\n")

# --------------------------------------------------------------------------
# Primitive schemas
# --------------------------------------------------------------------------

proc str*(): Schema[string] =
  ## Matches a JSON string.
  Schema[string](run: proc(j: JsonNode, ctx: var Ctx): string =
    if j.isNil or j.kind == JNull: ctx.fail("required"); return ""
    if j.kind != JString: ctx.fail("expected string, got " & $j.kind); return ""
    j.getStr)

proc integer*(): Schema[int] =
  ## Matches a JSON integer.
  Schema[int](run: proc(j: JsonNode, ctx: var Ctx): int =
    if j.isNil or j.kind == JNull: ctx.fail("required"); return 0
    if j.kind != JInt: ctx.fail("expected integer, got " & $j.kind); return 0
    j.getInt)

proc number*(): Schema[float] =
  ## Matches a JSON number (integer or float).
  Schema[float](run: proc(j: JsonNode, ctx: var Ctx): float =
    if j.isNil or j.kind == JNull: ctx.fail("required"); return 0.0
    case j.kind
    of JFloat: j.getFloat
    of JInt: j.getInt.float
    else: ctx.fail("expected number, got " & $j.kind); 0.0)

proc boolean*(): Schema[bool] =
  ## Matches a JSON boolean.
  Schema[bool](run: proc(j: JsonNode, ctx: var Ctx): bool =
    if j.isNil or j.kind == JNull: ctx.fail("required"); return false
    if j.kind != JBool: ctx.fail("expected boolean, got " & $j.kind); return false
    j.getBool)

# --------------------------------------------------------------------------
# Refinements (run only if the value parsed cleanly)
# --------------------------------------------------------------------------

proc refine*[T](s: Schema[T], message: string, ok: proc(v: T): bool): Schema[T] =
  ## Add a custom predicate. The check is skipped if the inner parse already
  ## failed, so you never get a spurious "invalid" on top of "expected string".
  let inner = s.run
  Schema[T](run: proc(j: JsonNode, ctx: var Ctx): T =
    let before = ctx.issues.len
    result = inner(j, ctx)
    if ctx.issues.len == before and not ok(result):
      ctx.fail(message))

proc min*(s: Schema[int], n: int): Schema[int] =
  s.refine("must be >= " & $n, proc(v: int): bool = v >= n)
proc max*(s: Schema[int], n: int): Schema[int] =
  s.refine("must be <= " & $n, proc(v: int): bool = v <= n)
proc min*(s: Schema[float], n: float): Schema[float] =
  s.refine("must be >= " & $n, proc(v: float): bool = v >= n)
proc max*(s: Schema[float], n: float): Schema[float] =
  s.refine("must be <= " & $n, proc(v: float): bool = v <= n)

proc min*(s: Schema[string], n: int): Schema[string] =
  ## Minimum string length.
  s.refine("must be at least " & $n & " chars", proc(v: string): bool = v.len >= n)
proc max*(s: Schema[string], n: int): Schema[string] =
  ## Maximum string length.
  s.refine("must be at most " & $n & " chars", proc(v: string): bool = v.len <= n)
proc nonempty*(s: Schema[string]): Schema[string] =
  s.refine("must not be empty", proc(v: string): bool = v.len > 0)

proc email*(s: Schema[string]): Schema[string] =
  ## Cheap structural email check (a real one would use std/re).
  s.refine("must be a valid email", proc(v: string): bool =
    let at = v.find('@')
    at > 0 and at < v.high and v.rfind('.') > at)

proc oneOf*(s: Schema[string], choices: openArray[string]): Schema[string] =
  ## Enum-style constraint: value must be one of ``choices``.
  let allowed = @choices
  s.refine("must be one of " & allowed.join(", "),
    proc(v: string): bool = v in allowed)

proc min*[T](s: Schema[seq[T]], n: int): Schema[seq[T]] =
  ## Minimum array length.
  s.refine("must have at least " & $n & " items", proc(v: seq[T]): bool = v.len >= n)
proc max*[T](s: Schema[seq[T]], n: int): Schema[seq[T]] =
  ## Maximum array length.
  s.refine("must have at most " & $n & " items", proc(v: seq[T]): bool = v.len <= n)

# --------------------------------------------------------------------------
# Modifiers & composition
# --------------------------------------------------------------------------

proc optional*[T](s: Schema[T]): Schema[Option[T]] =
  ## A missing key or JSON ``null`` becomes ``none(T)``; otherwise ``some``.
  ## Changes the produced type to ``Option[T]``.
  let inner = s.run
  Schema[Option[T]](run: proc(j: JsonNode, ctx: var Ctx): Option[T] =
    if j.isNil or j.kind == JNull: none(T)
    else: some(inner(j, ctx)))

proc default*[T](s: Schema[T], d: T): Schema[T] =
  ## Substitute ``d`` when the key is missing or ``null``. Keeps type ``T``.
  let inner = s.run
  Schema[T](run: proc(j: JsonNode, ctx: var Ctx): T =
    if j.isNil or j.kind == JNull: d
    else: inner(j, ctx))

proc array*[T](s: Schema[T]): Schema[seq[T]] =
  ## Matches a JSON array of ``s``, producing ``seq[T]``.
  let inner = s.run
  Schema[seq[T]](run: proc(j: JsonNode, ctx: var Ctx): seq[T] =
    if j.isNil or j.kind == JNull: ctx.fail("required"); return
    if j.kind != JArray: ctx.fail("expected array, got " & $j.kind); return
    for i, el in j.elems:
      ctx.withPath("[" & $i & "]"):
        result.add inner(el, ctx))

# --------------------------------------------------------------------------
# Object schema DSL (compile-time type inference)
# --------------------------------------------------------------------------

proc fieldOf*(j: JsonNode, key: string): JsonNode =
  ## Fetch a field, or a JNull node if absent (so schemas see "null" uniformly).
  if not j.isNil and j.kind == JObject and j.hasKey(key): j[key]
  else: newJNull()

proc inferVal*[T](s: Schema[T]): T = discard
  ## Never executed; used only inside ``typeof`` to recover ``T`` from a schema.

proc dslRewrite(n: NimNode): NimNode =
  ## Inside the DSL, let bare type names read as schema constructors:
  ## ``string`` -> ``str()``, ``int`` -> ``integer()``, etc.
  if n.kind == nnkIdent:
    case n.strVal
    of "string": return newCall(ident"str")
    of "int": return newCall(ident"integer")
    of "float": return newCall(ident"number")
    of "bool": return newCall(ident"boolean")
    else: return n
  result = copyNimNode(n)
  for c in n: result.add dslRewrite(c)

macro schema*(body: untyped): untyped =
  ## Build an object schema. Each ``key: schemaExpr`` line contributes a field;
  ## the produced type is a named tuple whose field types are inferred from the
  ## schema expressions. Recover that type with ``Infer(theSchema)``.
  var recFields = nnkTupleTy.newTree()
  var lets = newStmtList()
  var assigns = newStmtList()
  let jsym = ident"j"
  let ctxsym = ident"ctx"

  # object-kind guard
  assigns.add quote do:
    if `jsym`.isNil or `jsym`.kind != JObject:
      `ctxsym`.fail("expected object, got " &
        (if `jsym`.isNil: "null" else: $`jsym`.kind))
      return

  var idx = 0
  for f in body:
    f.expectKind(nnkCall)             # key: expr  ->  Call(Ident, StmtList(expr))
    let key = f[0].strVal
    let expr = dslRewrite(f[1][0])
    let fv = ident("tailorField" & $idx)
    lets.add newLetStmt(fv, expr)
    # tuple field:  key: typeof(inferVal(fieldN))
    recFields.add nnkIdentDefs.newTree(
      ident(key),
      newCall(ident"typeof", newCall(bindSym"inferVal", fv)),
      newEmptyNode())
    # body:  ctx.pushPath("key")
    #        result.key = fieldN.run(fieldOf(j,"key"), ctx)
    #        ctx.popPath()
    let doAssign = newAssignment(
      newDotExpr(ident"result", ident(key)),
      newCall(newDotExpr(fv, ident"run"),
        newCall(bindSym"fieldOf", jsym, newLit(key)), ctxsym))
    assigns.add newCall(bindSym"pushPath", ctxsym, newLit(key))
    assigns.add doAssign
    assigns.add newCall(bindSym"popPath", ctxsym)
    inc idx

  let recSym = genSym(nskType, "Rec")
  let prc = newProc(
    params = @[recSym,
      nnkIdentDefs.newTree(jsym, ident"JsonNode", newEmptyNode()),
      nnkIdentDefs.newTree(ctxsym, nnkVarTy.newTree(ident"Ctx"), newEmptyNode())],
    body = assigns,
    procType = nnkLambda,             # anonymous proc expression in the objconstr
    pragmas = nnkPragma.newTree(ident"closure"))

  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(
    lets,
    nnkTypeSection.newTree(nnkTypeDef.newTree(recSym, newEmptyNode(), recFields)),
    nnkObjConstr.newTree(
      nnkBracketExpr.newTree(bindSym"Schema", recSym),
      nnkExprColonExpr.newTree(ident"run", prc))))

macro Infer*(s: typed): untyped =
  ## Recover the produced type ``T`` from a ``Schema[T]`` value.
  ## ``type User = Infer(userSchema)``.
  getTypeInst(s)[1]

# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

proc tryParse*[T](s: Schema[T], j: JsonNode): ParseResult[T] =
  ## Parse without raising: inspect ``.ok`` / ``.value`` / ``.issues``.
  var ctx = Ctx()
  let v = s.run(j, ctx)
  if ctx.issues.len == 0: ParseResult[T](ok: true, value: v)
  else: ParseResult[T](ok: false, issues: ctx.issues)

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
