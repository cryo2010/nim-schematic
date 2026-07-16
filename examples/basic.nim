## Run from the repo root with:  nim r examples/basic.nim

import nim_tailor   # re-exports std/json and std/options

# 1. Define a schema with the combinator DSL. Bare `string`/`int`/... read as
#    schema constructors; chain refinements and modifiers fluently.
let user = schema:
  name:  string.min(2).max(50)
  age:   int.min(0).max(150)
  email: string.email.optional          # -> Option[string]
  role:  string.oneOf(["admin", "user"]).default("user")
  tags:  string.array.default(@[])       # -> seq[string]

# 2. Recover the inferred Nim type. This is the Zod `z.infer` trick:
#    User == tuple[name: string, age: int, email: Option[string],
#                  role: string, tags: seq[string]]
type User = Infer(user)

# 3. Parse JSON straight into that statically-typed value.
let u: User = user.parse("""
  { "name": "Ada", "age": 36, "email": "ada@example.com", "tags": ["math"] }
""")
echo "name : ", u.name                     # statically typed field access
echo "email: ", u.email.get                # Option[string]
echo "role : ", u.role                     # defaulted to "user"
echo "tags : ", u.tags

# 4. Validation errors accumulate (pydantic-style) and carry field paths.
let r = user.tryParse("""{ "name": "A", "age": 999, "role": "root" }""")
if not r.ok:
  echo "\n", r.issues.len, " issue(s):"
  for issue in r.issues:
    echo "  - ", issue          # e.g.  name: must be at least 2 chars

# 5. Schemas compose: nest by value.
let account = schema:
  id:    int
  owner: user
  admin: bool.default(false)

let a = account.parse("""
  { "id": 7, "owner": { "name": "Bo", "age": 5 }, "admin": true }
""")
echo "\naccount ", a.id, " owned by ", a.owner.name, " (admin: ", a.admin, ")"
