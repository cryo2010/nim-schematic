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

  test "oneOf should reject an unknown value":
    let r = account.tryParse("""
      {"id":1,"owner":{"name":"Ada","age":5},"role":"root"}""")
    check r.issues.anyIt(it.path == "role")

suite "arrays":

  test "issue path should include the array element index":
    let Nums = schema:
      xs: int.array
    let r = Nums.tryParse("""{"xs":[1,2,"three"]}""")
    check r.issues.anyIt(it.path == "xs[2]")

  test "tryParse should report an error for invalid JSON":
    let r = user.tryParse("""{not json""")
    check not r.ok
    check r.issues[0].message.contains("invalid JSON")

  test "array should enforce its length constraints":
    let Tags = schema:
      xs: string.array.min(1).max(2)
    check Tags.tryParse("""{"xs":["a"]}""").ok
    check not Tags.tryParse("""{"xs":[]}""").ok
    check not Tags.tryParse("""{"xs":["a","b","c"]}""").ok

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
