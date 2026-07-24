## A deliberately maximal example: nested objects, arrays of objects, optionals,
## nullables, defaults, enums, string formats (slug/semver/url), literals, an
## untagged union with a transform, custom messages and predicates, a sized
## integer field, a plain type validated with schemaOf, a recursive comment
## thread, discriminated unions nested as fields, aliases, type inference,
## error accumulation with deep paths, and JSON Schema output with metadata.
##
## Run from the repo root with:  nim r examples/complex.nim

import schematic

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
  age:   int.min(0, message = "age cannot be negative").max(150).optional

# A discriminated union used *inside* a nested object (see `member` below):
# a member's contact method, tagged by `kind`.
type
  ContactKind = enum ctEmail = "email", ctPhone = "phone"
  Contact = object
    case kind*: ContactKind
    of ctEmail: address*: string
    of ctPhone: number*:  string
let contact = discriminated(Contact, kind)

let member = schema:
  name:    string.min(1)
  role:    string.oneOf(["admin", "maintainer", "viewer"])
  contact: contact                              # discriminated union nested in an
                                                # object that is itself in an array

# A discriminated union: a deploy target, tagged by `kind`. The container port
# is a uint16, so its range (0..65535) is enforced during validation.
type
  DeployKind = enum dkStatic = "static", dkContainer = "container"
  Deploy = object
    env*: string                                  # shared by every branch
    case kind*: DeployKind
    of dkStatic: dir*: string
    of dkContainer:
      image*: string
      port*:  uint16                              # sized: out-of-range is an issue
let deploy = discriminated(Deploy, kind)

# An untagged union: `created` accepts unix seconds OR an ISO 8601 string, and
# both produce a `Time` (the string branch via `transform`). The field is read
# from the JSON key `created_at` via `alias`.
let flexTime = oneOfSchema(
  timestamp(),
  str().datetime.transform(proc(s: string): Time =
    parseTime(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())))

# The top-level schema, inference-first.
let project = schema:
  api:        literal("v1").default("v1")       # pinned; may be omitted
  name:       string.min(1).max(100)
  slug:       string.slug.refine("must not be a reserved word",
                proc(v: string): bool = v != "admin")
  version:    string.semver                     # built-in format
  homepage:   string.url.nullable               # key required; null clears it
                .describe("Project homepage; null when unset")
  visibility: string.oneOf(["public", "private", "internal"]).default("private")
  stars:      int.min(0, "stars cannot be negative").default(0)
  location:   schemaOf(GeoPoint).optional       # optional plain-type field
  owner:      owner                             # nested inferred object
  members:    member.array.default(@[])         # array of nested objects
  tags:       string.array.default(@[])
  created:    flexTime.alias("created_at")      # union + transform + alias
                .describe("Creation time, unix seconds or ISO 8601")
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
  "version": "0.4.0",
  "homepage": "https://github.com/cryo2010/nim-schematic",
  "visibility": "public",
  "stars": 42,
  "location": { "lat": 40.7128, "lng": -74.0060 },
  "owner": { "name": "Ada", "email": "ada@example.com", "age": 36 },
  "members": [
    { "name": "Bo", "role": "maintainer", "contact": {"kind":"email","address":"bo@x.io"} },
    { "name": "Cy", "role": "viewer",     "contact": {"kind":"phone","number":"+15551234"} }
  ],
  "tags": ["nim", "validation"],
  "created_at": "2023-11-14T22:13:20Z",
  "thread": {
    "author": "Ada", "body": "First!",
    "replies": [ { "author": "Bo", "body": "Nice work" } ]
  },
  "metadata": { "team": "core", "priority": 3 },
  "deploy": { "kind": "container", "env": "prod", "image": "app:1.2", "port": 8080 }
}
""")

echo p.name, " v", p.version, " (", p.visibility, ", api ", p.api, ")"
echo "  homepage: ", p.homepage.get                    # nullable -> Option[string]
echo "  owner: ", p.owner.name, " <", p.owner.email, ">, age ", p.owner.age.get
echo "  where: ", p.location.get.lat, ", ", p.location.get.lng
echo "  members: ", p.members.len
echo "  member 2 contact: ", p.members[1].contact.kind, " ", p.members[1].contact.number
echo "  created: ", p.created.utc.year, " (a Time, from either wire form)"
echo "  first reply by: ", p.thread.get.replies[0].author
echo "  metadata.team: ", p.metadata.get["team"].getStr
echo "  deploy: ", p.deploy.get.kind, " image=", p.deploy.get.image, " port=", p.deploy.get.port

# Defaults kicked in for anything omitted; `homepage` is nullable, so the key
# must be present, but null is fine. `created_at` here uses the unix form.
let minimal = project.parse("""
  { "name": "x", "slug": "x", "version": "1.2.3", "homepage": null,
    "created_at": 1700000000,
    "owner": { "name": "Ed", "email": "ed@x.io" } }
""")
echo "\nminimal: api=", minimal.api, " visibility=", minimal.visibility,
     " stars=", minimal.stars, " homepage?=", minimal.homepage.isSome,
     " created=", minimal.created.toUnix

# ---- unhappy path: every problem at once, each with a path ----
let bad = project.tryParse("""
{
  "api": "v2",
  "name": "",
  "slug": "Not A Slug",
  "version": "1.0",
  "homepage": "not a url",
  "visibility": "secret",
  "stars": -3,
  "owner": { "name": "A", "email": "nope" },
  "members": [ { "name": "Bo", "role": "root", "contact": {"kind":"fax"} } ],
  "created_at": true,
  "thread": {
    "author": "",
    "body": "hi",
    "replies": [ { "author": "x", "body": "" } ]
  },
  "deploy": { "kind": "container", "env": "prod", "image": "app:1.2", "port": 70000 }
}
""")
echo "\n", bad.issues.len, " validation issue(s):"
for issue in bad.issues:
  echo "  - ", issue

# ---- JSON Schema output, with metadata ----
let projectDoc = project.title("Project").describe("A hosted project definition")
let js = toJsonSchema(projectDoc)
echo "\nJSON Schema: title=", js["title"].getStr,
     ", homepage type=", js["properties"]["homepage"]["type"],
     ", created is a union: ", js["properties"]["created_at"].hasKey("anyOf")
