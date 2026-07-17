import unittest
import std/[json, options, strutils, sequtils]
import schematic

let user = schema:
  name:  string.min(2).max(50)
  age:   int.min(0).max(150)
  email: string.email.optional
  tags:  string.array.default(@[])

type User = Infer(user)

let address = schema:
  city: string.nonempty
  zip:  string

let account = schema:
  id:      int
  owner:   user            # nested schema by value
  address: address.optional
  role:    string.oneOf(["admin", "user", "guest"])

suite "primitives & inference":

  test "inferred type should have the right static shape":
    var u: User
    u.name = "Ada"
    u.age = 36
    u.email = some("ada@example.com")
    u.tags = @["math"]
    check u.name == "Ada"
    check u.email.isSome

  test "inferred type should be a nominal object":
    check User is object
    check not (User is tuple)
    # a nested schema-by-value field is itself an object
    let a = account.parse("""{"id":1,"owner":{"name":"Ada","age":5},"role":"user"}""")
    check typeof(a.owner) is object
    check a.owner.name == "Ada"

  test "parse should extract all fields when the object is valid":
    let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io","tags":["a","b"]}""")
    check u.name == "Ada"
    check u.age == 36
    check u.email == some("ada@x.io")
    check u.tags == @["a", "b"]

  test "optional field should be none when absent":
    let u = user.parse("""{"name":"Bo","age":1}""")
    check u.email.isNone

  test "default field should use its default when absent":
    let u = user.parse("""{"name":"Bo","age":1}""")
    check u.tags.len == 0

suite "validation errors":

  test "tryParse should collect all issues at once":
    let r = user.tryParse("""{"name":"A","age":999,"email":"nope"}""")
    check not r.ok
    check r.issues.len == 3            # name too short, age too big, bad email

  test "issue should carry the field path":
    let r = user.tryParse("""{"name":"A","age":5}""")
    check r.issues[0].path == "name"

  test "tryParse should report a type mismatch":
    let r = user.tryParse("""{"name":123,"age":5}""")
    check not r.ok
    check r.issues[0].message.contains("expected string")

  test "tryParse should report a missing required field":
    let r = user.tryParse("""{"age":5}""")
    check r.issues.anyIt(it.path == "name" and it.message == "required")

  test "parse should raise ValidationError when the input is invalid":
    expect ValidationError:
      discard user.parse("""{"name":"A","age":999}""")

  test "tryParse should report an error for invalid JSON":
    let r = user.tryParse("""{not json""")
    check not r.ok
    check r.issues[0].message.contains("invalid JSON")

suite "composition":

  test "issue path should include the nested object prefix":
    let r = account.tryParse("""
      {"id":1,"owner":{"name":"A","age":5},
       "address":{"city":"","zip":"12345"},"role":"admin"}""")
    check not r.ok
    check r.issues.anyIt(it.path == "owner.name")
    check r.issues.anyIt(it.path == "address.city")

  test "parse should build nested objects when valid":
    let a = account.parse("""
      {"id":1,"owner":{"name":"Ada","age":5},
       "address":{"city":"NYC","zip":"10001"},"role":"user"}""")
    check a.owner.name == "Ada"
    check a.address.isSome
    check a.address.get.city == "NYC"

  test "optional nested object should be none when absent":
    let a = account.parse("""
      {"id":1,"owner":{"name":"Ada","age":5},"role":"guest"}""")
    check a.address.isNone

suite "modifiers":

  let opt = schema:
    v: int.min(0).optional
  let def = schema:
    v: int.min(0).default(7)
  let arr = schema:
    xs: int.array

  test "optional should be none when the key is absent":
    check opt.parse("""{}""").v.isNone
  test "optional should be none when the value is null":
    check opt.parse("""{"v":null}""").v.isNone
  test "optional should be some when the value is present":
    check opt.parse("""{"v":3}""").v == some(3)
  test "optional should validate the inner value when present":
    check not opt.tryParse("""{"v":-1}""").ok

  test "default should use the default when the key is absent":
    check def.parse("""{}""").v == 7
  test "default should use the default when the value is null":
    check def.parse("""{"v":null}""").v == 7
  test "default should keep the value when present":
    check def.parse("""{"v":3}""").v == 3
  test "default should validate the value when present":
    check not def.tryParse("""{"v":-1}""").ok

  test "array should parse each element":
    check arr.parse("""{"xs":[1,2,3]}""").xs == @[1, 2, 3]
  test "array should produce an empty seq for an empty array":
    check arr.parse("""{"xs":[]}""").xs.len == 0
  test "array should reject a non-array value":
    let r = arr.tryParse("""{"xs":5}""")
    check not r.ok
    check r.issues.anyIt(it.path == "xs" and it.message.contains("expected array"))
  test "array should report the failing element with its index":
    let r = arr.tryParse("""{"xs":[1,"x",3]}""")
    check r.issues.anyIt(it.path == "xs[1]")

  test "lazy should resolve a schema assigned after it is referenced":
    var later: Schema[int]
    let holder = schema:
      n: lazy(later)
    later = integer().min(0)          # assigned after lazy(later) was referenced
    check holder.parse("""{"n":5}""").n == 5
    check not holder.tryParse("""{"n":-1}""").ok

suite "refinements":

  let numBound = schema:
    n: int.min(0).max(150)
  let floatBound = schema:
    x: float.min(1.0).max(2.0)
  let lenBound = schema:
    s: string.min(2).max(4)
  let nonEmpty = schema:
    s: string.nonempty
  let emailField = schema:
    e: string.email
  let choice = schema:
    r: string.oneOf(["red", "green"])
  let seqBound = schema:
    xs: int.array.min(2).max(3)
  let zipCode = schema:
    zip: string.pattern(r"\d{5}(-\d{4})?")

  test "min should reject a number below the bound":
    check not numBound.tryParse("""{"n":-1}""").ok
  test "min should accept a number at the lower bound":
    check numBound.tryParse("""{"n":0}""").ok
  test "max should reject a number above the bound":
    check not numBound.tryParse("""{"n":151}""").ok
  test "max should accept a number at the upper bound":
    check numBound.tryParse("""{"n":150}""").ok

  test "min should reject a float below the bound":
    check not floatBound.tryParse("""{"x":0.5}""").ok
  test "max should reject a float above the bound":
    check not floatBound.tryParse("""{"x":2.5}""").ok
  test "number bounds should accept a float within range":
    check floatBound.tryParse("""{"x":1.5}""").ok

  test "min should reject a string shorter than the length":
    check not lenBound.tryParse("""{"s":"a"}""").ok
  test "min should accept a string at the minimum length":
    check lenBound.tryParse("""{"s":"ab"}""").ok
  test "max should reject a string longer than the length":
    check not lenBound.tryParse("""{"s":"abcde"}""").ok
  test "max should accept a string at the maximum length":
    check lenBound.tryParse("""{"s":"abcd"}""").ok

  test "nonempty should reject an empty string":
    check not nonEmpty.tryParse("""{"s":""}""").ok
  test "nonempty should accept a non-empty string":
    check nonEmpty.tryParse("""{"s":"x"}""").ok

  test "email should reject a malformed address":
    check not emailField.tryParse("""{"e":"nope"}""").ok
  test "email should accept a valid address":
    check emailField.tryParse("""{"e":"ada@example.com"}""").ok

  test "oneOf should reject an unlisted value":
    check not choice.tryParse("""{"r":"blue"}""").ok
  test "oneOf should accept a listed value":
    check choice.tryParse("""{"r":"green"}""").ok

  test "min should reject a seq with too few items":
    check not seqBound.tryParse("""{"xs":[1]}""").ok
  test "min should accept a seq at the minimum length":
    check seqBound.tryParse("""{"xs":[1,2]}""").ok
  test "max should reject a seq with too many items":
    check not seqBound.tryParse("""{"xs":[1,2,3,4]}""").ok
  test "max should accept a seq at the maximum length":
    check seqBound.tryParse("""{"xs":[1,2,3]}""").ok

  test "pattern should accept a string that matches":
    check zipCode.tryParse("""{"zip":"12345"}""").ok
    check zipCode.tryParse("""{"zip":"12345-6789"}""").ok
  test "pattern should reject a string that does not match":
    let r = zipCode.tryParse("""{"zip":"nope"}""")
    check r.issues.anyIt(it.path == "zip" and it.message.contains("must match pattern"))
  test "pattern should be anchored to the whole string":
    check not zipCode.tryParse("""{"zip":"x12345"}""").ok   # a partial match is rejected

suite "custom refine":

  let even = schema:
    n: int.refine("must be even", proc(v: int): bool = v mod 2 == 0)

  test "refine should accept a value that satisfies the predicate":
    check even.tryParse("""{"n":4}""").ok

  test "refine should reject a value that fails the predicate with its message":
    let r = even.tryParse("""{"n":3}""")
    check not r.ok
    check r.issues.anyIt(it.path == "n" and it.message == "must be even")

  test "refine should skip its check when the inner value is invalid":
    let r = even.tryParse("""{"n":"oops"}""")
    check r.issues.len == 1                # only "expected integer", not "must be even"
    check r.issues[0].message.contains("expected integer")

type Comment = object          # a recursive (tree) type
  text*: string
  replies*: seq[Comment]

suite "recursion":

  var comment: Schema[Comment]
  comment = schema(Comment):
    text:    string.min(1)
    replies: lazy(comment).array.default(@[])   # leaves may omit `replies`

  test "parse should read an arbitrarily nested tree":
    let c = comment.parse("""
      {"text":"root","replies":[
        {"text":"a","replies":[]},
        {"text":"b","replies":[{"text":"b1","replies":[]}]}]}""")
    check c.text == "root"
    check c.replies.len == 2
    check c.replies[1].replies[0].text == "b1"

  test "recursive schema should report deep error paths":
    let r = comment.tryParse("""
      {"text":"root","replies":[{"text":"","replies":[]}]}""")
    check not r.ok
    check r.issues.anyIt(it.path == "replies[0].text")

  test "recursive schema should default a missing seq to empty":
    let c = comment.parse("""{"text":"leaf"}""")
    check c.replies.len == 0

suite "re-validation":

  test "tryValidate should report issues for a mutated value":
    var u = user.parse("""{"name":"Ada","age":36}""")
    check user.tryValidate(u).ok            # valid to begin with
    u.age = 999                             # mutate to invalid values
    u.name = "A"
    let r = user.tryValidate(u)
    check not r.ok
    check r.issues.anyIt(it.path == "age")
    check r.issues.anyIt(it.path == "name")

  test "validate should raise on an invalid value":
    var u = user.parse("""{"name":"Ada","age":36}""")
    u.age = -1
    expect ValidationError:
      discard user.validate(u)
    u.age = 40                              # fix it
    check user.validate(u).age == 40

type
  Point = object
    x*, y*: int
  Box = object
    label*:  string
    corner*: Point            # nested object type

suite "schemaOf":

  let box = schemaOf(Box)

  test "schemaOf should parse every field of an existing type":
    let b = box.parse("""{"label":"a","corner":{"x":1,"y":2}}""")
    check b.label == "a"
    check b.corner.x == 1

  test "schemaOf should report a missing nested field with its path":
    let r = box.tryParse("""{"label":"a","corner":{"x":1}}""")
    check not r.ok
    check r.issues.anyIt(it.path == "corner.y" and it.message == "required")

  test "schemaOf should preserve the nominal type inside a schema DSL":
    let thing = schema:
      id:    int
      where: schemaOf(Point)
    let t = thing.parse("""{"id":1,"where":{"x":3,"y":4}}""")
    check t.where is Point
    check t.where.x == 3

type Profile = object
  name*:   string
  age*:    int
  active*: bool

suite "schema(T) with omitted fields":

  let profile = schema(Profile):     # only `name` is constrained
    name: string.min(2)              # age and active are auto-derived structurally

  test "schema(T) should keep an omitted field's value from the JSON":
    let p = profile.parse("""{"name":"Ada","age":36,"active":true}""")
    check p.age == 36
    check p.active

  test "schema(T) should require an omitted field":
    check not profile.tryParse("""{"name":"Ada","age":36}""").ok   # active missing

  test "schema(T) should type-check an omitted field":
    let r = profile.tryParse("""{"name":"Ada","age":"x","active":true}""")
    check r.issues.anyIt(it.path == "age" and it.message.contains("expected integer"))

  test "schema(T) should still constrain a listed field":
    let r = profile.tryParse("""{"name":"A","age":36,"active":true}""")
    check r.issues.anyIt(it.path == "name")

  test "schema(T) should reject a listed field that is not on the type":
    template badField(): untyped =
      schema(Profile):
        bogus: int
    check not compiles(badField())

type Record = object
  id*:   int
  data*: JsonNode

suite "json passthrough":

  let evt = schema:
    name:    string.min(1)
    payload: JsonNode              # any JSON, via the DSL type sugar
    extra:   json().optional       # optional passthrough

  test "json should pass an arbitrary value through unchanged":
    let e = evt.parse("""{"name":"c","payload":{"x":[1,2],"b":true}}""")
    check e.payload["x"][1].getInt == 2
    check e.payload["b"].getBool

  test "json field infers a JsonNode type":
    let e = evt.parse("""{"name":"c","payload":true}""")
    check e.payload is JsonNode

  test "json should require a present value":
    let r = evt.tryParse("""{"name":"c"}""")
    check r.issues.anyIt(it.path == "payload" and it.message == "required")

  test "optional json should be none when absent":
    let e = evt.parse("""{"name":"c","payload":1}""")
    check e.extra.isNone

  test "schemaOf should handle a JsonNode field":
    let rec = schemaOf(Record)
    check rec.parse("""{"id":1,"data":{"any":"thing"}}""").data["any"].getStr == "thing"

type
  ShapeKind = enum skCircle = "circle", skSquare = "square"
  Shape = object
    label*: string                 # common field, present in every branch
    case kind*: ShapeKind
    of skCircle: radius*: float
    of skSquare:
      side*:   float
      filled*: bool
  ShapeBox = object                # a normal type with a variant-typed field
    note*:  string
    shape*: Shape

suite "discriminated unions":

  let shape = discriminated(Shape, kind)

  test "discriminated should build the branch selected by the tag":
    let c = shape.parse("""{"kind":"circle","label":"c","radius":2.5}""")
    check c.kind == skCircle
    check c.label == "c"
    check c.radius == 2.5
    let s = shape.parse("""{"kind":"square","label":"s","side":3.0,"filled":true}""")
    check s.kind == skSquare
    check s.side == 3.0
    check s.filled

  test "discriminated should reject an unknown tag":
    let r = shape.tryParse("""{"kind":"triangle","label":"x"}""")
    check r.issues.anyIt(it.path == "kind" and it.message.contains("must be one of"))

  test "discriminated should require the discriminator":
    let r = shape.tryParse("""{"label":"x"}""")
    check r.issues.anyIt(it.path == "kind" and it.message == "required")

  test "discriminated should validate a common field in every branch":
    let r = shape.tryParse("""{"kind":"circle","label":5,"radius":1.0}""")
    check r.issues.anyIt(it.path == "label" and it.message.contains("expected string"))

  test "discriminated should type-check a branch field":
    let r = shape.tryParse("""{"kind":"circle","label":"x","radius":"nope"}""")
    check r.issues.anyIt(it.path == "radius" and it.message.contains("expected number"))

  test "discriminated should require a missing branch field":
    let r = shape.tryParse("""{"kind":"square","label":"x","side":1.0}""")
    check r.issues.anyIt(it.path == "filled" and it.message == "required")

  test "discriminated should nest inside an inference-first schema":
    let envelope = schema:
      id:    int
      shape: shape                    # nested discriminated union
    let e = envelope.parse("""{"id":1,"shape":{"kind":"circle","label":"c","radius":2.0}}""")
    check e.shape.kind == skCircle
    check e.shape.radius == 2.0
    let r = envelope.tryParse("""{"id":1,"shape":{"kind":"triangle","label":"c"}}""")
    check r.issues.anyIt(it.path == "shape.kind")   # deep path through the variant

  test "discriminated should nest inside a schema(T) object":
    let box = schema(ShapeBox):
      note:  string
      shape: shape
    let b = box.parse("""{"note":"n","shape":{"kind":"square","label":"s","side":1.0,"filled":false}}""")
    check b.shape.kind == skSquare
    check b.shape.side == 1.0

suite "object algebra":

  let person = schema:
    name:  string.min(2)
    age:   int.min(0)
    email: string.email.optional

  test "pick should keep only the named fields":
    let creds = pick(person, name, email)
    let c = creds.parse("""{"name":"Ada","email":"a@b.co"}""")
    check c.name == "Ada"
    check c.email == some("a@b.co")
    check not compiles(c.age)                 # `age` was dropped

  test "pick should no longer require the dropped fields":
    let creds = pick(person, name)
    check creds.tryParse("""{"name":"Ada"}""").ok

  test "pick should reject an unknown field at compile time":
    template bad(): untyped = pick(person, bogus)
    check not compiles(bad())

  test "omit should drop the named fields":
    let bare = omit(person, email)
    let o = bare.parse("""{"name":"Ada","age":5}""")
    check o.name == "Ada" and o.age == 5
    check not compiles(o.email)

  test "partial should make every field optional":
    let up = partial(person)
    check up.parse("""{}""").name.isNone
    check up.parse("""{"name":"Bo"}""").name == some("Bo")

  test "partial should still validate a present value":
    let up = partial(person)
    check not up.tryParse("""{"age":-1}""").ok

  test "merge should combine two schemas":
    let extra = schema:
      role: string.oneOf(["admin", "user"])
    let m = merge(person, extra)
    let v = m.parse("""{"name":"Ada","age":5,"role":"admin"}""")
    check v.name == "Ada" and v.role == "admin"

  test "extend should add fields to a base schema":
    let admin = extend(person):
      role: string.oneOf(["admin"])
    let a = admin.parse("""{"name":"Ada","age":5,"role":"admin"}""")
    check a.role == "admin"
    check not admin.tryParse("""{"name":"A","age":5,"role":"admin"}""").ok   # base rule
    check not admin.tryParse("""{"name":"Ada","age":5,"role":"root"}""").ok  # new rule

suite "records":

  let cfg = schema:
    limits: record(integer().min(0))          # Table[string, int]

  test "record should parse a Table of values":
    let c = cfg.parse("""{"limits":{"cpu":4,"mem":8}}""")
    check c.limits["cpu"] == 4
    check c.limits.len == 2

  test "record should validate each value with the key in the path":
    let r = cfg.tryParse("""{"limits":{"cpu":-1}}""")
    check r.issues.anyIt(it.path == "limits.cpu")

  test "record should reject a non-object":
    check not cfg.tryParse("""{"limits":5}""").ok

suite "field aliases":

  let acct = schema:
    userName: string.min(1).alias("user_name")
    age:      int

  test "alias should read from the JSON key but keep the Nim field name":
    let u = acct.parse("""{"user_name":"ada","age":36}""")
    check u.userName == "ada"
    check u.age == 36

  test "alias should use the JSON key in error paths":
    let r = acct.tryParse("""{"user_name":"","age":36}""")
    check r.issues.anyIt(it.path == "user_name")

  test "alias should require the JSON key, not the field name":
    check not acct.tryParse("""{"userName":"ada","age":36}""").ok

suite "uuid / date / timestamp":

  let doc = schema:
    id:  string.uuid
    day: string.date
    at:  timestamp()

  test "uuid should accept a UUID and reject others":
    check doc.tryParse("""{"id":"12345678-1234-1234-1234-123456789abc","day":"2024-01-02","at":1700000000}""").ok
    check not doc.tryParse("""{"id":"nope","day":"2024-01-02","at":1700000000}""").ok

  test "date should require YYYY-MM-DD":
    check not doc.tryParse("""{"id":"12345678-1234-1234-1234-123456789abc","day":"jan 2","at":1700000000}""").ok

  test "timestamp should produce a Time from unix seconds":
    let v = doc.parse("""{"id":"12345678-1234-1234-1234-123456789abc","day":"2024-01-02","at":1700000000}""")
    check v.at == fromUnix(1700000000)

  test "timestamp should reject a non-integer":
    check not doc.tryParse("""{"id":"12345678-1234-1234-1234-123456789abc","day":"2024-01-02","at":"x"}""").ok

suite "toJsonSchema":

  test "toJsonSchema should describe primitives and constraints":
    let s = schema:
      name: string.min(2)
      age:  int.max(150)
      tags: string.array
    let js = toJsonSchema(s)
    check js["type"].getStr == "object"
    check js["properties"]["name"]["minLength"].getInt == 2
    check js["properties"]["age"]["maximum"].getInt == 150
    check js["properties"]["tags"]["type"].getStr == "array"
    check "name" in js["required"].to(seq[string])

  test "toJsonSchema should mark optional and default fields as not required":
    let s = schema:
      a: string
      b: string.optional
      c: string.default("x")
    let req = toJsonSchema(s)["required"].to(seq[string])
    check "a" in req
    check "b" notin req and "c" notin req

  test "toJsonSchema should emit oneOf for a discriminated union":
    let sh = discriminated(Shape, kind)
    let js = toJsonSchema(sh)
    check js.hasKey("oneOf")
    check js["oneOf"].len == 2

suite "coercion":

  let s = schema:
    age:    integer().min(0).coerce
    active: boolean().coerce
    label:  str().coerce

  test "coerce should accept a numeric string as an int":
    check s.parse("""{"age":"36","active":true,"label":"x"}""").age == 36

  test "coerce should accept a whole float as an int":
    check s.parse("""{"age":36.0,"active":true,"label":"x"}""").age == 36

  test "coerce should still accept the native type":
    check s.parse("""{"age":36,"active":true,"label":"x"}""").age == 36

  test "coerce should coerce boolean strings":
    check s.parse("""{"age":1,"active":"true","label":"x"}""").active
    check not s.parse("""{"age":1,"active":"false","label":"x"}""").active

  test "coerce should compare true/false case-insensitively":
    check s.parse("""{"age":1,"active":"TRUE","label":"x"}""").active
    check not s.parse("""{"age":1,"active":"False","label":"x"}""").active

  test "coerce should map 0 and positive ints to booleans":
    check not s.parse("""{"age":1,"active":0,"label":"x"}""").active
    check s.parse("""{"age":1,"active":1,"label":"x"}""").active
    check s.parse("""{"age":1,"active":5,"label":"x"}""").active
    check not s.parse("""{"age":1,"active":"0","label":"x"}""").active
    check s.parse("""{"age":1,"active":"1","label":"x"}""").active

  test "coerce should coerce a scalar to a string":
    check s.parse("""{"age":1,"active":true,"label":42}""").label == "42"

  test "coerce should apply refinements to the coerced value":
    check not s.tryParse("""{"age":"-5","active":true,"label":"x"}""").ok

  test "coerce should reject a non-coercible value":
    let r = s.tryParse("""{"age":"abc","active":true,"label":"x"}""")
    check r.issues.anyIt(it.path == "age" and it.message.contains("cannot coerce"))

suite "tuples":

  let s = schema:
    point: tup(number(), number())
    entry: tup(str(), integer(), boolean())
    coord: namedTuple(lat = number(), lng = number())

  test "tup should parse a JSON array into a positional tuple":
    let v = s.parse("""
      {"point":[1.5,2.5],"entry":["a",7,true],"coord":{"lat":1.0,"lng":2.0}}""")
    check v.point[0] == 1.5
    check v.point[1] == 2.5
    check v.entry[0] == "a"
    check v.entry[1] == 7
    check v.entry[2]

  test "tup should validate each element with its index in the path":
    let r = s.tryParse("""
      {"point":[1.5,"x"],"entry":["a",7,true],"coord":{"lat":1.0,"lng":2.0}}""")
    check r.issues.anyIt(it.path == "point[1]" and it.message.contains("expected number"))

  test "tup should reject an array of the wrong length":
    let r = s.tryParse("""
      {"point":[1.5],"entry":["a",7,true],"coord":{"lat":1.0,"lng":2.0}}""")
    check r.issues.anyIt(it.path == "point" and it.message.contains("length 2"))

  test "tup should reject a non-array":
    let r = s.tryParse("""
      {"point":{"a":1},"entry":["a",7,true],"coord":{"lat":1.0,"lng":2.0}}""")
    check r.issues.anyIt(it.path == "point" and it.message.contains("expected array"))

  test "namedTuple should parse a JSON object into a named tuple":
    let v = s.parse("""
      {"point":[1.0,2.0],"entry":["a",7,true],"coord":{"lat":40.7,"lng":-74.0}}""")
    check v.coord.lat == 40.7
    check v.coord.lng == -74.0

  test "namedTuple should validate each field with its name in the path":
    let r = s.tryParse("""
      {"point":[1.0,2.0],"entry":["a",7,true],"coord":{"lat":40.7,"lng":"z"}}""")
    check r.issues.anyIt(it.path == "coord.lng" and it.message.contains("expected number"))

  test "toJsonSchema should describe a tup as a fixed-length array":
    let js = toJsonSchema(s)["properties"]["point"]
    check js["type"].getStr == "array"
    check js["minItems"].getInt == 2
    check js["maxItems"].getInt == 2
    check js["prefixItems"].len == 2

type
  RefUser = ref object
    name*: string
    age*:  int
  NodeKindT = enum nkLeaf = "leaf", nkPair = "pair"
  RefShape = ref object              # a ref *variant* object
    label*: string
    case kind*: NodeKindT
    of nkLeaf: value*: int
    of nkPair: left*, right*: int

suite "ref objects":

  test "schemaOf should parse a ref object into an allocated value":
    let s = schemaOf(RefUser)
    let u = s.parse("""{"name":"Ada","age":36}""")
    check u != nil
    check u.name == "Ada"
    check u.age == 36

  test "Infer should recover a ref type from a ref-object schema":
    let s = schemaOf(RefUser)
    check (Infer(s) is ref)

  test "schema(T) should apply refinements to a ref object":
    let s = schema(RefUser):
      name: string.min(2)
      age:  int.min(0).max(150)
    check s.parse("""{"name":"Bo","age":40}""").name == "Bo"
    let r = s.tryParse("""{"name":"X","age":-1}""")
    check r.issues.anyIt(it.path == "name" and it.message.contains("at least 2"))
    check r.issues.anyIt(it.path == "age" and it.message.contains(">= 0"))

  test "discriminated should build a ref variant object":
    let s = discriminated(RefShape, kind)
    let leaf = s.parse("""{"kind":"leaf","label":"a","value":7}""")
    check leaf != nil
    check leaf.kind == nkLeaf
    check leaf.value == 7
    let pair = s.parse("""{"kind":"pair","label":"b","left":1,"right":2}""")
    check pair.kind == nkPair
    check pair.left == 1
    check pair.right == 2

  test "a ref-typed field should nest inside a value-object schema":
    let s = schema:
      owner: schemaOf(RefUser)
      tag:   string
    let v = s.parse("""{"owner":{"name":"Cy","age":22},"tag":"x"}""")
    check v.owner != nil
    check v.owner.name == "Cy"
    check v.tag == "x"

  test "an optional ref field should become Option[ref T]":
    let s = schema:
      owner: schemaOf(RefUser).optional
    check s.parse("""{"owner":{"name":"Di","age":1}}""").owner.get.name == "Di"
    check not s.parse("""{}""").owner.isSome

  test "validation should report a path through a ref field":
    let s = schema:
      owner: schemaOf(RefUser)
    let r = s.tryParse("""{"owner":{"name":"Ed","age":"nope"}}""")
    check r.issues.anyIt(it.path == "owner.age" and it.message.contains("expected integer"))

  test "a missing required ref field should raise":
    let s = schema:
      owner: schemaOf(RefUser)
    expect ValidationError:
      discard s.parse("""{}""")

type
  Status = enum stActive = "active", stPaused = "paused", stArchived = "archived"
  Prio   = enum pLow, pMed, pHigh          # no explicit string values -> $ is the name
  Ticket = object                          # enum fields auto-derived structurally
    status*: Status
    label*:  string

suite "enums":

  test "enumOf should parse a JSON string into an enum member":
    let s = schema:
      status: enumOf(Status)
    check s.parse("""{"status":"paused"}""").status == stPaused

  test "enumOf should honour a member's name when it has no explicit value":
    let s = schema:
      prio: enumOf(Prio)
    check s.parse("""{"prio":"pHigh"}""").prio == pHigh

  test "enumOf should reject a value that is not a member":
    let s = schema:
      status: enumOf(Status)
    let r = s.tryParse("""{"status":"nope"}""")
    check r.issues.anyIt(it.path == "status" and
      it.message == "must be one of active, paused, archived")

  test "enumOf should reject a non-string":
    let s = schema:
      status: enumOf(Status)
    let r = s.tryParse("""{"status":5}""")
    check r.issues.anyIt(it.path == "status" and it.message.contains("expected string"))

  test "schemaOf should auto-derive an enum-typed field":
    let s = schemaOf(Ticket)
    check s.parse("""{"status":"archived","label":"z"}""").status == stArchived

  test "an optional enum field should become Option[T]":
    let s = schema:
      status: enumOf(Status).optional
    check s.parse("""{"status":"active"}""").status.get == stActive
    check not s.parse("""{}""").status.isSome

  test "an enum array should parse each element":
    let s = schema:
      tags: enumOf(Status).array
    check s.parse("""{"tags":["active","paused"]}""").tags == @[stActive, stPaused]

  test "Infer should recover the enum type":
    let s = schema:
      status: enumOf(Status)
    check (Infer(s).status is Status)

  test "toJsonSchema should emit a string with an enum list":
    let s = schema:
      status: enumOf(Status)
    let js = toJsonSchema(s)["properties"]["status"]
    check js["type"].getStr == "string"
    check js["enum"] == %*["active", "paused", "archived"]
