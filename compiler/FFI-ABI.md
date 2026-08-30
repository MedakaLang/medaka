# FFI ABI contract

**Status: decision, and now LOWERED.** This document fixes the value-crossing
contract for the C FFI boundary the effect label `<FFI>` (#2071, `Prefix` domain)
already tracks. It answers a narrower question than the whole FFI story: *which
Medaka types may cross at all, and who owns the memory on each side* — so the
lowering had a contract to implement against instead of inventing one arm at a
time.

⚠️ **The lowering exists as of 2026-08-27** (`ffi-lower-and-link`, S-ffi-lowering,
#2074): `emitFfiCall` and friends in `compiler/backend/llvm_emit.mdk` implement §2
below, and `ffiCrossableTy` (`compiler/types/typecheck.mdk`) rejects everything
outside §1 at check time. Gated by `test/diff_compiler_llvm_ffi.sh`. One thing
this doc specifies is still NOT done, deliberately:

* **`Array Int` in RETURN position is refused.** §2.4 says "a C-side `int64_t*`
  PLUS LENGTH is copied", a C-ABI return carries ONE value, so there is no length
  channel and no correct number of words to copy; the emitter reports a loud gap
  naming that hole rather than guessing a length. **The out-parameter shape IS the
  answer, and now genuinely works** — declare the array as a *parameter*, allocate
  it on the Medaka side, and let C fill it in place. ⚠️ That shape's history is
  worth knowing, because this block twice said the opposite: it was recommended
  first, then measured as FALSE by the `ffi-lower-and-link` review round (S1-6) —
  §2.4's outbound copy meant C filled a throwaway buffer and the Medaka array was
  silently unchanged at exit 0 — and this block was then rewritten to name NO
  working shape, which was the honest state while the copy-back was missing.
  §2.4 grew the copy-back in `ffi-boundary-honesty` (S-ffi-array-copyback, #2164),
  so the shape works for real. 🚨 **If the copy-back is ever removed, this bullet
  goes back to naming NO shape — never leave it recommending one that silently
  drops the data ([W-QUIETER]).**
* **Linkage** — landed (S-ffi-linkage, #2075). A `[foreign-libraries]` table in
  `medaka.toml` (`readForeignLibs`/`libLinkFlags`, `compiler/driver/build_cmd.mdk`)
  links a named library by searching its declared directory, falling back to the
  linker's default search path; a missing library is a located
  `B-FFI-LIB-NOT-FOUND` diagnostic naming the library, key, and manifest path —
  not a raw `clang`/`ld` wall. No `[foreign-libraries]` table: the link line is
  byte-identical to a project with none (verified by argv capture, not by
  inspection).

🚨 **The `FFI` label is WRITTEN by the author, never added by the compiler**
(F1, epic #2070, 2026-08-27). A user-declared `extern`'s terminal effect row
must already name `FFI` — `<FFI>`, or `<FFI "libcurl">`, or joined with whatever
else the row names (`<FFI, Net "a.com/*">`) — or the declaration is a located
type error (`T-FFI-UNLABELLED`). Its predecessor STAMPED the atom in when it was
missing, and did so for *every* row shape, not only the empty one: a declared
`<Net "a.com/*">` silently typed as `<FFI, Net "a.com/*">`, so the row in the
source and the row the effect system enforced were two different rows and no
signature could be written honestly and believed. Two populations are exempt,
both by the same test the crossable guard uses: a program the loader owns to
`stdlibRoot` (`stdlib/runtime.mdk`'s catalog IS the effect vocabulary), and a
local redeclaration of a catalog name (`ffiIsBuiltinExternName` — such a name is
lowered as the builtin whatever its local row claims, so the row is not a
foreign-call contract). **That second exemption is bounded by two rules of its
own**: the redeclared signature must match the catalog row's *shape*
(`T-FFI-BUILTIN-SHADOW`, below) and must not *narrow* its effect row
(`T-FFI-CATALOG-NARROW`, below).

⚠️ **The catalog-name exemption requires a SIGNATURE match, not just a name
match** (`T-FFI-BUILTIN-SHADOW`, added by the `ffi-lower-and-link` review round,
S0-3). The name-only exemption was measured on *compatible* redeclarations only
(`bitAnd`, `getEnv`); an incompatible one got the same free pass and the same
builtin codegen, so `extern log : String -> <FFI "mylog"> Unit` compiled to `call
double @mdk_log(double <String cell pointer>)` at exit 0 and the author's own C
`log` was never called. Such a declaration is now a located type error: the
emitter routes a catalog name to the builtin regardless of typecheck's verdict
(`ffiExternRows` subtracts the catalog outright; `emitApp` tests `isAnyExtern`
before the FFI arm), so a shape-incompatible redeclaration is a claim no lowering
can honour in either reading. Comparison is at **type-head granularity** —
argument heads plus return head, effect rows and constraint prefixes walked
through, type variables normalised — the same projection the emitter's FFI index
stores. The compatible-redeclaration idiom the effect-domain fixtures rely on is
untouched.

🚨 **A catalog redeclaration may not NARROW the catalog's effect row**
(`T-FFI-CATALOG-NARROW`, #2163, the `ffi-boundary-honesty` sprint). The
shape rule above walks *through* effect rows on purpose, so `<>` and
`<FileWrite "_">` are one shape to it — which left epic #2070's own R2 escape
hatch open for all 138 catalog names. `extern writeFile : String -> String -> <>
Result Unit String` matched the catalog's heads, passed every rule above, typed
its caller as `String -> Unit`, and the emitter (name-keyed, and never reached by
a typecheck verdict) still lowered the call to the real `writeFile`: `medaka
check` printed `innocent : String -> Unit` at exit 0 for a function that writes
to disk.

The rule is **subsumption, not equality, and not a ban**: the declared row must
COVER the catalog's own row, and may be wider. A wider row over-declares what the
caller must permit, which is the safe direction — so `extern putStrLn : String ->
<IO> Unit` stays legal against the catalog's narrower `<Stdout>` (the bound's
`IO` is widened to its security-label alias before the comparison, exactly as an
`<IO>`-bounded body row is). The compatible- and wider-redeclaration idioms the
fixture corpora rely on are untouched; only the *narrowing* case is refused, and
the ~100 catalog rows that write no effect row at all (`bitAnd`, `arrayBlit`, the
math family) are silent under it by construction, since the empty row is covered
by everything.

⚠️ **A NULLARY `extern k : Int` is rejected** (`T-FFI-NULLARY`, same review round,
S0-2). An effect row lives on an arrow's result, so a signature with no arrow has
nowhere to write `FFI` — but the emitter lowered such a name as a foreign call
anyway (`emitVar`'s `isFfiExtern` arm → `emitFfiEtaClosure`), handing back an eta
closure pointer where the declared value was expected: garbage at exit 0, where
before the #2074 lowering the same program died loudly with `unbound variable`.
Write `extern k : Unit -> <FFI> T` and call it as `k ()`. **This CLOSES #2106**,
which asked how a nullary extern *would* spell its label: it does not, and it
need not. The `ffi-boundary-honesty` sprint measured the alias-wrapped spellings
the rule was thought to miss — `type A = Int; extern k : A` and `type A a = Sh a
=> Int; extern k : A Int` — and both produce the byte-identical `T-FFI-NULLARY`
diagnostic the plain `extern k : Int` spelling gets, because `expandAliasHeadTy`
unwraps either alias shape to a bare `TyCon` before the label rule ever matches.
An effect row lives on an arrow's result, so a nullary foreign declaration is
refused rather than labelled, and the arrow spelling is the whole answer.

🚨 **The `mdk_` prefix is reserved** (`T-FFI-RESERVED-NAME`, same review round,
S0-4). A foreign declaration's name is used verbatim as the C symbol, and `mdk_*`
is the runtime's own C symbol namespace (`runtime/medaka_rt.c`), so `extern
mdk_nil : Unit -> <FFI> Int` linked onto the runtime internal and printed its Nil
constructor word at exit 0. Any user extern whose name starts with `mdk_` is
refused, at any signature and with no catalog-name exemption — a *mismatched*
signature was already loud (clang rejects the conflicting `declare`); the silent
half is the matching one.

🚨 **One C symbol, one signature, program-wide.** Two modules that each declare a
name with *different* type-head shapes is refused at Core IR lowering time (the
`foreign declaration collision` panic in `ffiExternTypeNames`,
`compiler/ir/core_ir_lower.mdk`). The FFI index is bare-name keyed across the
whole program, so before this the first declaration won and the other module's
calls were marshalled through it — a wrong value at exit 0, or a segfault. Two
modules declaring the *same* name with the *same* signature is legitimate sharing
and stays legal.

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
| `Unit` | no representation (§8: zero-width) | yes, trivial |

`Unit` was omitted from the original v1 cut, which made every void-returning C
function — the single most common FFI shape — inexpressible. Added
2026-08-27 (`ffi-lower-and-link`, S-crossable-guard re-cut) by orchestrator/Val
ruling: `Unit` carries no runtime representation, so it crosses trivially in
either position (a `Unit`-typed parameter marshals to nothing; a `Unit` return
means the C function is called for effect only, mapping to a C `void` return)
— see §2.6.

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

#### 2.1a Inbound `Bool` and `Char` are NORMALISED, not merely tagged

The tagging rule above is the whole story for `Int` — every `int64_t` is a valid
`Int`. It is **not** the whole story for `Bool` and `Char`, whose native reps are
**subsets** of the immediate space (§8.1): `False` is exactly the word `1`, `True`
exactly `3`, and a `Char` exactly `cp * 2 + 1` for every `cp` that is a Unicode
**scalar value** — `0 ≤ cp ≤ 1114111` (`charMinBound`/`charMaxBound`) **and**
`cp` outside the UTF-16 surrogate window `0xD800 ≤ cp ≤ 0xDFFF`
(`55296 ≤ cp ≤ 57343`). The bounds alone are **not** the validity predicate: the
surrogate window sits inside them and is nonetheless not a `Char`. The one
authority is the runtime's `mdk_char_from_code` (`runtime/medaka_rt.c`), whose
condition is verbatim `n >= 0 && n <= 0x10FFFF && !(n >= 0xD800 && n <= 0xDFFF)`;
every other `Char`-producing path in the language already agrees with it (the
lexer rejects a surrogate literal outright, and `charFromCode 55296` is `None`).
A C function is under no obligation to stay inside either subset, and this ABI is
the only place that can say what happens when it does not.

**This was a live S1 (#2128), not a hypothetical.** Until 2026-08-28 the inbound
arm re-tagged whatever it got, so `long long cTruthy(void){ return 42; }` behind
`extern cTruthy : Unit -> <FFI "…"> Bool` produced the word `85` — neither `1`
nor `3`. The two constructs that read a `Bool` then **disagreed on the same
runtime value in the same program**: `if` untags and tests `!= 0`, so it took the
`True` branch at exit 0, while `match` compares the immediate word against `3`/`1`
exactly, so it died with `E-NONEXHAUSTIVE-MATCH`. An out-of-range `Char` was worse
still: tagged as if valid, it printed replacement garbage at exit 0.

- **`Bool` — normalised, by C's own rule.** The returned scalar is collapsed to
  the two legal words before anything else sees it: `0` becomes `False`, every
  other bit pattern becomes `True`. That is exactly the truthiness convention
  every C caller already writes to (`return flags & MASK;` is idiomatic, not
  sloppy), so it converts the commonest honest C idiom into the right Medaka
  value rather than rejecting it — and, being one of exactly two words, `if` and
  `match` can no longer disagree about it. `0` and `1` round-trip unchanged, so
  nothing that already worked changes.

- **`Char` — validated, and an out-of-range value TRAPS.** A codepoint has no
  C-side convention to normalise onto the way a bool does, and there is no
  defensible value to substitute: clamping to `charMaxBound`, masking the low
  bits, or substituting U+FFFD would all invent a codepoint the C function never
  returned and hand it onward at exit 0 — which is precisely the silent wrongness
  this rule exists to remove (`AGENTS.md` [W-QUIETER]: making a defect quieter is
  a severity *increase*). So the boundary checks the full validity predicate
  stated above — `0 ≤ r ≤ 1114111` **and** `r` outside `55296..57343` — and aborts
  with a coded runtime error naming the foreign call and the predicate when it
  fails. Three unsigned compares: `ult 1114112` for the bounds (a negative
  `long long` reads as a huge unsigned and fails it at the same time, so the low
  end needs no compare of its own), plus `ult 55296` / `ugt 57343` `or`-ed
  together for the surrogate exclusion. Cost is three compares and a never-taken
  branch on a path that has just made a C call.

  ⚠️ Checking only the *bounds* here would leave the FFI boundary the single door
  in the language through which an invalid `Char` reaches `println` as malformed
  UTF-8 at exit 0. That is not hypothetical — it was the shipped behaviour until
  2026-08-28 (review finding S0-1): `long long cCharSurrogate(void){ return
  0xD800; }` behind `extern cCharSurrogate : Unit -> <FFI> Char` produced an
  invalid `Char` at exit 0.

  **Why this is not a violation of §4.** §4 says a foreign call cannot fail *into*
  Medaka — meaning the C function has no channel for signalling *its own* failure
  as a Medaka error, and must encode that in its return value instead. That
  governs C-side failure signalling. It does not oblige the ABI to accept, and
  pass on, data that C has already got wrong: an abort is not a value threaded
  back to a Medaka caller, it is the same class of event as `E-INDEX-OOB`. The
  alternative reading — "the ABI must always produce *some* `Char`" — is the
  reading that makes `println` print garbage at exit 0.

  A C function that legitimately has "no character" to return should say so in
  its Medaka signature (return an `Int` codepoint the caller validates, or a
  status code), exactly as §4 already directs for every other kind of C-side
  failure.

Gated by cells 7–9 of `test/diff_compiler_llvm_ffi.sh`, against the `cTruthy`/
`cFalsy`/`cOne`/`cCharA`/`cCharBig`/`cCharNeg`/`cCharSurrogate` functions in
`test/ffi_fixtures/ffi_abi_probe.c`; implemented by `ffiNormalizeBool` /
`ffiNormalizeChar` in `compiler/backend/llvm_emit.mdk`.

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
- **C → Medaka:** a returned `const char*` is a NUL-terminated byte sequence; a
  null pointer represents the empty string. Before copying, the boundary
  validates that every byte belongs to a canonical UTF-8 encoding of a Unicode
  scalar value. It rejects stray or bad continuation bytes, truncated and
  overlong encodings, UTF-16 surrogate encodings, and values above U+10FFFF.
  Invalid input aborts with a coded runtime diagnostic rather than creating a
  malformed Medaka `String`; lossy replacement would silently invent a value
  that C did not return. Embedded NUL bytes therefore remain outside this v1
  return convention because there is no separate length channel.

  Valid input is **copied** into a fresh Medaka String cell via
  `mdk_alloc_atomic` + `memcpy`, mirroring exactly what `mdk_str_lit` already
  does for string literals. Medaka never takes ownership of a C-allocated
  buffer directly (no "adopt this `malloc` pointer as a String cell" path exists
  or is planned) — the copy is mandatory, not an optimization to skip later. If
  the C side `malloc`'d the source buffer, the **C side remains responsible for
  freeing it**; Medaka's copy is independent.

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
- **Medaka → C, the COPY-BACK half** (#2164): after the call returns, the
  boundary copies the buffer's `len` words back into the caller's live cell,
  re-tagging each (`(w << 1) | 1`, exactly inverting the outbound `>> 1`). The
  count comes from the LIVE cell, the same `len` the out-copy used — C is given
  no length channel and so cannot have grown the buffer. Without this half, the
  outbound copy alone makes a C function that fills a caller-allocated array a
  silent no-op on the Medaka side.

  🚨 **The copy-back is UNCONDITIONAL — there is no "in" vs "out" parameter
  concept in a Medaka FFI signature, and this section does not introduce one.**
  Every `Array` argument is copied back whether or not C wrote to it; an
  untouched buffer restores the identical words, a correctness no-op. Detecting
  which arguments a C function writes would require knowing its body, which the
  compiler never does.

  Lowering: `mdk_ffi_array_int_out` / `mdk_ffi_array_int_in`
  (`runtime/medaka_rt.c`), emitted by `ffiMarshalOut` / `ffiArrayCopyBack`
  (`compiler/backend/llvm_emit.mdk`). The buffer pointer stays live across the
  call in an ordinary SSA register, which Boehm's conservative stack scan covers
  like any other local referenced after a call — no new rooting mechanism, and
  none of §2.5's retain-past-return hazard, since the copy-back happens before
  the calling frame is gone.
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

### 2.6 `Unit`

`Unit` has no runtime representation at all — not an immediate, not a boxed
cell (§8). There is nothing to tag, untag, allocate, or free.

- **Medaka → C:** a `Unit`-typed parameter marshals to nothing — it does not
  appear in the C call's argument list. (In practice a v1 crossable signature
  with a `Unit` parameter is degenerate; the common shape is `Unit` in RETURN
  position, not argument position.)
- **C → Medaka:** a `Unit`-returning declared extern maps to a C function
  returning `void`; the call is made for effect only, and the Medaka side
  produces the `Unit` value without reading any C return register.

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

⚠️ **This convention is about the C side SIGNALLING failure; it does not license
the ABI to launder malformed data.** §2.1a's `Char` range check aborts when C
returns something that is not a Unicode scalar, and that is not a violation of
the rule above: nothing is threaded back to a Medaka caller as a value, and no
effect-system machinery crosses the boundary. It is the same class of event as
`E-INDEX-OOB` — the alternative, producing *some* `Char` unconditionally, is a
wrong answer at exit 0.

## 5. See also

- `compiler/RUNTIME-DESIGN.md` §8 — native value representation (immediates
  vs. boxed heap aggregates), the source of every ownership answer above.
- `compiler/RUNTIME-DESIGN.md` §9 — Boehm GC strategy (conservative stack
  scanning, no rooting API), the source of §2.5's valid-for-the-call rule.
- #2071 — `<FFI>` effect label (Prefix domain); the effect-tracking half of
  the FFI story, orthogonal to this doc's value-crossing half.
- #2074 — the lowering (`emitFfiCall` and friends) that implements this
  contract; out of scope here, next sprint.
