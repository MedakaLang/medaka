# Effects V: Authority in Data

A path that has been checked once should not have to be checked again every time
it is passed along. A file handle, a database connection, a socket: each is a
value that was opened at some authority, and everything done through it happens
at that authority. This chapter shows how a data type records that, so that the
authority travels with the value.

## An index of kind `Authority`

A type parameter can be declared to range over the authorities of a label:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

data Handle (p : Authority Store) = Handle (String @p)

open : (path : String) -> Handle path
open path = Handle path

read : Handle p -> <Store p> Int
read (Handle s) = load s

cfg : Unit -> Handle "cfg/*"
cfg () = open "cfg/app.toml"

readCfg : Unit -> <Store "cfg/*"> Int
readCfg () = read (cfg ())

anyAt : String -> Handle *
anyAt s = open s

main =
  println (readCfg ())
  println (read (anyAt "whatever"))
```

```medaka-expect
1
1
```

`data Handle (p : Authority Store)` says `p` is not a type but an authority in
`Store`'s domain, and the one field, `String @p`, is a string that lies within
it. The four functions show the four ways an index is written:

- `Handle path` in `open`, a **named argument**: the handle's authority is
  whatever path the caller opened.
- `Handle p` in `read`, a **variable**: `read` works on a handle at any
  authority, and is charged `<Store p>`, that authority, exactly as a named
  argument would be.
- `Handle "cfg/*"` in `cfg`, a **literal**.
- `Handle *` in `anyAt`, the **whole domain**, the index of a handle opened at a
  path the compiler could not read.

`check` prints `main : <Stdout, Store> Unit`, because `anyAt "whatever"` is a
`Handle *` and reading it charges the whole domain. Drop that line and the row
becomes `<Stdout, Store "cfg/*">`.

## The constructor is the proof

What keeps a `Handle "cfg/*"` honest is that applying `Handle` checks its
argument against the field's qualifier. There is no other way to make one:

```
error: data.mdk:9:19: `forged` reaches "secrets/key" where its declared bound admits only "cfg/*"; stay within the bound, or widen it
  |
9 | forged () = Handle "secrets/key"
  |                    ^
```

So a value of type `Handle "cfg/*"` is evidence: whoever built it passed a string
that the compiler read as lying within `"cfg/*"`. Functions that consume the
handle can rely on that without re-reading the string, which they could not do
anyway, since by then it is a runtime value.

Records work the same way. A qualified field is checked at construction and at
update, and reading it gives the declared type back:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

data Conf (p : Authority Store) = Conf { path : String @p, retries : Int }

readConf : Conf p -> <Store p> Int
readConf c = load c.path

main =
  let c = Conf { path = "cfg/app.toml", retries = 3 }
  println (readConf c + c.retries)
```

```medaka-expect
4
```

## The index is invariant

A `Handle "cfg/app.toml"` is not a `Handle "cfg/*"`, even though the first
authority lies within the second. Index arguments have to be equal:

```
error: data.mdk:6:10: authority index mismatch: "cfg/*" vs "cfg/app.toml"; an authority in a type argument is invariant, so write the same index on both sides or name it, `Handle p`
  |
6 | widen h = h
  |           ^
```

The reason is the same one that makes a `Ref` invariant in
[chapter 2](effects-2-polymorphism.md): a type may use its index in a field
that is written as well as read, and widening it would let a narrower value be
stored where a wider one is expected. The message names the way out. A function
that should accept handles at any authority takes `Handle p` and is charged `p`.

Impls do the same. An `impl` head takes a variable in the index slot, never a
written authority, because instances are chosen by the type's head and the index
is erased:

```medaka
effect Store Prefix

data Handle (p : Authority Store) = Handle (String @p)

impl Display (Handle p) where
  display (Handle s) = "handle at \{s}"

main =
  println (Handle "cfg/app.toml")
  let h = Handle "anything" : Handle *
  println h
```

```medaka-expect
handle at cfg/app.toml
handle at anything
```

## A directory: an index that ranges over patterns

A handle names one file. A *directory* is a value under which a program builds
many paths, `root ++ "blocks/" ++ cid`, and a `Handle`-style index cannot follow
that: `root` may be an exact element, and an exact element admits nothing below
itself, so the extension is the whole domain. A `*` on the kind makes the index
range over patterns only, so an extension of the root on the right stays within
it ([chapter 4](effects-4-authority.md#pattern-ranging-binders)):

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

data DataDir (d : Authority Store*) = DataDir (String @d)

readBlock : DataDir d -> String -> <Store d> Int
readBlock (DataDir root) cid = load (root ++ "blocks/" ++ cid)

sub : DataDir d -> String -> DataDir d
sub (DataDir root) name = DataDir (root ++ name ++ "/")

dataDir : DataDir "data/*"
dataDir = DataDir "data/"

main =
  println (readBlock dataDir "b1")
  println (readBlock (sub dataDir "scratch") "b2")
```

```medaka-expect
1
1
```

`readBlock` is charged `Store d`, whatever directory it was given, and `sub`
returns a directory at the same authority. `DataDir "data/"` is a `DataDir
"data/*"`: a root built from an exact string is closed to the pattern it
begins, since the directory will be extended. So `check` prints `main :
<Stdout, Store "data/*"> Unit`, and the program's manifest grants `"data/*"`.
A test can pass a scratch directory instead, and only the instantiation
reaches the row.

`d` in `readBlock` is written bare, so it takes the range of the slot it fills.
A written exact index, `DataDir "data/app.db"`, is refused, and so is a binder
that ranges over the whole domain, `(p : String @Store) -> DataDir p`: either
could stand for an exact element. Both are `T-AUTHORITY-PATTERN`, and the
second names the fix, `(p : String @Store*)`. At run time the directory's
grant is forwarded like any other, so a name that climbs out of it,
`readBlock dataDir "../secret"` on a real file extern, is refused at the call:
`data/../secret is outside the granted authority ["data/*"]`.

## Hiding the index

Sometimes the authority is not known until runtime and does not need to be part
of the type: a handle chosen from a list, say. A constructor can bind an
authority *existentially*, with a kinded group in front of its fields:

```medaka
effect Store Prefix

load : (path : String) -> <Store path> Int
load _ = 1

data Handle (p : Authority Store) = Handle (String @p)

data AnyHandle = AnyHandle (p : Authority Store) (Handle p)

read : Handle p -> <Store p> Int
read (Handle s) = load s

readAny : AnyHandle -> <Store> Int
readAny (AnyHandle h) = read h

pickOne : Bool -> AnyHandle
pickOne useCfg =
  if useCfg then
    AnyHandle (Handle "cfg/app.toml")
  else
    AnyHandle (Handle "data/x")

main = println (readAny (pickOne True))
```

```medaka-expect
1
```

`AnyHandle` has no index; it wraps a handle at some authority and forgets which.
Matching on it, in a function clause as `readAny` does or in a `match` arm,
brings the authority back into scope as a fresh name for the duration of that
clause or arm. Inside, `h` is a `Handle p` for that `p`, and `read h` is charged
`<Store p>`. Since nobody outside knows what `p` is, the only bound that admits
it is the bare label, and `readAny` says `<Store>`. Anything narrower is refused:

```
error: data.mdk:14:29: `readAny` reaches p where its declared bound admits only "cfg/*"; stay within the bound, or widen it
  |
14 | readAny (AnyHandle h) = read h
  |                              ^
```

Only a clause or an arm can open an existential, because those have an end, and
the opened authority may not be used past it. A `let` pattern has no such end:

```
error: data.mdk:15:22: this pattern opens the existential authority `p`, which only a `match` arm or a function clause can scope; match on the value, or take it as a clause parameter
  |
15 |   let (AnyHandle h) = any
  |                       ^
```

## Exporting an indexed type

Across modules, a constructor is a proof only if applying it actually checks
something. `public export data` makes a constructor usable from other modules,
and the compiler requires that every such constructor carry its authority
parameter in some field:

```
error: data.mdk:3:55: constructor `Token` of public type `Token` carries its authority parameter `p` in no field, so another module could invent an authority; export `Token` abstractly with `export data`, or give `Token` a field that carries `p`
  |
3 | public export data Token (p : Authority Store) = Token Int
  |                                                        ^
```

A field *carries* the parameter when every value of the field's type holds a
value at that authority: a qualified string, a tuple containing one, or another
indexed type all of whose constructors carry it. A `List (Handle p)` does not,
because the empty list is a `List (Handle p)` at every `p`, and a closure does
not, because an idle closure is one too.

The alternative is the usual one for a handle type: export it abstractly, so
only the declaring module can build one, and export the functions that do:

```medaka-project
-- file: store.mdk
export effect Store Prefix

export
load : (path : String) -> <Store path> Int
load _ = 1

export data Handle (p : Authority Store) = Handle (String @p)

export
open : (path : String) -> Handle path
open path = Handle path

export
read : Handle p -> <Store p> Int
read (Handle s) = load s

-- file: main.mdk
import store.{Handle, open, read}

readCfg : Unit -> <Store "cfg/*"> Int
readCfg () = read (open "cfg/app.toml")

main = println (readCfg ())
```

```medaka-expect
1
```

`main.mdk` never sees the `Handle` constructor. It can open a handle only through
`open`, whose signature fixes the index to the path, and read it only through
`read`, which charges that index. The module boundary and the effect row do the
same job from two sides.

The runtime's own handle types are declared this way, one step further out.
`Socket` and `ListenSocket` are `extern data` types with an `Authority Net`
parameter and no constructors at all; the only things that produce one are the
catalog externs, and `netTcpConnect : (host : String) -> Int -> <Net host>
Result String (Socket host)` gives the socket exactly the authority the
connection was granted. Every extern that uses a socket is then charged at its
index, so a program's `Net` row names the hosts it connected to and nothing else.

That covers authority in data. The last piece of the system is data that stores
not an authority but a whole computation, row included.
