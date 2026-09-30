# Effects IV: Parameters and Authority

`<FileRead>` says a function may read files. It does not say which. For a
manifest that is the difference between "this plugin reads its own config" and
"this plugin reads anything", so a label can carry a *parameter*: a value from a
small domain that bounds *which* file, host, variable, or resource the label
reaches. This chapter is about those parameters, how the compiler works out what
a call is charged with, and how the answer follows a value through a program.

## A label with a domain

A declared label may name a domain. `Prefix` is the one for paths and hosts:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

readConfig : Unit -> <Store "cfg/*"> Int
readConfig () = load "cfg/app.toml"

readAll : Unit -> <Store> Int
readAll () = load "anything"

readBoth : Unit -> <Store "cfg/*", Store "data/*"> Int
readBoth () = load "cfg/a" + load "data/b"

main =
  println (readConfig ())
  println (readAll ())
  println (readBoth ())
```

```medaka-expect
1
1
2
```

Three new things are in that program. The signature of `load` names its argument,
`(path : String)`, and then uses the name in the row: `<Store path>` charges the
label at whatever path the caller passes. `readConfig` bounds its row with a
literal, `<Store "cfg/*">`, and its body is checked against it: `"cfg/app.toml"`
lies within `"cfg/*"`, so it is accepted. `readAll` writes the label bare, which
means the whole domain, any path at all, and `readBoth` writes two *atoms* of the
same label (an atom is one label with one parameter, the unit a row is made of),
which admits either.

Reading a path the bound does not admit is refused with the same message as any
other escape, now with parameters in it:

```
error: authority.mdk:7:21: Effectful value used where <Store "cfg/*"> is allowed, but it performs <Store "secrets/key">
  |
7 | readConfig () = load "secrets/key"
  |                      ^
```

The parameters are ordered. `"cfg/app.toml"` lies within `"cfg/*"`, which lies
within the bare label. A written element either ends in `*`, in which case it is
a pattern admitting everything that starts with the part before the star, or it
does not, in which case it is exact and admits only itself. `"cfg/app.toml"`
does not admit `"cfg/app.toml.bak"`; `"cfg/app.toml*"` does. Two patterns are
never merged into a wider one: `<Store "cfg/a/*", Store "cfg/b/*">` admits both
subtrees and nothing else, not `"cfg/*"`.

An exact element needs no `/`, because it admits only itself. The one thing
that may not be written is the empty string, which would be the prefix of
everything. So a bare filename is a legal bound:

```medaka
countNotes : Unit -> <FileRead "notes.txt"> Result String String
countNotes () = readFile "notes.txt"

main : <IO> Unit
main = println "ok"
```

```medaka-expect
ok
```

`medaka manifest` prints that element as it is, and the same text is a legal
`--allow` entry, so a manifest always round-trips through `check-policy`:

```
$ medaka manifest notes.mdk --fn countNotes
[package.capabilities]
FileRead = "notes.txt"

$ medaka check-policy notes.mdk --allow FileRead=notes.txt --fn countNotes
accepted. countNotes requires only <FileRead "notes.txt">
   no sample run: 'countNotes' is not a String -> String entry
```

## Named arguments

`(path : String) -> <Store path> Int` is the signature of an operation whose
authority is decided by its caller. Inside such a function, the body may forward
the named argument to another operation, but it may not reach anything else:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

under : (dir : String) -> <Store dir> Int
under dir = load dir

twice : (p : String) -> <Store p> Int
twice p = load p + load p

main =
  println (under "cfg/x")
  println (twice "data/y")
```

```medaka-expect
1
2
```

`check` prints `main : <Stdout, Store "cfg/x", Store "data/y"> Unit`. Each call
substituted its literal for the name, so the row `main` is charged with is exact.
And the compiler holds the body of `under` to its promise:

```
error: authority.mdk:7:18: Binding 'sneaky' reaches "secrets/key" where only dir is admitted: dir is an authority the caller chooses, so a body may forward the named argument or use it in an operation that keeps its authority, never reach a value it does not derive from. Perform the operation on the named argument, or widen the declared row to the label bare
  |
7 | sneaky dir = load "secrets/key"
  |                   ^
```

A name in a row is a variable of the signature, the way `a` is in `List a -> Int`,
and the rule for it is the one from [chapter 2](effects-2-polymorphism.md): the
caller chooses it, so the body must work for every choice. The name may only be
used to the right of the argument that binds it, and only in the same signature.

An extension of a named argument is the whole domain: a caller may pass an exact
element such as `"cfg/app.toml"`, which admits only itself, so
`load (dir ++ "/x")` is refused inside `under`. Forward the argument, and build
the longer path at the call site (or, when the body must extend it, declare the
argument pattern-ranging, [below](#pattern-ranging-binders)):

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

under : (dir : String) -> <Store dir> Int
under dir = load dir

inConfig : String -> <Store "cfg/*"> Int
inConfig name = under ("cfg/" ++ name)

main = println (inConfig "app.toml")
```

```medaka-expect
1
```

The built-in file, environment, and network externs are all declared this way:
`readFile : (path : String) -> <FileRead path> Result String String`,
`getEnv : (name : String) -> <Env name> Option String`,
`netTcpConnect : (host : String) -> Int -> <Net host> Result String (Socket host)`.
So a program that reads one file is charged with that one file, with nothing
written by the programmer:

```medaka
import string.{lines}

countLines : Unit -> <FileRead "notes/*"> Int
countLines () = match readFile "notes/today.txt"
  Ok text => length (lines text)
  Err _ => 0

main = println (countLines ())
```

```medaka-expect
0
```

(The file does not exist where the examples are run, so the count is 0. That is
itself the point: the effect and the failure are separate, and the row was
checked before anything ran.) The `io` module's `readLines`, which reads a file
and splits it, is declared the same way, `(path : String) -> <FileRead path>
...`, so a function that calls it can carry a narrow bound.

## How the compiler reads a path

When the argument to `load` is a literal, the parameter is that literal. When it
is something else, the compiler has to abstract it, and the rules are these:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

byName : String -> <Store "cfg/*"> Int
byName name = load ("cfg/" ++ name)

pick : Bool -> <Store "cfg/*", Store "data/*"> Int
pick useCfg =
  let path = if useCfg then "cfg/app.toml" else "data/app.db"
  load path

viaLet : Unit -> <Store "cfg/app.toml"> Int
viaLet () =
  let p = "cfg/app.toml"
  load p

main =
  println (byName "x")
  println (pick True)
  println (viaLet ())
```

```medaka-expect
1
1
1
```

- A **literal** is itself.
- A **concatenation** whose left operand is known extends it: `"cfg/" ++ name` is
  the pattern `"cfg/*"`, whatever `name` is. (Two literals concatenated are one
  literal.)
- An **interpolated part** is read like its operand written directly, so
  `"cfg/\{name}"` is `"cfg/" ++ name`, unless the program defines its own
  `display`, which interpolation calls.
- A **`let`-bound** name is whatever it was bound to, in the scope it was bound in.
- An **`if` or `match`** is the join of its branches, one element per branch.
- **Anything else** is the whole domain. A parameter of unknown origin, a function
  result, a field of a record, unless its type carries an authority of its own
  (the qualified values below): the compiler cannot know what string it holds, so
  it assumes any string.

The last rule is the one that matters for security. A path that arrives at
runtime abstracts to the whole domain, and the whole domain does not fit a bound:

```
error: authority.mdk:7:23: Effectful value used where <Store "cfg/*"> is allowed, but it performs <Store>
  |
7 | readConfig name = load name
  |                        ^
```

So a function bounded to `"cfg/*"` cannot be talked into reading a path its
caller chose outright. There is no separate check for "computed destinations";
the rule that unknown means everything, and everything fits nothing narrower
than the bare label, is that check. The price is that the abstraction is
conservative. It can over-approximate, refusing a program a human can see is
fine, and when that happens the remedy is to name the argument in the signature,
as `under` does above, and let the caller supply the authority.

A pattern is a prefix of the string, and a string is not yet a file:
`"cfg/" ++ name` is within `"cfg/*"` for every `name`, including
`"../secret.txt"`. So the check does not stop at the string. The authority the
compiler granted reaches the file function at the call, and the runtime compares
files, not strings: it resolves the path, `..` and symlinks included, and refuses
one that lands outside every element it was granted.

```medaka
readConfig : String -> <FileRead "cfg/*"> Result String String
readConfig name = readFile ("cfg/" ++ name)

main = println (readConfig "../secret.txt")
```

```medaka-expect
Err cfg/../secret.txt is outside the granted authority ["cfg/*"]
```

The same holds for a symlink inside `cfg/` that points out of it, and for a file
not created yet: a new file under `cfg/` resolves through the part of its path
that exists. A function that returns a `Result` answers with that `Err`;
`fileExists` and `canonicalizePath`, which have no error to return, panic with the
same message. The grant is also what the manifest records, so a host that trusts
`cfg/*` from the manifest reads it as the program does. A bare `<FileRead>`
grants every path, and confines nothing.

The compiler reads the part of a path it can see the same way. For `FileRead`
and `FileWrite`, whose file functions resolve the path, a bound is checked
against the path's canonical form: `.` and empty components are dropped, and
`..` removes the directory before it. So `"cfg/./" ++ name` is within
`"cfg/*"`, and `"cfg/../" ++ name` is not. It is `"./*"`, every path under
the working directory:

```medaka
readIn : String -> <FileRead "cfg/*"> Result String String
readIn name = readFile ("cfg/./" ++ name)

readBeside : String -> <FileRead "./*"> Result String String
readBeside name = readFile ("cfg/../" ++ name)

main = println "checked"
```

```medaka-expect
checked
```

Bounding `readBeside` to `"cfg/*"` instead is refused before anything runs:

```
error: authority.mdk:5:27: Effectful value used where <FileRead "cfg/*"> is allowed, but it performs <FileRead "./*">
  |
5 | readBeside name = readFile ("cfg/../" ++ name)
  |                            ^
```

A path that climbs above the working directory, such as `"../x"`, is within
no bound inside it, and a manifest grants it as the bare label. The compiler
resolves only what the program spells: a `..` inside `name` and a symlink are
the runtime's, as above. Every other label compares text, `Net` and your own
`effect Store Prefix` included, and there `..` is two characters.

The check has limits, each listed under "Open edges" in the
[reference](effects-7-reference.md):

- The runtime checks the path, and the operating system then opens it. A
  symlink swapped inside `cfg/` between those two steps can reach a file
  outside it.
- A wasm build cannot check a path at all, so `medaka build --target wasm`
  refuses a call that grants a pattern such as `"cfg/*"`, at that call. A
  whole-domain or exact-path grant builds, including through `io.readLines`
  or `fs.isFile`, which pass on their caller's grant.
- An authority opened from an existential, and an instance head's index
  inside a method body, are granted the whole domain. The declaration that
  reaches them is held to its own row, so that row bounds them.

## Sets and products

`Prefix` is one of three domains. `Set` is for labels whose parameter is one of a
finite set of names:

```medaka
effect Var Set

readVar : (name : String) -> <Var name> String
readVar _ = "value"

paths : Unit -> <Var {"HOME", "PATH"}> String
paths () = readVar "HOME" ++ ":" ++ readVar "PATH"

main = println (paths ())
```

```medaka-expect
value:value
```

A set bound admits exactly its members, and the same message reports a name that
is not one of them:

```
error: authority.mdk:7:44: Effectful value used where <Var {"HOME", "PATH"}> is allowed, but it performs <Var {"HOME", "SECRET"}>
  |
7 | paths () = readVar "HOME" ++ ":" ++ readVar "SECRET"
  |                                             ^
```

`Product` combines axes, each of which is a `Prefix` or a `Set`. The declaration
names the axes in order, and the first is the *primary* axis, the one a bare
string lifts into:

```medaka
effect Http Product (Host : Prefix, Method : Set)

request : (host : String) -> String -> <Http host> Int
request _ _ = 200

fetchApi : Unit -> <Http Host="api.example.com/*"> Int
fetchApi () = request "api.example.com/v1/items" "GET"

main = putStrLn "\{fetchApi ()}"
```

```medaka-expect
200
```

`<Http host>` lifts the argument into the primary axis, so it reads as
`<Http Host=host>` when `host` is used at this label alone. The two spellings
are not interchangeable when the same binder is also used at another label:
`<Http Host=host, FileRead host>` is accepted, while `<Http host, FileRead host>`
is refused ("used at labels from different domains"), because a whole-parameter
binder ranges over the product and an axis binder over the axis. An axis a row
does not mention is the whole of that axis. A written product may pin several:
`<Http Host="api.example.com/*" Method={"GET"}>`. Comparison is pointwise, so a
row that says nothing about `Method` does not fit a bound that restricts it.

Any axis can name an argument, so an operation whose method its caller decides
says so in its signature:

```medaka
effect Http Product (Host : Prefix, Method : Set)

request : (host : String) ->
  (method : String) ->
  <Http Host=host Method=method> Int
request _ _ = 200

getItems : Unit -> <Http Host="api.example.com/*" Method={"GET"}> Int
getItems () = request "api.example.com/v1/items" "GET"

main = putStrLn "\{getItems ()}"
```

```medaka-expect
200
```

Each argument is charged on its own axis, in that axis's domain: `host` is a
`Prefix` element and `method` a `Set` element. A literal `"GET"` is the
one-member set `{"GET"}`, which fits the bound. A method that arrives at runtime
is the whole `Method` axis, and it does not fit. Here `getAny` has the bound
`getItems` has, and takes its method as a `String` argument `m`:

```
error: method.mdk:7:46: Effectful value used where <Http Host="api.example.com/*" Method={"GET"}> is allowed, but it performs <Http Host="api.example.com/v1/items">
  |
7 | getAny m = request "api.example.com/v1/items" m
  |                                               ^
```

The performed row leaves `Method` out because the whole axis is its value.
Arguments passed in the wrong order are charged on the axes they land on, so
`request "GET" "api.example.com/v1/items"` performs `Host="GET"` and a method
named `"api.example.com/v1/items"`, and neither fits. Inside a function that
names both axes, extending an axis argument (`host ++ "/x"`) gives that axis's
whole domain, as extending any named argument does.

In a manifest a product renders as a table, and a label that holds several
elements renders as an array. The first transcript is the `Http` program above;
the second is the "How the compiler reads a path" program, whose `main` reaches
both subtrees:

```
$ medaka manifest product.mdk
[package.capabilities]
Http = { host = "api.example.com/*" }
Stdout = true
```

```
$ medaka manifest paths.mdk
[package.capabilities]
Stdout = true
Store = ["cfg/*", "data/*"]
```

One limit applies to everything written in source: a row may name at most 16
elements of one label, and a set literal at most 16 members. Inferred rows,
policies, and manifests have no cap.

```
error: authority.mdk:6:16: Invalid effect parameter on <Var>: a set holds at most 16 members, and this one has 17
  |
6 | many : Unit -> <Var {"a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10", "a11", "a12", "a13", "a14", "a15", "a16", "a17"}> String
  |                 ^
```

## Values that carry authority

So far authority has lived on arrows. A *value* can carry it too, written with a
spaced `@` after its type: `String @dir` is a string known to lie within the
authority `dir`. The compiler uses that to follow a path through a function that
does not itself perform anything:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

same : (dir : String @Store) -> String @dir
same dir = dir

choose : Bool -> (a : String @Store) -> (b : String @Store) -> String @(a | b)
choose first a b = if first then a else b

main =
  println (load (same "cfg/x"))
  println (load (choose True "cfg/x" "data/y"))
```

```medaka-expect
1
1
```

`same` returns its argument at the argument's own authority, so `load (same
"cfg/x")` is charged `Store "cfg/x"`, not the whole domain. `choose` returns one
of two arguments, and `@(a | b)` is the spelling for "within either". `check`
prints `main : <Stdout, Store "cfg/x", Store "data/y"> Unit`, which is what a caller
would hope for.

Neither function performs anything, and neither signature has a row. A
qualifier's name still needs a domain, some label's set of authorities for
`dir` to be an element of, and `(dir : String @Store)` writes it on the binder.
That `@Store` belongs to `dir`, not to the string: the argument is an ordinary
`String`, and naming the domain charges nothing. For a `Product` label the
domain is its primary axis, the one a bare string lifts into. An atom that
names the argument (`<Store dir>`) or an index (`Handle dir`) gives a binder a
domain too, and a binder may have several of these as long as they agree.
With none of them the compiler explains:

```
error: authority.mdk:6:32: The qualifier names 'dir', but no binder domain, effect atom or index in this signature names 'dir', so its authority has no domain: an authority is a path prefix, a name set or a product only as some label's parameter. Write the domain on the binder, `(dir : String @FileRead)`, name the label it bounds, `<FileRead dir>`, or index a handle by it, `Handle dir`, or drop the qualifier
  |
6 | same : (dir : String) -> String @dir
  |                                 ^
```

A helper like `same` may return its argument, or a value derived from it that
keeps its authority, but not an extension of it: `dir ++ "/index"` in the
result is the whole domain, for the reason an extension in a row is, unless
the binder ranges over patterns ([below](#pattern-ranging-binders)).

A qualifier may also be a literal, `String @"cfg/*"`. The written qualifier
of a result or a value is a bound. The body is abstracted by the rules in "How
the compiler reads a path", as an argument is, and the result must lie within
the bound. A use then sees the qualifier the signature wrote, not the body:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

configFile : String @"cfg/*"
configFile = "cfg/app.toml"

pickConfig : Bool -> String @"cfg/*"
pickConfig useApp = if useApp then "cfg/app.toml" else "cfg/db.toml"

main =
  println (load configFile)
  println (load (pickConfig True))
```

```medaka-expect
1
1
```

`check` prints `configFile : String @"cfg/*"` and
`main : <Stdout, Store "cfg/*"> Unit`. A use of `configFile` is charged the
pattern its signature promises, not the one file its body names, so the body
can change within `cfg/` without changing any caller's row. The same holds
across modules, which is how one module hands another an address it may
reach: an exported `loopback : String @"127.0.0.1"` passed to
`netTcpConnect` is charged `<Net "127.0.0.1">` in the importing module. A
body outside the bound is refused where it is written:

```
error: authority.mdk:7:13: Binding 'configFile' reaches "secrets/key" where its declared bound admits only "cfg/*". Stay within the declared bound, or widen it to cover what the body reaches
  |
7 | configFile = "secrets/key"
  |              ^
```

### Pattern-ranging binders

The extension rule exists because a caller may choose an exact element. A
binder that can only ever stand for a *pattern* (`"cfg/*"`, `*`, a join of
patterns) has no such caller: every pattern admits every right extension of a
value within it. A `*` after the label says so, `(dir : String @Store*)`:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

under : (dir : String @Store*) -> String -> <Store dir> Int
under dir name = load (dir ++ name)

withIndex : (dir : String @Store*) -> String @dir
withIndex dir = dir ++ "/index"

inConfig : String -> <Store "cfg/*"> Int
inConfig name = under "cfg/" name

main =
  println (inConfig "app.toml")
  println (load (withIndex "notes/"))
```

```medaka-expect
1
1
```

Both bodies extend `dir` on the right and stay within it. A caller that passes
an exact element is charged the pattern it begins: `under "cfg/" name` is
charged `Store "cfg/*"`, and `check` prints `main : <Stdout, Store "cfg/*",
Store "notes/*"> Unit`. So a caller bounded by one exact file, `<Store
"cfg/app.toml">`, cannot call `under "cfg/app.toml" ""`: it is charged
`"cfg/app.toml*"`. An extension on the left, `name ++ dir`, is still the
whole domain.

A data parameter takes the same `*` in its kind, `(d : Authority Store*)`
([chapter 5](effects-5-data.md) builds a data directory this way), and a bare
index variable in a signature (`Dir d`) takes the range of the slot it fills.
Three things are refused, each as `T-AUTHORITY-PATTERN`: a written exact
element in such a slot (`Dir "cfg/app.toml"`), a binder written without the
`*` filling one (`(dir : String @Store) -> Dir dir`, whose report names
`@Store*`), and a `*` on a label whose domain has no patterns but the whole
domain, a `Set` label or a `Product` whose first axis is a `Set`.

## Relations the compiler keeps

A function with no signature is free to be more precise than any signature could
say. When its body relates two authorities, the compiler keeps the relation as a
constraint on the inferred type:

```medaka
effect Store Prefix

data Dir (d : Authority Store) = Dir (String @d)

sub : Dir d -> String @d -> Dir d
sub (Dir _) s = Dir s

subIn h (Dir p) = sub h p

cfg : Dir "cfg/*"
cfg = Dir "cfg/"

inCfg (Dir p) = sub cfg p

main = println 1
```

```medaka-expect
1
```

```
sub : Dir d -> String @d -> Dir d
subIn : (a <= d) => Dir d -> Dir a -> Dir d
cfg : Dir "cfg/*"
inCfg : (d <= "cfg/*") => Dir d -> Dir "cfg/*"
```

`Dir` is a type indexed by an authority; [the next chapter](effects-5-data.md)
is about those. What matters here is the context `check` prints. `subIn` takes a
directory and a second directory whose authority must lie within the first's,
and rather than guess a single index for both, the compiler quantifies two and
records `a <= d` between them. `inCfg` fixes one side to `"cfg/*"`. A use that
violates the relation is refused at the use, naming the binding that carries it:

```
error: authority.mdk:14:6: 'inCfg' needs "data/x" to lie within "cfg/*" here: its inferred type relates those authorities (a `<=` in its context), and this use does not satisfy the relation. Pass values whose authorities satisfy it
  |
14 | bad = inCfg (Dir "data/x")
  |       ^
```

There is no syntax for writing such a context in a signature yet, so a binding
that needs one has to be left unsigned.

Everything in this chapter attached authority to a string as it moved through
calls. The next chapter attaches it to a data type, so that a value can carry its
authority around indefinitely.
