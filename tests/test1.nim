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
