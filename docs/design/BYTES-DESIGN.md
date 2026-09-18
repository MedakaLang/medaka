# Bytes — a packed byte string for Medaka

**Status:** B1 shipped, and B2's representation change has landed —
`stdlib/bytes.mdk` is a `newtype` over the runtime's packed `ByteBlock`
buffer, so a byte string costs one byte per byte. The mutable and growable
siblings and the caller migration are later milestones of the Bytes epic
(#3134).

This document records the decisions the epic is built on, so later waves cite
a written ruling instead of a recollection. Each section below is one ruling
taken on 2026-09-16, plus the one deviation accepted on 2026-09-17.

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
- A builtin head cannot be imported by name, so `import bytes.{Bytes}` would
  have nothing to bring into scope.
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
  a hash or cipher state that is overwritten in place and never resized.
- **`ByteBuf`** — growable, written in pure Medaka over the other two, with
  zero new intrinsics.

Together they are 46 exported names and 18 externs — the full B3 surface.
B1 builds only the subset listed under "The B1 surface" below.

`stdlib/bytebuilder.mdk` already is a growable byte buffer (`Vector Int`
backed, `buildArray : Builder -> Array Int`). The overlap with `ByteBuf` is
real and is resolved in the milestone that introduces `ByteBuf`, not in B1;
B1 adds no second growable buffer.

---

## Ruling 2 — `toUtf8`/`fromUtf8` are duplicated for the migration's duration

Byte-returning twins land alongside the originals. Callers move module by
module in wave order, and the old pair is deleted at B6.

With the eventual packed representation the new twin is `O(1)` — a view over
the `String` cell's existing UTF-8 bytes. Today, with no representation
change, it is `O(n)` exactly like the original.

**Deviation, accepted 2026-09-17:** the twins land in `stdlib/bytes.mdk`, not
in `stdlib/string.mdk`, and are named `toUtf8Bytes` / `fromUtf8Bytes`.
`stdlib/string.mdk` imports only `core` today, and a `Bytes`-returning
function there would drag `stdlib/bytes.mdk` into nearly every module's import
closure, the compiler's included — the exact bootstrap exposure B1 is
sequenced to avoid.

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

Not part of B1. `slice`, `view` and `compact` are B3 names; the ruling is
recorded here for them to cite.

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
byte count is exported as `bytesLength` rather than `length`: `length` is
`Foldable`'s method and the prelude exports it, so a bare `length` here would
be an ambiguous occurrence at every import site.

---

## The B1 surface

`stdlib/bytes.mdk` exports exactly this, and nothing more:

```medaka-nocheck: a signature listing, not a standalone program
export newtype Bytes = Bytes (Array Int)   -- constructor is module-private
export fromArray     : Array Int -> Bytes
export toArray       : Bytes -> Array Int
export bytesLength   : Bytes -> Int
export get           : Int -> Bytes -> Option Int
export impl Index Bytes Int Int            -- `b[i]`, panics out of range
export impl Eq Bytes
export impl Ord Bytes
export toUtf8Bytes   : String -> Bytes
export fromUtf8Bytes : Bytes -> String
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

## Sequencing

| Milestone | Content |
|---|---|
| B1 | `newtype` staging wrapper over `Array Int`, no representation change |
| B2 | Packed representation behind the same surface |
| B3 | `MutBytes`, `ByteBuf`, `slice`/`view`/`compact` — the full 46-name surface |
| B4–B5 | Caller migration, module by module, in wave order |
| B6 | Delete `toUtf8`/`fromUtf8` and the remaining `Array Int`-as-bytes uses |

B1's whole job is that every later mistake is a compile error.

---

## Open for B2 — domain enforcement

The `0` to `255` domain `Bytes` documents is not enforced at B1: `fromArray`
accepts any `Int`, and `get`/`b[i]`/`eq`/`compare` all read an out-of-range
element back unchanged. Whether B2's packed representation masks
out-of-range elements, rejects them, or leaves the discipline to the caller
is not decided here.
