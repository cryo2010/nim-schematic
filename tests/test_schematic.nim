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

type
  Tag = enum tgA = "a", tgB = "b"
  Payload = object                # a variant for strict-union tests
    label*: string
    case tag*: Tag
    of tgA: x*: int
    of tgB: y*: int

suite "strict":

  let base = schema:
    name: string
    age:  int

  test "a non-strict object should ignore unknown keys":
    check base.parse("""{"name":"A","age":1,"extra":true}""").name == "A"

  test "strict should reject each unknown key at its own path":
    let s = base.strict
    let r = s.tryParse("""{"name":"A","age":1,"x":9,"y":8}""")
    check r.issues.anyIt(it.path == "x" and it.message == "unexpected key")
    check r.issues.anyIt(it.path == "y" and it.message == "unexpected key")

  test "strict should still accept a fully-declared object":
    let s = base.strict
    check s.parse("""{"name":"A","age":1}""").age == 1

  test "strict should apply only to its own level":
    let inner = schema:
      city: string
    let outer = schema:
      who:  string
      home: inner
    let s = outer.strict
    check s.tryParse("""{"who":"x","home":{"city":"NYC","zip":"1"}}""").ok
    let r = s.tryParse("""{"who":"x","home":{"city":"NYC"},"bogus":1}""")
    check r.issues.anyIt(it.path == "bogus" and it.message == "unexpected key")

  test "strict should reject keys outside the selected union branch":
    let s = discriminated(Payload, tag).strict
    check s.parse("""{"tag":"a","label":"L","x":1}""").x == 1
    let r = s.tryParse("""{"tag":"a","label":"L","x":1,"z":9}""")
    check r.issues.anyIt(it.path == "z" and it.message == "unexpected key")

  test "toJsonSchema should mark a strict object as additionalProperties false":
    check toJsonSchema(base)["additionalProperties"].getBool == true
    check toJsonSchema(base.strict)["additionalProperties"].getBool == false

# --------------------------------------------------------------------------
# Regression tests for the validation-hardening fixes, plus previously
# untested API surface.
# --------------------------------------------------------------------------

suite "crash safety":

  test "pattern should reject invalid UTF-8 instead of crashing":
    let s = schema:
      v: string.pattern(r"\w+")
    let r = s.tryParse("{\"v\": \"ab\xffcd\"}")     # raw 0xFF byte in the string
    check not r.ok
    check r.issues.anyIt(it.message.contains("must match pattern"))
    check s.tryParse("""{"v":"abc"}""").ok

  test "a sized signed int field should reject out-of-range values":
    type Small = object
      a*: int8
    let s = schemaOf(Small)
    let r = s.tryParse("""{"a":300}""")
    check not r.ok
    check r.issues.anyIt(it.path == "a" and it.message.contains("<= 127"))
    check s.parse("""{"a":-128}""").a == -128

  test "a sized unsigned int field should reject instead of wrapping":
    type Small = object
      b*: uint8
    let s = schemaOf(Small)
    check not s.tryParse("""{"b":300}""").ok
    check not s.tryParse("""{"b":-1}""").ok
    check s.parse("""{"b":255}""").b == 255'u8

  test "a uint64 field should reject negative values":
    type Big = object
      c*: uint64
    let s = schemaOf(Big)
    check not s.tryParse("""{"c":-1}""").ok
    check s.parse("""{"c":9223372036854775807}""").c == 9223372036854775807'u64

  test "validation should stop at the maximum nesting depth":
    type Deep = object
      children*: seq[Deep]
    var ds: Schema[Deep]
    ds = schema(Deep):
      children: lazy(ds).array.default(@[])
    var j = %*{"children": []}
    for i in 0 ..< schematicMaxDepth * 4: j = %*{"children": [j]}
    let r = ds.tryParse(j)
    check not r.ok
    check r.issues.anyIt(it.message == "maximum nesting depth exceeded")

  test "validation should accept nesting below the depth limit":
    type Deep2 = object
      children*: seq[Deep2]
    var ds: Schema[Deep2]
    ds = schema(Deep2):
      children: lazy(ds).array.default(@[])
    var j = %*{"children": []}
    for i in 0 ..< 100: j = %*{"children": [j]}
    check ds.tryParse(j).ok

suite "checks against normalized values":

  test "a check after default should validate and keep the default":
    let s = schema:
      n: int.default(7).min(5)
    check s.parse("{}").n == 7

  test "a check before default should behave the same":
    let s = schema:
      n: int.min(5).default(7)
    check s.parse("{}").n == 7

  test "a check after coerce should see the coerced value":
    let s = schema:
      n: int.coerce.min(10)
    check s.parse("""{"n":"50"}""").n == 50
    check not s.tryParse("""{"n":"5"}""").ok

  test "refine should see the coerced value":
    let s = schema:
      n: integer().coerce.refine("must be 36", proc(v: int): bool = v == 36)
    check s.parse("""{"n":"36"}""").n == 36

  test "an object-level refine should see filled-in defaults":
    let base = schema:
      x: int.default(5)
    let s = base.refine("x must be 5", proc(v: Infer(base)): bool = v.x == 5)
    check s.tryParse("{}").ok

  test "an array default after a length check should apply":
    let s = schema:
      xs: string.array.default(@["a"]).min(1)
    check s.parse("{}").xs == @["a"]

  test "an invalid default should be rejected when the schema is built":
    expect ValueError:
      let bad = schema:
        n: int.min(10).default(5)
      discard bad

  test "a timestamp default should serialize to unix seconds":
    let s = schema:
      at: timestamp().default(fromUnix(1700000000))
    check s.parse("{}").at == fromUnix(1700000000)

suite "toJson and re-validation round trips":

  let aliased = schema:
    userName: string.min(1).alias("user_name")

  test "tryValidate should accept a freshly parsed aliased value":
    let u = aliased.parse("""{"user_name":"ada"}""")
    check aliased.tryValidate(u).ok

  test "toJson should write aliased fields under their JSON key":
    let u = aliased.parse("""{"user_name":"ada"}""")
    check aliased.toJson(u) == %*{"user_name": "ada"}

  test "tryValidate should still catch a mutated aliased value":
    var u = aliased.parse("""{"user_name":"ada"}""")
    u.userName = ""
    check not aliased.tryValidate(u).ok

  test "tryValidate should accept a timestamp value":
    let s = schema:
      at: timestamp()
    let v = s.parse("""{"at":1700000000}""")
    check s.tryValidate(v).ok
    check s.toJson(v)["at"].getInt == 1700000000

  test "tryValidate should compile and round-trip a tuple schema":
    let s = schema:
      point: tup(number(), integer())
    let v = s.parse("""{"point":[1.5,2]}""")
    check s.tryValidate(v).ok
    check s.toJson(v)["point"] == %*[1.5, 2]

  test "toJson should round-trip a discriminated union":
    let sh = discriminated(Shape, kind)
    let v = sh.parse("""{"kind":"circle","label":"c","radius":2.5}""")
    check sh.tryValidate(v).ok
    check sh.toJson(v) == %*{"kind":"circle","label":"c","radius":2.5}

  test "toJson should emit null for an absent optional field":
    let s = schema:
      email: string.email.optional
    check s.toJson(s.parse("{}"))["email"].kind == JNull

suite "compile-time rejections":

  type
    VK = enum vkA = "a", vkB = "b"
    Var = object
      label*: string
      case kind*: VK
      of vkA: x*: int
      of vkB: y*: string

  test "schemaOf should reject a variant object at compile time":
    check not compiles(schemaOf(Var))

  test "schema(T) should reject a variant object at compile time":
    template viaSchemaT(): untyped =
      schema(Var):
        label: string.min(1)
    check not compiles(viaSchemaT())

  test "strict should reject a non-object schema at compile time":
    check not compiles(str().strict)
    check not compiles(integer().strict)
    check not compiles(str().array.strict)

suite "multi-label variant branches":

  type
    MK = enum mkA = "a", mkB = "b", mkC = "c"
    Multi = object
      label*: string
      case kind*: MK
      of mkA, mkB: shared*: int
      of mkC: solo*: string

  let s = discriminated(Multi, kind)

  test "each label of a multi-label branch should parse":
    check s.parse("""{"kind":"a","label":"x","shared":1}""").shared == 1
    let b = s.parse("""{"kind":"b","label":"x","shared":2}""")
    check b.kind == mkB and b.shared == 2
    check s.parse("""{"kind":"c","label":"x","solo":"s"}""").solo == "s"

  test "a multi-label branch should require its fields for every label":
    check not s.tryParse("""{"kind":"b","label":"x"}""").ok

suite "string edge cases":

  test "string min/max should count unicode characters, not bytes":
    let s = schema:
      name: string.min(2).max(3)
    check s.tryParse("""{"name":"héé"}""").ok        # 3 chars, 5 bytes
    check not s.tryParse("""{"name":"hééé"}""").ok   # 4 chars
    check not s.tryParse("""{"name":"é"}""").ok      # 1 char, 2 bytes

  test "email should reject an empty domain or TLD":
    let s = schema:
      e: string.email
    for bad in ["a@.", "a@b.", "a@.c", "@b.c", "a@bc"]:
      check not s.tryParse("{\"e\":\"" & bad & "\"}").ok
    check s.tryParse("""{"e":"a@b.c"}""").ok

  test "coerce should reject non-finite number strings":
    let s = schema:
      x: number().coerce
    for bad in ["nan", "inf", "-inf", "1e999"]:
      check not s.tryParse("{\"x\":\"" & bad & "\"}").ok
    check s.parse("""{"x":"1e300"}""").x == 1e300

suite "previously untested surface":

  var post: Schema[Comment]            # recursive, for the $refs tests below
  post = schema(Comment):
    text:    string.min(1)
    replies: lazy(post).array.default(@[])

  test "datetime should accept ISO 8601 and reject others":
    let s = schema:
      at: string.datetime
    check s.tryParse("""{"at":"2024-01-02T03:04:05Z"}""").ok
    check s.tryParse("""{"at":"2024-01-02T03:04:05.123+02:00"}""").ok
    check not s.tryParse("""{"at":"2024-01-02"}""").ok
    check not s.tryParse("""{"at":"x2024-01-02T03:04:05Z"}""").ok

  test "dollar should render an issue as path and message":
    let r = user.tryParse("""{"age":5}""")
    check ($r.issues[0]).contains("name: ")

  test "parse should accept a JsonNode directly":
    let u = user.parse(%*{"name": "Ada", "age": 36})
    check u.name == "Ada"

  test "tryParse should accept a JsonNode directly":
    check not user.tryParse(%*{"name": "A", "age": 999}).ok

  test "toJsonSchema should describe a record and a timestamp":
    let s = schema:
      lims: record(integer().min(0))
      at:   timestamp()
    let js = toJsonSchema(s)
    check js["properties"]["lims"]["additionalProperties"]["type"].getStr == "integer"
    check js["properties"]["at"]["type"].getStr == "integer"

  test "toJsonSchema should use the alias key for properties":
    let s = schema:
      userName: string.alias("user_name")
    check toJsonSchema(s)["properties"].hasKey("user_name")

  test "toJsonSchema should keep the root self-reference as #":
    let js = toJsonSchema(post)
    check js["properties"]["replies"]["items"]["$ref"].getStr == "#"
    check not js.hasKey("$defs")

  test "toJsonSchema should hoist a nested recursive schema into $defs":
    let thread = schema:
      title: string
      root:  lazy(post)
    let js = toJsonSchema(thread)
    let refStr = js["properties"]["root"]["$ref"].getStr
    check refStr.startsWith("#/$defs/")
    let defName = refStr.split("/")[^1]
    check js["$defs"].hasKey(defName)
    check js["$defs"][defName]["properties"]["replies"]["items"]["$ref"].getStr == refStr

suite "sized numeric constructors":

  test "integer(T) should enforce the type's range":
    let s = schema:
      port: integer(uint16)
    check not s.tryParse("""{"port":70000}""").ok
    check not s.tryParse("""{"port":-1}""").ok
    check s.parse("""{"port":8080}""").port == 8080'u16

  test "the DSL should accept bare sized type names":
    let s = schema:
      port:  uint16.min(1024)
      score: int8
      ratio: float32
    let v = s.parse("""{"port":8080,"score":-5,"ratio":1.5}""")
    check v.port is uint16
    check v.score is int8
    check v.ratio is float32
    check v.port == 8080'u16 and v.score == -5'i8 and v.ratio == 1.5'f32
    check not s.tryParse("""{"port":80,"score":0,"ratio":1.0}""").ok
    check not s.tryParse("""{"port":1024,"score":200,"ratio":1.0}""").ok

  test "a bound outside the type's range should not compile":
    check not compiles(integer(uint8).min(-1))

  test "a uint64 bound beyond the JSON integer range should raise":
    expect ValueError:
      discard integer(uint64).min(uint64.high)

  test "coerce should range-check the coerced value":
    let s = schema:
      port: integer(uint16).coerce
    check s.parse("""{"port":"8080"}""").port == 8080'u16
    check not s.tryParse("""{"port":"70000"}""").ok

  test "toJsonSchema should carry the type's bounds":
    let s = schema:
      b: integer(uint8)
    let js = toJsonSchema(s)
    check js["properties"]["b"]["minimum"].getInt == 0
    check js["properties"]["b"]["maximum"].getInt == 255

  test "sized fields should round-trip through toJson and tryValidate":
    let s = schema:
      port:  uint16.min(1024)
      ratio: float32
    let v = s.parse("""{"port":8080,"ratio":1.5}""")
    check s.tryValidate(v).ok
    check s.toJson(v)["port"].getInt == 8080

  test "the plain integer() and number() forms should be unchanged":
    check integer().min(0).max(10) is Schema[int]
    check number().min(0.5) is Schema[float]

  test "integer(T) should agree with schemaOf on the same field type":
    type Conf = object
      port*: uint16
    let derived = schemaOf(Conf)
    let explicit = schema(Conf):
      port: integer(uint16)
    check not derived.tryParse("""{"port":70000}""").ok
    check not explicit.tryParse("""{"port":70000}""").ok
    check derived.parse("""{"port":1}""").port == explicit.parse("""{"port":1}""").port

  test "every sized type name should rewrite and infer in the DSL":
    let s = schema:
      a: int8
      b: int16
      c: int32
      d: int64
      e: uint
      f: uint8
      g: uint16
      h: uint32
      i: uint64
      x: float32
      y: float64
    let v = s.parse("""{"a":-1,"b":-2,"c":-3,"d":9223372036854775807,
      "e":5,"f":6,"g":7,"h":8,"i":9,"x":1.5,"y":2.5}""")
    check v.a is int8 and v.a == -1'i8
    check v.b is int16 and v.b == -2'i16
    check v.c is int32 and v.c == -3'i32
    check v.d is int64 and v.d == high(int64)
    check v.e is uint and v.e == 5'u
    check v.f is uint8 and v.f == 6'u8
    check v.g is uint16 and v.g == 7'u16
    check v.h is uint32 and v.h == 8'u32
    check v.i is uint64 and v.i == 9'u64
    check v.x is float32 and v.x == 1.5'f32
    check v.y is float64 and v.y == 2.5

  test "each sized integer type should enforce its own range":
    template rejects(T: untyped, bad: string): untyped =
      let s = schema:
        n: integer(T)
      check not s.tryParse("{\"n\":" & bad & "}").ok
    rejects(int8,   "128")
    rejects(int16,  "32768")
    rejects(int32,  "2147483648")
    rejects(uint8,  "-1")
    rejects(uint16, "65536")
    rejects(uint32, "4294967296")
    rejects(uint,   "-1")
    rejects(uint64, "-1")
    check integer(int64).parse(newJInt(high(int64))) == high(int64)

suite "nullable":

  let s = schema:
    name: string.min(2).nullable    # key required, value may be null
    age:  int.optional

  test "nullable should accept an explicit null as none":
    check s.parse("""{"name":null}""").name.isNone

  test "nullable should accept a value as some and still refine it":
    check s.parse("""{"name":"Ada"}""").name == some("Ada")
    check not s.tryParse("""{"name":"A"}""").ok

  test "nullable should require the key to be present":
    let r = s.tryParse("{}")
    check not r.ok
    check r.issues.anyIt(it.path == "name" and it.message == "required")

  test "optional should still treat missing and null the same":
    check s.parse("""{"name":null}""").age.isNone
    check s.parse("""{"name":null,"age":null}""").age.isNone
    check s.parse("""{"name":null,"age":3}""").age == some(3)

  test "a plain required field should still reject explicit null":
    let p = schema:
      x: int
    check not p.tryParse("""{"x":null}""").ok
    check not p.tryParse("{}").ok

  test "toJsonSchema should emit a null type member and keep the key required":
    let js = toJsonSchema(s)
    check js["properties"]["name"]["type"] == %*["string", "null"]
    check "name" in js["required"].to(seq[string])

  test "toJsonSchema should fall back to anyOf for typeless inner schemas":
    let g = schema:
      extra: json().nullable
    check toJsonSchema(g)["properties"]["extra"].hasKey("anyOf")

  test "nullable values should round-trip through toJson and tryValidate":
    let v = s.parse("""{"name":null,"age":1}""")
    check s.tryValidate(v).ok
    check s.toJson(v)["name"].kind == JNull
    check s.tryValidate(s.parse("""{"name":"Ada"}""")).ok

  test "nullable should distinguish inside nested objects":
    let outer = schema:
      inner: s
    let r = outer.tryParse("""{"inner":{}}""")
    check r.issues.anyIt(it.path == "inner.name" and it.message == "required")
    check outer.parse("""{"inner":{"name":null}}""").inner.name.isNone

suite "custom messages":

  test "every built-in refinement should accept a message override":
    let s = schema:
      age:   int.min(0, message = "age cannot be negative")
      name:  string.min(2, "name too short")
      email: string.email("bad email")
      role:  string.oneOf(["a", "b"], message = "unknown role")
      tags:  string.array.max(2, "too many tags")
      zip:   string.pattern(r"\d{5}", "bad zip")
    let r = s.tryParse("""{"age":-1,"name":"x","email":"nope","role":"z",
      "tags":["a","b","c"],"zip":"abc"}""")
    check not r.ok
    for expected in ["age cannot be negative", "name too short", "bad email",
                     "unknown role", "too many tags", "bad zip"]:
      check r.issues.anyIt(it.message == expected)

  test "format refinements should accept a message override":
    let s = schema:
      id:  string.uuid("bad id")
      day: string.date(message = "bad day")
      at:  string.datetime("bad at")
      nm:  string.nonempty("empty nm")
    let r = s.tryParse("""{"id":"x","day":"x","at":"x","nm":""}""")
    for expected in ["bad id", "bad day", "bad at", "empty nm"]:
      check r.issues.anyIt(it.message == expected)

  test "the default message should be unchanged when no override is given":
    let s = schema:
      n: int.min(0)
      f: float.max(2.0)
    let r = s.tryParse("""{"n":-1,"f":3.0}""")
    check r.issues.anyIt(it.message == "must be >= 0")
    check r.issues.anyIt(it.message == "must be <= 2.0")

  test "a message override should work on sized numeric schemas":
    let s = schema:
      port: uint16.min(1024, message = "reserved port")
    check s.tryParse("""{"port":80}""").issues[0].message == "reserved port"

type AccountId = distinct string
proc `==`(a, b: AccountId): bool {.borrow.}

suite "transform":

  let user = schema:
    name: string.min(2).transform(proc(s: string): string = s.strip)
    id:   string.uuid.transform(proc(s: string): AccountId = AccountId(s))
    born: string.date.transform(proc(s: string): Time =
            parseTime(s, "yyyy-MM-dd", utc()))
    tags: string.transform(proc(s: string): string = s.toLowerAscii).array

  const okJson = """{"name":"  Ada  ","id":"12345678-1234-1234-1234-123456789abc",
    "born":"1815-12-10","tags":["Math","LOGIC"]}"""

  test "transform should map validated values and change the field type":
    let u = user.parse(okJson)
    check u.name == "Ada"
    check u.id is AccountId
    check u.id == AccountId("12345678-1234-1234-1234-123456789abc")
    check u.born.utc.year == 1815
    check u.tags == @["math", "logic"]

  test "refinements before a transform should constrain the wire value":
    check not user.tryParse("""{"name":"A","id":"12345678-1234-1234-1234-123456789abc",
      "born":"1815-12-10","tags":[]}""").ok

  test "refine after a transform should see the transformed value":
    let past = schema:
      born: string.date
              .transform(proc(s: string): Time = parseTime(s, "yyyy-MM-dd", utc()))
              .refine("must be before 2000", proc(t: Time): bool = t.utc.year < 2000)
    check past.tryParse("""{"born":"1999-01-01"}""").ok
    check not past.tryParse("""{"born":"2001-01-01"}""").ok

  test "a raising transform should report an issue, not crash":
    let boom = schema:
      n: int.transform(proc(v: int): int =
           (if v == 13: raise newException(ValueError, "unlucky")); v)
    let r = boom.tryParse("""{"n":13}""")
    check not r.ok
    check r.issues.anyIt(it.path == "n" and it.message == "transform failed: unlucky")
    check boom.parse("""{"n":7}""").n == 7

  test "toJson should raise for a transform without back":
    let u = user.parse(okJson)
    expect ValueError:
      discard user.toJson(u)

  test "a transform with back should round-trip through toJson and tryValidate":
    let cel = schema:
      tempF: number().transform(proc(f: float): float = f * 9 / 5 + 32,
                                back = proc(f: float): float = (f - 32) * 5 / 9)
    let c = cel.parse("""{"tempF":100.0}""")
    check c.tempF == 212.0
    check cel.tryValidate(c).ok
    check cel.toJson(c)["tempF"].getFloat == 100.0

  test "transform should compose with optional":
    let s = schema:
      nick: string.transform(proc(v: string): string = v.strip).optional
    check s.parse("{}").nick.isNone
    check s.parse("""{"nick":" x "}""").nick == some("x")

  test "toJsonSchema should describe the wire input of a transform":
    let js = toJsonSchema(user)
    check js["properties"]["born"]["type"].getStr == "string"

  test "schemaOf should derive distinct fields from their base type":
    type Acct = object
      id*: AccountId
    let s = schemaOf(Acct)
    check s.parse("""{"id":"abc"}""").id == AccountId("abc")
    check not s.tryParse("""{"id":5}""").ok

  test "transform inside nullable should skip null but require the key":
    let s = schema:
      nick: string.transform(proc(v: string): string = v.strip).nullable
    check s.parse("""{"nick":null}""").nick.isNone      # transform not invoked
    check s.parse("""{"nick":" x "}""").nick == some("x")
    let r = s.tryParse("{}")
    check not r.ok
    check r.issues.anyIt(it.path == "nick" and it.message == "required")

  test "transform outside optional should run on missing input with none":
    let s = schema:
      nick: string.optional.transform(proc(v: Option[string]): string =
              (if v.isSome: v.get.strip else: "(anon)"))
    check s.parse("{}").nick == "(anon)"                # ran on none
    check s.parse("""{"nick":null}""").nick == "(anon)"
    check s.parse("""{"nick":" x "}""").nick == "x"
    check s.parse("{}").nick is string                  # no longer Option

  test "transform outside nullable should run on null but require the key":
    let s = schema:
      nick: string.nullable.transform(proc(v: Option[string]): string =
              (if v.isSome: v.get.strip else: "(cleared)"))
    check s.parse("""{"nick":null}""").nick == "(cleared)"
    check s.parse("""{"nick":" x "}""").nick == "x"
    check not s.tryParse("{}").ok                       # key still required

suite "literal":

  let event = schema:
    version: literal("v1")
    code:    literal(404)
    active:  literal(true)

  test "literal should accept exactly its value":
    let e = event.parse("""{"version":"v1","code":404,"active":true}""")
    check e.version == "v1" and e.code == 404 and e.active

  test "literal should reject the wrong value of the right type":
    let r = event.tryParse("""{"version":"v2","code":404,"active":true}""")
    check r.issues.anyIt(it.path == "version" and it.message == "must be \"v1\"")

  test "literal should report a type error before the value check":
    let r = event.tryParse("""{"version":5,"code":404,"active":true}""")
    check r.issues.anyIt(it.path == "version" and it.message.contains("expected string"))

  test "literal should combine with default to pin an omittable field":
    let pinned = schema:
      version: literal("v1", message = "unsupported version").default("v1")
    check pinned.parse("{}").version == "v1"
    check pinned.tryParse("""{"version":"v2"}""").issues[0].message == "unsupported version"

  test "toJsonSchema should emit const for a literal":
    check toJsonSchema(event)["properties"]["version"]["const"].getStr == "v1"

suite "oneOfSchema":

  let flexTime = oneOfSchema(
    timestamp(),
    str().datetime.transform(proc(s: string): Time =
      parseTime(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())))
  let evt = schema:
    created: flexTime

  test "the first cleanly matching alternative should win":
    check evt.parse("""{"created":1700000000}""").created == fromUnix(1700000000)
    check evt.parse("""{"created":"2023-11-14T22:13:20Z"}""").created == fromUnix(1700000000)

  test "no match should report the closest alternative's issues":
    let r = evt.tryParse("""{"created":true}""")
    check not r.ok
    check r.issues.anyIt(it.path == "created" and it.message == "no alternative matched")
    check r.issues.len > 1                    # closest branch's issues follow

  test "a missing value should report required":
    check evt.tryParse("{}").issues.anyIt(
      it.path == "created" and it.message == "required")

  test "divergent shapes should map onto a common type via transform":
    type Contact = object
      email*: string
      name*:  string
    let full = schema(Contact):
      email: string.email
    let short = str().email.transform(proc(s: string): Contact = Contact(email: s))
    let contact = oneOfSchema(full, short)
    check contact.parse("\"a@b.co\"").email == "a@b.co"
    check contact.parse("""{"email":"a@b.co","name":"Ada"}""").name == "Ada"
    check not contact.tryParse("\"not-an-email\"").ok

  test "overlapping alternatives should resolve in declaration order":
    let s = schema:
      n: oneOfSchema(integer().min(0), integer())
    check s.parse("""{"n":-5}""").n == -5     # falls through to the second

  test "round trips should use the first invertible alternative":
    let v = evt.parse("""{"created":"2023-11-14T22:13:20Z"}""")
    check evt.tryValidate(v).ok
    check evt.toJson(v)["created"].getInt == 1700000000

  test "toJsonSchema should emit anyOf":
    let js = toJsonSchema(evt)["properties"]["created"]
    check js.hasKey("anyOf")
    check js["anyOf"].len == 2

  test "an empty alternative list should be rejected at build time":
    expect ValueError:
      discard oneOfSchema[int]()

  test "oneOfSchema should compose with optional":
    let s = schema:
      at: flexTime.optional
    check s.parse("{}").at.isNone
    check s.parse("""{"at":1700000000}""").at == some(fromUnix(1700000000))

suite "coerce guard":

  test "coerce should still work on every scalar schema form":
    let s = schema:
      age:  int.min(0).coerce
      port: uint16.coerce
      flag: bool.coerce
      name: str().coerce
    let v = s.parse("""{"age":"36","port":"80","flag":"true","name":7}""")
    check v.age == 36
    check v.port == 80'u16
    check v.flag
    check v.name == "7"

  test "coerce on a non-scalar schema should not compile":
    check not compiles(str().array.coerce)
    check not compiles(json().coerce)
    check not compiles(str().optional.coerce)
    check not compiles(timestamp().coerce)

  test "coerce after transform should be rejected when the schema is built":
    expect ValueError:
      discard str().transform(proc(v: string): string = v.strip).coerce

  test "coerce before transform should keep working":
    let s = schema:
      n: integer().coerce.transform(proc(v: int): int = v * 2)
    check s.parse("""{"n":"21"}""").n == 42
