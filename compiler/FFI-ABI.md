# FFI ABI contract

**Status: decision, not implementation.** This document fixes the value-crossing
contract for the C FFI boundary the effect label `<FFI>` (#2071, `Prefix` domain)
already tracks. **No lowering exists yet** — `emitFfiCall` and the calling
convention that actually marshals a value across the boundary are #2074, next
sprint, out of scope here. This doc answers a narrower question first: *which
Medaka types may cross at all, and who owns the memory on each side* — so #2074
has a contract to implement against instead of inventing one arm at a time.

This doc is scoped to **value crossing**. It does not restate #2071's
effect-tracking ground (that a foreign call is `<FFI>`-effectful and how that
propagates) — see #2071 for that.

Prerequisite reading: `compiler/RUNTIME-DESIGN.md` §8 (native value
representation — RATIFIED 2026-06-07) and §9 (GC strategy — Boehm, decided
2026-07-16). Everything below is an application of those two decisions to a
boundary the runtime doesn't fully control.

## 1. The crossable set (v1)

| Medaka type | Native rep (§8) | Crossable |
|---|---|---|
| `Int` | immediate, low-bit-1, 63-bit | yes |
| `Float` | boxed `{header, double}` | yes |
| `Bool` | immediate, low-bit-1 | yes |
| `Char` | immediate, low-bit-1 (codepoint) | yes |
| `String` | boxed `{header, byte_len, cp_count, bytes…}` | yes, copy-at-boundary |
| `Array Int` | boxed `{header, len, Int elements…}` | yes, copy-at-boundary |

Every other value kind (`Tuple`, `List`, other-element `Array`, ADT/`Record`,
`Ref`, closures, thunks) is explicitly **not** in the v1 crossable set — see §3.

## 2. Ownership per type per direction

### 2.1 Immediates — `Int`, `Bool`, `Char`

These are not pointers (§8.1: low bit 1, the other 63 bits are the payload).
There is nothing to allocate and nothing to free on either side.

- **Medaka → C:** the tagged word is untagged to a plain C scalar at the call
  boundary (`ashr 1` for `Int`; same for `Bool`/`Char`'s codepoint/0-1 payload).
  The C function receives a plain `int64_t`/`int32_t`/etc, never the tagged
  representation. No ownership question arises.
- **C → Medaka:** the returned C scalar is tagged (`(x << 1) | 1`) on the way
  back in. Same non-issue: nothing was allocated, nothing to free.

### 2.2 `Float`

`Float` boxes (§8.4: boxed-first, `{i64 header, double}`), so unlike the other
scalars it *does* cross a GC-managed pointer.

- **Medaka → C:** the C function receives the **unboxed** `double`, not the
  cell pointer — the box is a native-backend-internal representation choice
  (§8.6: "boxing is invisible"), and it must not leak across an ABI boundary
  whose other side has no concept of a Medaka heap cell. The calling
  convention unboxes at the call site, symmetrically with how it unboxes
  `Int`.
- **C → Medaka:** a C function returning a `double` is reboxed into a fresh
  `{header, double}` cell via `mdk_alloc` on the Medaka side of the call —
  never handed back as a raw `double*` the C side allocated (§2a: "any extern
  that *returns* a Medaka value must allocate it in the GC heap with the
  correct object header"). Ownership: Medaka allocates, Medaka (Boehm) frees.
  C never sees or owns a `Float` cell.

### 2.3 `String`

Native rep: boxed `{i64 header/tag, i64 byte_len, i64 cp_count, bytes…, '\0'}`
(`mdk_str_lit`, `runtime/medaka_rt.c`) — UTF-8 bytes, NUL-terminated for C
interop convenience, but the NUL is not the source of truth for length
(`byte_len` is).

- **Medaka → C:** **copy at the boundary.** The C function receives a `const
  char*` pointing at the cell's inline byte payload (valid for the duration of
  the call — see §2.5) *or*, if the C signature wants an owned buffer, an
  explicit byte-for-byte copy into a `malloc`'d buffer the C side then owns.
  v1 commits to the **borrowed-pointer-for-the-call-duration** form as the
  default (no copy, no allocation) precisely because it's cheaper and the
  common case (`printf`-shaped calls) never needs to keep the string past the
  call. A C function that needs to **retain** the string past return **must**
  request the copying form explicitly (out of scope for the ABI-copy-or-not
  decision itself, but the rule is: retention without a copy is undefined,
  §2.5) — Boehm registers no root for a pointer C code merely stashes.
- **C → Medaka:** a `const char*` (+ length, since Medaka strings are not
  NUL-length-defined) returned/out-param'd from C is **copied** into a fresh
  Medaka String cell via `mdk_alloc_atomic` + `memcpy`, mirroring exactly what
  `mdk_str_lit` already does for string literals. Medaka never takes ownership
  of a C-allocated buffer directly (no "adopt this `malloc` pointer as a
  String cell" path exists or is planned) — the copy is mandatory, not an
  optimization to skip later. If the C side `malloc`'d the source buffer, the
  **C side remains responsible for freeing it**; Medaka's copy is independent.

### 2.4 `Array Int`

Native rep: boxed `{header, len, Int elements…}`, all-immediate elements (per
§1, only `Array Int` is in the v1 crossable set — an `Array` of anything
boxed, e.g. `Array String`, is out of scope until v1's successor, since each
element would need its own crossing rule).

- **Medaka → C:** **copy at the boundary**, by the same reasoning as `String`
  §2.3 — a raw pointer to the cell's element words is only guaranteed live for
  the call's duration (§2.5); if the C signature is a flat `int64_t*` (or
  `int32_t*`, requiring a narrowing copy) the calling convention copies
  `len` words out before the call, never hands the live GC pointer to a C
  function that might store it.
- **C → Medaka:** a C-side `int64_t*` + length is copied into a fresh
  `{header, len, elements…}` cell via `mdk_alloc` (mirrors `mdk_alloc(8 * (n +
  1))` sites already in `runtime/medaka_rt.c`, e.g. array-construction
  helpers). Same rule as `String`: Medaka never adopts a C-allocated buffer as
  its own cell; the copy is mandatory. Freeing the C-side source buffer, if
  heap-allocated, is the C side's responsibility.

### 2.5 The load-bearing distinction: valid-for-the-call vs. valid-after-return

Per `RUNTIME-DESIGN.md` §9 (Boehm, non-moving, conservative stack scanning, no
rooting/handle API): a raw pointer into a `String`/`Array Int` cell handed to a
C function **stays valid for that synchronous call** — Boehm won't move or
collect it while it's referenced from the live Medaka stack frame making the
call. But **nothing in the runtime tracks a pointer a C function stores past
the call's return** — there is no root-registration API for a C-side global,
struct field, or heap slot to keep a Medaka cell alive once the call returns
and the Medaka stack frame that referenced it is gone. A C function that
squirrels away the borrowed pointer for later use is holding a dangling
reference the moment Boehm's next collection runs and finds no live root.
This is exactly why §2.3/§2.4 above default to copy-out on the C→Medaka
direction and treat Medaka→C as borrow-for-the-call-only: **v1 has no
mechanism for a foreign call to retain a Medaka-owned pointer across its own
return.**

## 3. Not crossable in v1 — and why, in ABI terms

- **`Tuple`** — boxed with no length/type-tag encoded in the cell itself (the
  arity is a compile-time-only fact per §8.1); a C signature has no generic
  way to describe an anonymous fixed-arity heterogeneous struct without the
  compiler emitting a bespoke C struct definition per tuple shape used at an
  FFI site — no such codegen exists.
- **`List`** (cons cells) — a linked structure of individually GC-allocated
  boxed cells chained by pointer; a C function would need to walk Medaka's
  internal cons representation (or the compiler would need to flatten it,
  which is exactly what `Array` already is) to consume it at all. No
  flattening/marshaling codegen exists for it in v1.
- **`Array` of a boxed element type** (e.g. `Array String`, `Array (Array
  Int)`) — each element is itself a heap pointer needing its own
  crossing/copy rule (§2.5's dangling-pointer hazard applies per-element, not
  just to the outer array cell); v1 only specifies the all-immediate-element
  case (`Array Int`).
- **ADT / `Record`** — the cell layout (ctor ordinal + fields, or field order)
  is a compiler-internal encoding with no stable, documented binary layout a
  C caller could target; there is also no way to express "which ADT" in a C
  signature.
- **`Ref`** — a boxed mutable cell; crossing it would either (a) hand a raw
  GC pointer to C for read/write, which reintroduces §2.5's retention hazard
  in its most dangerous form (a C-visible *mutable* alias into the Boehm
  heap with no synchronization or lifetime contract), or (b) require a
  copy-in/copy-out convention that defeats the point of a `Ref`. Neither is
  designed.
- **Closures / functions** — a closure cell carries a code pointer *and* a
  GC-managed captured-environment pointer (§8.5: `{header, code_ptr,
  captured…}`). The environment pointer has no C-side representation at all
  — a C function receiving it could not call back into it without also
  understanding Medaka's calling convention (`tailcc`/musttail marshaling,
  §8.5) and closure layout, neither of which is a stable, externally
  documented ABI. Passing a closure across FFI is undefined in v1.
- **Thunks (`VThunk`)** — a laziness cell is a compiler/runtime-internal
  memoization detail with no defined forced-vs-unforced semantics a C caller
  could safely observe; forcing one requires re-entering the Medaka
  evaluator, which a plain C-ABI call cannot do.

## 4. The failure convention

No Medaka error type crosses back over a C ABI call — a C function signature
has no channel for a Medaka `Result`/exception value, and C has no exception
mechanism compatible with Medaka's (`RUNTIME-DESIGN.md` §4 already treats
`panic`/`exit` as `noreturn`, never a value returned to a caller).

**v1 convention: a foreign call cannot fail into Medaka.** The C function
signature admitted at an FFI call site must itself be total from Medaka's
point of view — any failure the C side needs to signal is encoded in its
**return value** (a sentinel, an out-parameter status code, etc. — the C
function's own problem to define, not the ABI's), never as a thrown/raised
Medaka error. If a foreign call needs to signal "this can fail," the Medaka
signature at the call site must say so via an ordinary return type (e.g.
returning an `Int` status code, or a `Bool`), not via effect-system error
machinery threading back across the boundary. A C function that itself
crashes (segfault, abort) is outside any contract this document can make —
that is native undefined behavior, not a Medaka-level failure this ABI is
responsible for converting into anything.

## 5. See also

- `compiler/RUNTIME-DESIGN.md` §8 — native value representation (immediates
  vs. boxed heap aggregates), the source of every ownership answer above.
- `compiler/RUNTIME-DESIGN.md` §9 — Boehm GC strategy (conservative stack
  scanning, no rooting API), the source of §2.5's valid-for-the-call rule.
- #2071 — `<FFI>` effect label (Prefix domain); the effect-tracking half of
  the FFI story, orthogonal to this doc's value-crossing half.
- #2074 — the lowering (`emitFfiCall` and friends) that implements this
  contract; out of scope here, next sprint.
