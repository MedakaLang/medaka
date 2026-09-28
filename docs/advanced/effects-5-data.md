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

`check` prints `main : <IO, Store> Unit`, because `anyAt "whatever"` is a
`Handle *` and reading it charges the whole domain. Drop that line and the row
becomes `<IO, Store "cfg/*">`.

## The constructor is the proof

What keeps a `Handle "cfg/*"` honest is that applying `Handle` checks its
argument against the field's qualifier. There is no other way to make one:

```
error: data.mdk:9:19: Binding 'forged' reaches "secrets/key" where its declared bound admits only "cfg/*". Stay within the declared bound, or widen it to cover what the body reaches
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
error: data.mdk:6:10: Authority index mismatch: "cfg/*" vs "cfg/app.toml". An authority written as a type argument is invariant, so the two indices must be EQUAL, not merely one within the other: a `Handle "cfg/app"` is not a `Handle "cfg/*"`. Write the same index on both sides, or name the index (`Handle p`) where any authority is meant
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
error: data.mdk:14:29: Binding 'readAny' reaches p where its declared bound admits only "cfg/*". Stay within the declared bound, or widen it to cover what the body reaches
  |
14 | readAny (AnyHandle h) = read h
  |                              ^
```

Only a clause or an arm can open an existential, because those have an end, and
the opened authority may not be used past it. A `let` pattern has no such end:

```
error: data.mdk:15:20: This pattern opens the existential authority 'p', which only a `match` arm or a function clause can scope: the arm or clause ends where the authority's uses must end. Match on the value, or take it as a clause parameter, and use it inside
  |
15 |   let (AnyHandle h) = any
  |                     ^
```

## Exporting an indexed type

Across modules, a constructor is a proof only if applying it actually checks
something. `public export data` makes a constructor usable from other modules,
and the compiler requires that every such constructor carry its authority
parameter in some field:

```
error: data.mdk:3:55: Constructor 'Token' of public type 'Token' carries its authority parameter 'p' in no field, so applying it from another module would invent an authority nothing proves. Export 'Token' abstractly (`export data`, constructing it only here), or give 'Token' a field that carries 'p': a qualifier (`String @p`), a tuple holding one, or an index of a type whose every constructor carries it (`Handle p`; not `List (Handle p)`, whose empty list carries nothing, and not a closure)
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
