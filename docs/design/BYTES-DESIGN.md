# Bytes — a packed byte string for Medaka

**Status:** B1, B2 and B3 have all shipped. `stdlib/bytes.mdk` is a `newtype`
over the runtime's packed `ByteBlock` buffer, so a byte string costs one byte
per byte, and the minimal mutable sibling `MutBytes` (allocate, write, read,
freeze) shipped in B2. B3 (sprint `enough-to-carry-a-path`, #3196) shipped
`slice`/`append`/`indexOf`/`Hashable Bytes`, `writeStdoutBytes`, and
`stdlib/bytebuilder.mdk`'s `Builder` re-backed on a packed `ByteBlock` —
**`ByteBuf` as a distinct growable type was withdrawn**; `bytebuilder.mdk`
became the one growable byte buffer instead of a second one being added
alongside it (Ruling 1 below is corrected accordingly). `slice`/`view`/`compact`
as a triad and the caller migration remain later milestones of the Bytes
epic (#3134).

**The element type is `U8`** (#3415, integer-stack milestone N2,
`docs/design/INTEGER-TYPES-DESIGN.md`). `get`, `b[i]`, `fold`, `forEach`,
`any`, `all` and `map` hand out a `U8`, and `map`, `elemIndex`,
`mut_bytes.setInPlace`, `mut_bytes.fill` and `bytebuilder.emitU8` take one.
Indices, lengths and offsets stay `Int`, and so do the bulk `Array Int` doors
(`fromArray`, `fromArrayAssumeByteDomain`, `toArray`). `byteparser` still
reads an `Array Int` (#3414); its single-byte primitives hand out a `U8` and
fail the parse on an element outside `0` to `255`. See the element-type
section below for what this changed in the rulings.

This document records the decisions the epic is built on, so later waves cite
a written ruling instead of a recollection. Each section below is one ruling
taken on 2026-09-16, plus the one deviation accepted on 2026-09-17, plus the
**B3 correction** noted where it applies (dated 2026-09-19).

---

## Why a type at all

Medaka spells "a sequence of bytes" as `Array Int` today — a file's contents,
a hash digest, a UTF-8 encoding and a list of small numbers are all the same
type, so nothing catches handing codepoints to a function that wants bytes.
`Array Int` also costs a full boxed machine word per byte, which is the
8.0× memory factor the packed representation is meant to recover.

B1 introduces the *name* and nothing else: `newtype Bytes = Bytes (Array Int)`
in `stdlib/bytes.mdk`, with a module-private constructor. The representation
is unchanged, so B1 cannot regress performance, and every call site that must
eventually change is already a compile error rather than a silent mismatch.

`Array Int` survives the epic. It is the FFI-crossable sequence type, and
nothing here retires it.

---

## The B2 shape — a `newtype` over the runtime's packed block

B2 keeps the wrapper and swaps the payload: `newtype Bytes = Bytes ByteBlock`,
where `ByteBlock` is the runtime's packed byte buffer — one byte per byte,
eight primitives, implemented by all three engines.

The wrapper is not what makes dispatch work. `Eq`, `Ord`, `Debug`, `Index`,
`Hashable` and `Display` all attach to a builtin type head directly, so a
`Bytes` that *was* the builtin head would still dispatch. The wrapper is what
makes `Bytes` behave like a library type:

- A builtin head claims its identifier in every program at once, so any user's
  own `data Bytes = …` becomes a hard `Duplicate type` error.
- A builtin head cannot be constructed or pattern-matched by name.
- A builtin head must be listed in the compiler frontend's hardcoded
  `primitiveTypes`, which puts a library type's name inside the frontend.

So the payload is a builtin and the name is not.

---

## Ruling 1 — three types

The full surface is three types, not one:

- **`Bytes`** — immutable, packed. The type in this document's title, and the
  only one B1 builds.
- **`MutBytes`** — mutable, packed, fixed length. The crypto scratch buffer:
  a hash or cipher state that is overwritten in place and never resized. It
  lives in `stdlib/mut_bytes.mdk`, not `stdlib/bytes.mdk`: one module cannot
  export two `length`s, so each type carries the bare names in its own.
- **`ByteBuf`** — growable, written in pure Medaka over the other two, with
  zero new intrinsics.

Together they were planned as 46 exported names and 18 externs. B1 built only
the subset listed under "The B1 surface" below.

**Correction, 2026-09-19 (B3):** `stdlib/bytebuilder.mdk` already was a
growable byte buffer (`Vector Int` backed, `buildArray : Builder -> Array
Int`) when this ruling was written, and the overlap it flags was resolved by
re-backing `bytebuilder.mdk`'s existing `Builder` on a packed `ByteBlock`
(`fromByteBlockPrefix : Int -> ByteBlock -> Bytes` is the new seam) rather than
by building a separate `ByteBuf` type. `ByteBuf` as a distinct name is
withdrawn; the "46 exported names" figure no longer describes the shipped
surface.

---

## Ruling 2 — `toUtf8`/`fromUtf8` are duplicated for the migration's duration

Byte-returning twins land alongside the originals. Callers move module by
module in wave order, and the old pair is deleted at B6.

With the eventual packed representation the new twin is `O(1)` — a view over
the `String` cell's existing UTF-8 bytes. Today, with no representation
change, it is `O(n)` exactly like the original.

**Deviation, accepted 2026-09-17:** the twins land in `stdlib/bytes.mdk`, not
in `stdlib/string.mdk`. `stdlib/string.mdk` imports only `core` today, and a
`Bytes`-returning function there would drag `stdlib/bytes.mdk` into nearly
every module's import closure, the compiler's included — the exact bootstrap
exposure B1 is sequenced to avoid.

**Amended at B5 (#3221):** the twins are named `encodeUtf8` /
`decodeUtf8` / `decodeUtf8Lossy`, not `toUtf8Bytes` / `fromUtf8Bytes`. The way
back is two functions rather than one because there is no total
`Bytes -> String`: `byteBlockToString` blits bytes into a `String` cell
without reading them, so a single `Bytes -> String` door hands back a corrupt
`String` at exit 0 on any byte sequence that is not UTF-8. `decodeUtf8`
answers `Option String` and refuses; `decodeUtf8Lossy` substitutes U+FFFD per
maximal subpart. `toUtf8Bytes` / `fromUtf8Bytes` are removed, not deprecated.

---

## Ruling 3 — out-of-range access copies `stdlib/array.mdk`'s pairing exactly

Operator and positional forms panic; `get` is the `Option`-returning form.
`b[i]` desugars to the `index` method of the `Index` interface
(`stdlib/core.mdk`), whose signature `index : c -> k -> v` is total, so an
instance has no `None` to return and must panic.

`stdlib/array.mdk` states the pairing in its own module doc comment, and
`stdlib/bytes.mdk` repeats it verbatim. On one out-of-range index `i`:
`get i b` is `None`, and `b[i]` raises `E-INDEX-OOB`.

---

## Ruling 4 — `slice` copies; `view` is the explicit `O(1)` opt-in

Not part of B1. **Correction, 2026-09-19:** `slice` shipped in B3 (copying,
per this ruling); `view` and `compact` did not — they remain deferred to a
later milestone. The ruling is recorded here for whichever milestone ships
them to cite.

A slice that shares its parent's storage retains the whole parent. The
concrete hazard is the pds one: a header or field value sliced out of a large
request body and stored in a record that outlives the body keeps the body
alive. Java shipped an `O(1)` substring for twelve years and removed it in
Java 7 over exactly this cost. Medaka has no lifetime escape analysis to catch
it, and lint cannot check the discipline either — the linter has no type
environment, so no rule can key on "this value is a view".

So the default copies, and sharing is a separately named function the author
has to reach for. The 8.0× memory win comes from packing, not from views, so
this ruling costs the epic nothing.

---

## Ruling 5 — `stdlib/regex.mdk` is out of scope, permanently

`Vm.codes : Array Int` carries Unicode *codepoints* on the `String` path, and
character-class sets are codepoint ranges. Neither is a byte sequence, so
neither can ever become `Bytes`. This is not a deferral; the regex engine is
never migrated.

The same reasoning is why `Bytes` has no element type parameter, and therefore
cannot implement `Foldable`, `Mappable` or `Filterable` — those interfaces
range over a container of some element type, and `Bytes` is not one. This is a
kind-level impossibility rather than a decision to revisit, and it is why the
byte count is an ordinary export rather than a method. It was first exported
as `bytesLength`, because a bare `length` under `import bytes.*` was an
ambiguous occurrence; the export is now `length`, and a wildcard import of
`bytes` is no longer a supported form. Named in an import list `length`
shadows the prelude's method for the whole importing module, so a module that
uses both reaches this one through an alias (`import bytes as B`).

---

## The B1 surface

`stdlib/bytes.mdk` exports exactly this, and nothing more:

```medaka-nocheck: a signature listing, not a standalone program
export newtype Bytes = Bytes (Array Int)   -- constructor is module-private
export fromArray     : Array Int -> Bytes
export toArray       : Bytes -> Array Int
export length        : Bytes -> Int         -- was `bytesLength` until B5
export get           : Int -> Bytes -> Option Int
export impl Index Bytes Int Int            -- `b[i]`, panics out of range
export impl Eq Bytes
export impl Ord Bytes
```

There is deliberately no `fromList` and no builder. `Foldable`, `Mappable` and
`Filterable` are declined at the kind level, per ruling 5.

B2 moves two rows of that surface. `fromArray` becomes
`Array Int -> Option Bytes` and answers `None` on an element outside `0` to
`255`, and a transitional `fromArrayAssumeByteDomain : Array Int -> Bytes`
joins it, masking to the low eight bits instead of refusing, for callers whose
elements are bytes by construction. The transitional door is removed at B6,
alongside `toUtf8`/`fromUtf8`.

`stdlib/bytes.mdk` is not imported by `stdlib/core.mdk` (the only
auto-prelude) or by any `compiler/` module at B1 — `stdlib/hex.mdk` does
import it. Keeping it out of the compiler's import closure is what makes B1
free of a seed re-mint.

---

## The `++` verdict

`Bytes` got a `Semigroup` instance in B3 (`append`, reached by `b1 ++ b2`).
`append` dispatches correctly on `Bytes` through every syntactic form that
lets the compiler recover the operand type at the call site — infix, an
operator section, a `Semigroup a =>`-constrained function body, and an
immediately-applied lambda all reach `append` and allocate the joined length
once. Binding `(++)` — or a hand-written `x y => x ++ y` lambda — to a name
with `let` and applying it through that name is a separate, pre-existing
native-backend gap: it panics cleanly under `medaka run` but segfaults the
compiled binary (`E-FATAL-SIGNAL`), tracked as #3204. This is not `Bytes`-
specific — it reproduces on any hand-written `Semigroup` instance — but B3 is
what made it reachable through ordinary stdlib use, since `Bytes` is the
first non-`String`/`List` stdlib type with one.

## Sequencing

| Milestone | Content |
|---|---|
| B1 | `newtype` staging wrapper over `Array Int`, no representation change |
| B2 | Packed representation behind the same surface, plus the minimal `MutBytes` (allocate, write, read, freeze) |
| B3 | `slice`/`append`/`indexOf`/`Hashable Bytes`, `writeStdoutBytes`, `bytebuilder.mdk`'s `Builder` re-backed on a packed `ByteBlock` (`fromByteBlockPrefix`) — **not** a separate `ByteBuf` type, which is withdrawn. `view`/`compact` deferred to a later milestone (no consumer needs the `O(1)`-aliasing opt-in yet; Ruling 4 still applies once one does) |
| B4 | Caller migration, first measured path: `stdlib/http.mdk`'s request scan/parse, `stdlib/net_async.mdk`'s recv chain, and the socket read loop in `pds/shell/server.mdk` — `sprint a-byte-costs-a-byte` (#3210), measured with `pds/test/performance_resource_main.mdk`'s `inbound-alloc` probe |
| B5 | Remaining caller migration, module by module, in wave order |
| B6 | Delete `toUtf8`/`fromUtf8` and the remaining `Array Int`-as-bytes uses |

B1's whole job is that every later mistake is a compile error.

---

## Ruling 6 — the byte domain has three doors, chosen by what the caller can know

The `0` to `255` domain `Bytes` documents was not enforced at B1: `fromArray`
accepted any `Int`, and `get`/`b[i]`/`eq`/`compare` all read an out-of-range
element back unchanged. B2 decides this, rather than leaving it open, with
three doors — which one applies is decided by what the caller can know about
its input, not by convenience:

- **Unvouched bulk data** — `fromArray : Array Int -> Option Bytes`, exactly
  like `charFromCode : Int -> Option Char`. Not masking, not a panic: an
  element outside `0`–`255` makes the whole call answer `None`.
- **Vouched-for bulk data** — `fromArrayAssumeByteDomain : Array Int -> Bytes`,
  naming the caller's promise the way `sha256AssumeByteDomain` already does. A
  broken promise truncates (masks to the low eight bits), because a packed
  byte cannot hold `300`. This door is **transitional**: its own doc block
  names B6 as its removal, alongside `toUtf8`/`fromUtf8`.
- **A positional write** — `mut_bytes`'s `setInPlace` **panics** on an
  out-of-range value, exactly as `array.setInPlace` already panics on an
  out-of-range index. Ruling 3 made this split for the index dimension; this
  extends it to the value dimension. An `Option`-returning write was
  considered and rejected: an unfireable `None` arm would land in every
  decoder loop in the tree that builds bytes one at a time. Superseded in
  its value half by the element type: since N2 the written value is a `U8`,
  so it cannot be out of range, and the refusal moved to the conversion into
  `U8` (see "The element type" below). The index half still panics.

Two corrections to this milestone's earlier description, each with its
mechanism:

- **No FFI-crossable-set change.** `ffiCrossableTy` governs user `extern`
  declarations only — `ffiCheckExternsGo` skips any name for which
  `ffiIsBuiltinExternName` holds (`compiler/types/typecheck.mdk:34389-34397`).
  Every primitive this milestone added is builtin, so none of them consults
  the predicate, and `Array Int` remains the crossable set unchanged.
- **No seed re-mint forced.** `test/bootstrap_from_seed.sh:44-77` is tolerant
  by default: the seed must still *compile* HEAD (required), not be
  byte-current with it (a drift detector). A re-mint is forced only if the old
  seed emitter can no longer compile HEAD, which happens only if
  `compiler/**` or `stdlib/core.mdk` adopts `Bytes` — out of scope for this
  epic (see "The B1 surface" above).

## The element type — a byte is a `U8` (#3415, 2026-09-25)

Val ruled on 2026-09-24 that a byte is a `U8`, a member of the fixed-width
family, rather than an `Int` or a bespoke `Byte`. N2 of the integer stack
carried it out. What it changed here:

- **The range check has one home.** The value-range panics in `map`,
  `setInPlace`, `fill` and `emitU8` are gone. A literal byte outside `0` to
  `255` is a compile-time error (`emitU8 300`), and a computed one crosses
  into `U8` through `fromInt`, which panics, or `u8.truncate`, which is the
  only masking door and is named for it. The three-door table above keeps its
  bulk rows unchanged.
- **Arithmetic on a read byte widens first.** `U8` arithmetic wraps, so code
  that combines bytes into a larger number writes `u8.toInt b`. A literal-
  seeded fold accumulator (`fold (acc b => acc + b) 0`) would otherwise sum in
  `U8` and wrap; the migration widened every such fold.
- **`Hashable Bytes` is unchanged.** A byte string still hashes as the
  `Array Int` of its bytes, and a `U8` hashes as its `Int`.
- **Not settled here:** a total `Array U8 -> Bytes` door (#3412) and a
  `toArray` over `Array U8` are new names, so they wait for a proposal. The
  comparison `b[i] == 13` does not type-check yet, because the literal
  defaults to `Int` before `Index` fixes the element type (#3437); code
  writes `u8.toInt b[i] == 13` until that is fixed.

`adoptByteBlockUnsafe`, `lendByteBlockUnsafe`, and `fromByteBlockPrefix` are
the only exports naming `ByteBlock` directly (`stdlib/bytes.mdk`'s
`# Kernel doors` section); B5 adds no more without a ruling.

---

## Ruling 7 — the `*Bytes` suffix names a shape, not a byte count (2026-09-20)

A `*Bytes` suffix on an exported name is licensed only where it disambiguates
that export from a differently-typed twin already living in the same
module — the pattern `stdlib/regex.mdk` already has in `find`/`findBytes` and
`isFullMatch`/`isFullMatchBytes`, where the bare name takes a `String` and the
suffixed one takes a byte sequence. Outside that pattern, a name that already
says "bytes" keeps its name at B6 and swaps its type from `List Int`/`Array
Int` to the packed `Bytes`, rather than being renamed to something else — the
suffix already told the truth about the *shape* of the value; only its
representation changes.

A `*Bytes` suffix that means something else entirely is not a suffix
violation and is out of this ruling's scope: a byte *count*
(`maxHttpRequestBytes : Int`, `checkHttpRequestBytes : Int -> Result String
Unit`), or a fixed-size digest array with no `Bytes`-typed twin to
disambiguate against yet (`sha256FixedBytes`, `hmacSha256FixedBytes`) — #3222's
own recommendation flagged the digest-array case as B5/B6 territory without
deciding it here, and this ruling does not decide it either.

`stdlib/regex.mdk`'s `Vm.codes : Array Int` (Unicode codepoints on the
`String` path) is unaffected by any of this — Ruling 5 above already put it
permanently out of scope, for reasons that have nothing to do with naming.
`isFullMatchBytes`/`findBytes` are a different, unrelated part of the same
module: they take a byte buffer, not codepoints, and ARE inside this ruling's
scope.

### B6 rename table

Derived by `git grep -nE '^[a-zA-Z0-9_]*Bytes[a-zA-Z0-9_]* :' -- 'stdlib/*.mdk'`
(excluding `*_test.mdk`), filtered to **exported** names — an unexported
`*Bytes` helper carrying the same suffix is not public API and has no B6
obligation of its own. The largest unexported group is `stdlib/http.mdk`'s
`lowerAsciiBytes`/`allTokenBytes`/`validFieldValueBytes`/`trimLeftOwsBytes`/
`trimRightOwsBytes`/`scanTokenEndBytes`/`skipOwsBytes`, each already the
`Bytes`-typed twin of an `Array Int`-typed private original the module's own
comment (`stdlib/http.mdk:354-361`) says B5 removes; also unexported:
`stdlib/http.mdk`'s `validBytes`/`headHeaderBytes`/`requestBytesVerdict`/
`decodeQueryBytes`/`validMediaBytes`, `stdlib/base32.mdk`'s `validBytes`,
`stdlib/byteparser.mdk`'s `takeBytesGo`, `stdlib/crypto/sha256.mdk`'s `digestBytes`,
`stdlib/bytes.mdk`'s `debugBytesHex`, `stdlib/crypto/hmac.mdk`'s `blockBytes`,
`stdlib/net.mdk`'s `testSentBytes`, and
`stdlib/net_async.mdk`'s `pendingRecvBytes`/`tryRecvBytes`/`recvBytesStep`/
`recvUntilBytes`/`recvUntilBytesStep`/`recvBytesWake`.

| Module | Export (current) | Current signature | B6 destination |
|---|---|---|---|
| `bytebuilder` | `buildBytes` | `Builder -> Bytes` | unchanged — already packed |
| `bytebuilder` | `appendBytes` | `Bytes -> Builder -> Unit` | **2026-09-21: renamed to `emitBytes`** |
| `bytebuilder` | `emitBytes` | `List Int -> Builder -> Unit` | **2026-09-21: name retires, deleted** |
| `byteparser` | `takeBytes` | `Int -> ByteParser (List Int)` | **2026-09-21: `Int -> ByteParser Bytes`** |
| `hex` | `encodeBytes` | `Bytes -> String` | unchanged — already packed |
| `hex` | `decodeBytes` | `String -> Result String Bytes` | unchanged — already packed |
| `bytes` | `writeStdoutBytes` | `Bytes -> <Stdout> Unit` | unchanged — already packed |
| `net_async` | `recvBytes` | `Connection -> Int -> Async <Net "_" \| e> (Result String Bytes)` | unchanged — already packed |
| `net_async` | `recvBytesWithin` | `Duration -> Connection -> Int -> Async <Clock, Net "_" \| e> (Result String Bytes)` | unchanged — already packed |
| `regex` | `isFullMatchBytes` | `Regex -> Array Int -> Int -> Int -> Bool` | B6: same name, `Array Int -> Bytes` — the licensed twin of `isFullMatch : Regex -> String -> Bool` |
| `regex` | `findBytes` | `Regex -> Array Int -> Int -> Int -> Option Match` | B6: same name, `Array Int -> Bytes` — the licensed twin of `find : Regex -> String -> Option Match` |
| `sha256` | `sha256FixedBytes` | `Array Int -> Array Int` | undecided — fixed-digest array, no `Bytes`-typed twin yet; not this ruling's call |
| `hmac` | `hmacSha256FixedBytes` | `Array Int -> Array Int -> Array Int` | undecided — same reasoning as `sha256FixedBytes` |

The two 2026-09-21 rows are #3222's Half B: byteparser's `takeBytes` takes the
packed name; bytebuilder's `emitBytes` and `appendBytes` swap roles, so the
`Bytes`-taking bulk form keeps the name that already said "bytes." Every real
caller (`sqlite/lib`, `gzip/lib`, `pds/lib`, `pds/shell/server.mdk`) was
updated in the same change.
