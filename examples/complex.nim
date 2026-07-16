## A deliberately maximal example: nested objects, arrays of objects, optionals,
## defaults, enums, several refinements (including custom predicates), a plain
## type validated with schemaOf, a recursive comment thread, a discriminated
## union, type inference, and error accumulation with deep paths.
##
## Run from the repo root with:  nim r examples/complex.nim

import schematic
import std/strutils   # for the custom refine predicates

# A plain type we validate structurally with `schemaOf` (no custom rules).
type GeoPoint = object
  lat*: float
  lng*: float

# A recursive (tree) type: a comment with nested replies.
type Comment = object
  author*:  string
  body*:    string
  replies*: seq[Comment]

var comment: Schema[Comment]
comment = schema(Comment):
  author:  string.min(1)
  body:    string.min(1).max(2000)
  replies: lazy(comment).array.default(@[])   # leaves may omit `replies`

# Reusable nested schemas, composed by value into the top-level schema.
let owner = schema:
  name:  string.min(2).max(50)
  email: string.email
  age:   int.min(0).max(150).optional          # -> Option[int]

let member = schema:
  name: string.min(1)
  role: string.oneOf(["admin", "maintainer", "viewer"])

# A discriminated union: a deploy target, tagged by `kind`.
type
  DeployKind = enum dkStatic = "static", dkContainer = "container"
  Deploy = object
    env*: string                                  # shared by every branch
    case kind*: DeployKind
    of dkStatic: dir*: string
    of dkContainer:
      image*: string
      port*:  int
let deploy = discriminated(Deploy, kind)

# The top-level schema, inference-first.
let project = schema:
  name:       string.min(1).max(100)
  slug:       string.refine("must be kebab-case", proc(v: string): bool =
                v.len > 0 and v.allCharsInSet({'a'..'z', '0'..'9', '-'}))
  version:    string.pattern(r"\d+\.\d+\.\d+")   # regex refinement
  visibility: string.oneOf(["public", "private", "internal"]).default("private")
  stars:      int.min(0).default(0)
  location:   schemaOf(GeoPoint).optional       # optional plain-type field
  owner:      owner                             # nested inferred object
  members:    member.array.default(@[])         # array of nested objects
  tags:       string.array.default(@[])
  thread:     comment.optional                  # optional recursive tree
  metadata:   JsonNode.optional                 # arbitrary passthrough JSON
  deploy:     deploy.optional                   # nested discriminated union

# The inferred Nim type, straight from the schema.
type Project = Infer(project)

# ---- happy path: parse into a fully typed value ----
let p: Project = project.parse("""
{
  "name": "Schematic",
  "slug": "schematic",
  "version": "0.1.0",
  "visibility": "public",
  "stars": 42,
  "location": { "lat": 40.7128, "lng": -74.0060 },
  "owner": { "name": "Ada", "email": "ada@example.com", "age": 36 },
  "members": [
    { "name": "Bo", "role": "maintainer" },
    { "name": "Cy", "role": "viewer" }
  ],
  "tags": ["nim", "validation"],
  "thread": {
    "author": "Ada", "body": "First!",
    "replies": [ { "author": "Bo", "body": "Nice work" } ]
  },
  "metadata": { "team": "core", "priority": 3 },
  "deploy": { "kind": "container", "env": "prod", "image": "app:1.2", "port": 8080 }
}
""")

echo p.name, " v", p.version, " (", p.visibility, ")"
echo "  owner: ", p.owner.name, " <", p.owner.email, ">, age ", p.owner.age.get
echo "  where: ", p.location.get.lat, ", ", p.location.get.lng
echo "  members: ", p.members.len
echo "  first reply by: ", p.thread.get.replies[0].author
echo "  metadata.team: ", p.metadata.get["team"].getStr
echo "  deploy: ", p.deploy.get.kind, " image=", p.deploy.get.image   # nested union

# Defaults kicked in for anything omitted:
let minimal = project.parse("""
  { "name": "x", "slug": "x", "version": "1.2.3",
    "owner": { "name": "Ed", "email": "ed@x.io" } }
""")
echo "\nminimal: visibility=", minimal.visibility, " stars=", minimal.stars,
     " tags=", minimal.tags, " members=", minimal.members.len,
     " location?=", minimal.location.isSome

# ---- unhappy path: every problem at once, each with a path ----
let bad = project.tryParse("""
{
  "name": "",
  "slug": "Not A Slug",
  "version": "1.0",
  "visibility": "secret",
  "owner": { "name": "A", "email": "nope" },
  "members": [ { "name": "Bo", "role": "root" } ],
  "thread": {
    "author": "",
    "body": "hi",
    "replies": [ { "author": "x", "body": "" } ]
  },
  "deploy": { "kind": "lambda", "env": "prod" }
}
""")
echo "\n", bad.issues.len, " validation issue(s):"
for issue in bad.issues:
  echo "  - ", issue
