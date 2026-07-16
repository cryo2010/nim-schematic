import unittest
import std/[json, options, strutils, sequtils]
import tailor

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

  test "inferred type has the right static shape":
    var u: User
    u.name = "Ada"
    u.age = 36
    u.email = some("ada@example.com")
    u.tags = @["math"]
    check u.name == "Ada"
    check u.email.isSome

  test "parses a valid object":
    let u = user.parse("""{"name":"Ada","age":36,"email":"ada@x.io","tags":["a","b"]}""")
    check u.name == "Ada"
    check u.age == 36
    check u.email == some("ada@x.io")
    check u.tags == @["a", "b"]

  test "optional field absent -> none":
    let u = user.parse("""{"name":"Bo","age":1}""")
    check u.email.isNone

  test "default field applied when absent":
    let u = user.parse("""{"name":"Bo","age":1}""")
    check u.tags.len == 0

suite "validation errors":

  test "collects multiple issues at once":
    let r = user.tryParse("""{"name":"A","age":999,"email":"nope"}""")
    check not r.ok
    check r.issues.len == 3            # name too short, age too big, bad email

  test "error carries field paths":
    let r = user.tryParse("""{"name":"A","age":5}""")
    check r.issues[0].path == "name"

  test "type mismatch reported":
    let r = user.tryParse("""{"name":123,"age":5}""")
    check not r.ok
    check r.issues[0].message.contains("expected string")

  test "required field missing":
    let r = user.tryParse("""{"age":5}""")
    check r.issues.anyIt(it.path == "name" and it.message == "required")

  test "parse raises ValidationError with all issues":
    expect ValidationError:
      discard user.parse("""{"name":"A","age":999}""")

suite "composition":

  test "nested object with path prefix":
    let r = account.tryParse("""
      {"id":1,"owner":{"name":"A","age":5},
       "address":{"city":"","zip":"12345"},"role":"admin"}""")
    check not r.ok
    check r.issues.anyIt(it.path == "owner.name")
    check r.issues.anyIt(it.path == "address.city")

  test "valid nested account":
    let a = account.parse("""
      {"id":1,"owner":{"name":"Ada","age":5},
       "address":{"city":"NYC","zip":"10001"},"role":"user"}""")
    check a.owner.name == "Ada"
    check a.address.isSome
    check a.address.get.city == "NYC"

  test "optional nested object absent":
    let a = account.parse("""
      {"id":1,"owner":{"name":"Ada","age":5},"role":"guest"}""")
    check a.address.isNone

  test "enum rejects unknown value":
    let r = account.tryParse("""
      {"id":1,"owner":{"name":"Ada","age":5},"role":"root"}""")
    check r.issues.anyIt(it.path == "role")

suite "arrays":

  test "array element path in errors":
    let Nums = schema:
      xs: int.array
    let r = Nums.tryParse("""{"xs":[1,2,"three"]}""")
    check r.issues.anyIt(it.path == "xs[2]")

  test "invalid JSON reported cleanly":
    let r = user.tryParse("""{not json""")
    check not r.ok
    check r.issues[0].message.contains("invalid JSON")

  test "array length constraints":
    let Tags = schema:
      xs: string.array.min(1).max(2)
    check Tags.tryParse("""{"xs":["a"]}""").ok
    check not Tags.tryParse("""{"xs":[]}""").ok
    check not Tags.tryParse("""{"xs":["a","b","c"]}""").ok

suite "custom refine":

  test "predicate passes and fails with its message":
    let Even = schema:
      n: int.refine("must be even", proc(v: int): bool = v mod 2 == 0)
    check Even.tryParse("""{"n":4}""").ok
    let r = Even.tryParse("""{"n":3}""")
    check r.issues.anyIt(it.path == "n" and it.message == "must be even")

  test "custom check skipped when inner already failed":
    let Even = schema:
      n: int.refine("must be even", proc(v: int): bool = v mod 2 == 0)
    let r = Even.tryParse("""{"n":"oops"}""")
    check r.issues.len == 1                # only "expected integer", not "must be even"
    check r.issues[0].message.contains("expected integer")
