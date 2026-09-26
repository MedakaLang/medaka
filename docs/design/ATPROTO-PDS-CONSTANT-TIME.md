# atproto PDS field/scalar constant-time reduction contract

**Status:** implemented and landed for #1724. The successor whole-signing
contract is [`ATPROTO-PDS-SIGNING-CONTRACT.md`](ATPROTO-PDS-SIGNING-CONTRACT.md).

This document specifies the smallest complete landing that closes the three
reduction leaks named by #1724. It is subordinate to P15 in
`ATPROTO-PDS-DESIGN.md`: secret-bearing signing does not ship until this
contract is implemented and verified.

The landing is deliberately indivisible. A fixed fold count with a branchy
final subtraction, or a branchless subtraction above a value-dependent fold
loop, still leaks. Neither subset may land or be described as constant-time.

## 1. Property and boundary

For every admitted input to the private reduction paths in
`pds/lib/field.mdk` and `pds/lib/scalar.mdk`, the native executable used to
deploy a PDS must have:

- an input-independent number of carry, fold, subtraction, selection, and
  allocation steps;
- no branch, early return, recursion exit, or array index selected by a limb;
- no comparison-to-`Bool` converted to an `Int` through `if`;
- the same canonical output as the current implementation.

Loop and recursion conditions may depend on public counters and fixed array
lengths. Bounds checks on fixed-length arrays at public indices are therefore
inside the property. Malformed-input rejection remains outside it: lengths and
the fact of canonical-wire rejection are public API outcomes.

Native is the security boundary because it is the PDS deployment engine. Eval
and Wasm remain required value-parity arms, but this contract does not claim
constant-time execution for them. Wasm's ordinary `Int` carrier selects between
`i31ref` and boxed `i64` representations according to the value; boxing can
branch and allocate below any PDS helper. The limb arithmetic is `U64`
(§5.1), whose Wasm carrier is equally outside this claim. A Wasm constant-time claim therefore
requires a separately accepted uniform integer/crypto carrier or backend
representation design. It cannot be established by scanning the PDS helper,
and the absence of host entropy already independently prevents Wasm key
generation. This engine boundary must not be widened by inference.

This contract covers the reduction paths named by #1724. It does **not** by
itself certify every exported field/scalar helper or the future signing module.
Before P15's signing acceptance cell can be claimed, the signing slice must
census its secret-bearing call graph and either remove or justify the remaining
value-dependent helpers, including field/scalar equality and zero tests,
`scIsHigh`, and both modules' general negation paths. In particular, closing
#1724 must not be reported as proof that an unwritten signing implementation is
constant-time.

## 2. Admitted producers

The fixed counts below are valid only because the modules keep their existing
opaque canonical types and producer bounds.

Field `canonicalizeLimbs` (and `canonicalize`, which reads a five-limb array
into it) has exactly four direct producer classes:

- `feFromBytesReduce` and `feFromBytes`: a 256-bit byte value, limbs 0
  through 3 below `2^52` and limb 4 below `2^48`;
- `feAdd`: five limb sums, limbs 0 through 3 below `2^53` and limb 4 below
  `2^49`;
- `feNegate`: `2p - a` limb by limb, within the same bounds as `feAdd`;
- `feMul`: the port of `secp256k1_fe_mul_inner`, limbs 0 through 3 below
  `2^52` and limb 4 below `2^48 + 2^34` (§3.1).

Its admitted precondition is therefore limbs 0 through 3 below `2^53` and
limb 4 below `2^49`. `feSub`, `feSquare`, and `feInverse` reach those
producers transitively. No caller-supplied raw limb array may reach
`canonicalizeLimbs`.

Scalar `reduceWide` has exactly five direct producer classes:

- canonical and reducing byte decoders;
- `scAdd`, below `2n < 2^257`;
- `scNegate`, at most `n`;
- `scMul`, below `n^2 < 2^512`.

`scSub` and `scInverse` reach them transitively. The existing `< 2^512`
workspace precondition remains load-bearing, and on this path nothing checks it
at run time (see §4); fixed-count reduction does not widen the accepted domain.

Any new producer or relaxed magnitude bound invalidates this contract until its
maximum pass count and fixnum headroom are re-derived.

## 3. Field schedule: exactly one fold/carry round

The field is five limbs in base `2^52`, the layout of `libsecp256k1`'s
`field_5x52_impl.h`: limbs 0 through 3 hold 52 bits and limb 4 holds 48.
`canonicalizeLimbs` runs exactly one round, straight-line on registers, and
then the subtract-and-select of §5:

1. take `x = t4 >> 48` and keep the low 48 bits of limb 4;
2. unconditionally add `x * (2^32 + 977)` to limb 0, since
   `2^256 = 2^32 + 977 (mod p)`;
3. carry limbs 0 through 3 down to 52 bits, the last carry into limb 4.

This is the first pass of the reference's `secp256k1_fe_normalize`. Its second
pass, a fold of `(overflow | value >= p)`, is what the subtract-and-select
does here.

Why one round suffices under the precondition of §2: limb 4 is below `2^49`,
so `x <= 1` and limb 0 is below `2^53 + 2^33` after the fold. Every carry is
then at most 2. After the round limbs 0 through 3 are below `2^52`, limb 4 is
at most `2^48 + 1`, and the value is below `2^256 + 2^209`, which is below
`2p`. That is exactly what §5 needs: each limb's `t` fits its width plus one
bit (limb 4's `t` is at most `2^48 + 2`), and a value `V < 2p` leaves
`V - p < p` after one subtraction whenever `V >= p`. The round's registers
stay below `2^54`, far from `U64`'s `2^64`.

Why one round is needed: the subtract-and-select reads each limb at its width,
and a limb at or above `2^52` makes that limb's `t` reach `2^53`, whose shift
gives a borrow of `-1` and a wrong result. Real producers make such limbs:
`feAdd (p - 1) (p - 1)` has limbs 1 through 3 equal to `2^53 - 2`. There is
no zero-round schedule.

The round runs even for canonical input, and nothing tests its overflow. A
`1 -> 0` mutation, in which `canonicalizeLimbs` hands its arguments straight to
`subPSelect`, must be rejected by the permanent schedule control and by the
conservative-bound witness with limbs 0 through 3 equal to `2^53 - 1` and
limb 4 equal to `2^49 - 1`, checked against its canonical value
`0x100000000000010000000000001000000000000100002000007a1`. That witness is
private test access to the reduction precondition, not a fabricated public
`Fe`.

### 3.1 Field multiplication headroom

`feMul` is a straight-line port of `secp256k1_fe_mul_inner` from
`field_5x52_int128_impl.h`: the same products in the same order into two
128-bit accumulators, `c` and `d`, each held as a `(hi, lo)` pair of `U64`
registers (§5.1). The reference proves its bounds for inputs up to magnitude
8, where its `VERIFY_BITS_128` assertions reach 116 bits. This module's
operands are always canonical, so its bounds are derived here for those
inputs instead:

| Value | Limbs 0–3 | Limb 4 |
|---|---|---|
| a canonical `Fe`, every operand | `< 2^52` | `< 2^48` |
| `feAdd` and `feNegate` sums, before reduction | `< 2^53` | `< 2^49` |
| `feMul` result, before reduction | `< 2^52` | `< 2^48 + 2^34` |
| after the fold/carry round | `< 2^52` | `<= 2^48 + 1` |

A partial product of two canonical limbs is below `2^104`, `2^100` when one
factor is limb 4, and `2^96` for `a[4] * b[4]`. With `pk` for the sum of the
products `a[i] * b[k - i]`, the accumulators peak at:

| Step (the reference's order) | Bound |
|---|---|
| `d = p3` | `< 2^106.00` |
| `d += R * low64(p8)` | `< 2^106.03`, the peak |
| `d >>= 52; d += p4 + (R << 12) * (p8 >> 64)` | `< 2^105.65` |
| `d += p5` | `< 2^105.09` |
| `c = p0 + u0 * (R >> 4)` | `< 2^104.01` |
| `c += p1 + R * low52(d)` | `< 2^105.01` |
| `d += p6` | `< 2^104.17` |
| `c += p2 + R * low64(d)` | `< 2^105.62` |
| `c += (R << 12) * (d >> 64) + t3` | `< 2^85.01` |

The peak leaves 21.97 bits under `2^128`, so a pair never overflows: the high
word stays below `2^42.03`, `hi + h + carry` never wraps, and the low word
wraps by design, with the lost bit recovered as the carry (§5.1).

The fold constant is `R = 0x1000003D10 = 2^260 mod p`: `2^256 = 2^32 + 977
(mod p)`, and `R` is 16 times that, itself below `p`, so it is the residue.
A limb position `k` has weight `2^(52k)`, so a quantity at position `k + 5`
has weight `2^260 * 2^(52k)` and folds to `R` times position `k`. `feMul`
uses it three ways. `R` folds the low bits of a column into the position five
below it: the low 64 bits of `p8` and of `p7`, and the low 52 of the
accumulator holding `p6`. `R << 12` folds a column's high word, whose
weight is `2^64` above its column, which is `2^12` above the next position
up. `R >> 4 = 2^256 mod p` folds the 56-bit `u0`, which the reference aligns
to weight `2^256`. `canonicalizeLimbs` folds limb 4's bits above 48, also at
weight `2^256`, with `R >> 4`.

Nothing above is stored. The accumulators, carries and fold products live in
registers from the first product to the reduction, and only the five result
limbs are narrowed to `Int` and stored, each below `2^52`, 10 bits under the
`2^62` ceiling of an exact narrowing (§5.1). The only arrays that ever hold a
non-canonical limb are the byte decoder's exact 256-bit limbs (below `2^52`)
and the reductions gate's private witnesses (below `2^53`).

At a higher operand magnitude every product bound grows by twice the
magnitude's logarithm, still inside a pair up to the reference's magnitude 8.
The result would then still meet `canonicalizeLimbs`'s precondition, but
nothing in this module relies on that slack: only canonical values ever reach
`feMul`, and nothing checks that at run time.

## 4. Scalar schedule: exactly four fold/carry rounds

Replace `reduceLoop` and `highIsZero` with:

1. one fixed 32-limb `carryAllUnchecked`;
2. exactly four unconditional `foldOnce` plus `carryAllUnchecked` rounds.

`carryAllUnchecked` drops a carry out of limb 31 without testing it: every
admitted workspace is below `2^512`, so that carry is always zero, and its only
branch is the public limb index. `carryAll` is the checked twin, which panics
on such a carry; the reduction gate runs the two side by side.

`foldOnce` must reuse a fixed allocation schedule. It may allocate its current
16-limb high-half buffer once per round because four allocations are
input-independent; allocating it once outside the schedule is also valid. It
must never skip a round because the high half is zero.

Let `c = 2^256 - n`, so `c + 1 < 2^129`. For any admitted `V < 2^512`, one
fold maps `V = H*2^256 + L` to `H*c + L`:

- after fold 1, the value is below `2^385`;
- after fold 2, it is below `2^258`, so the high half is at most 3;
- after fold 3, it is below `2^256 + 3c`, so its high half is at most 1;
- before fold 4, if the high half is 0 the value is already below `2^256` and
  the unconditional zero fold preserves it; if the high half is 1, its low
  half is below `3c`, so fold 4 produces less than `4c < 2^131 < 2^256`.

Four rounds therefore clear the high half for the whole admitted domain. A
three-round mutation must be rejected by the permanent pass-count control and
by an adversarial value witness.

## 5. Unconditional subtract-and-select

Both modules must replace their early-exit magnitude comparison, conditional
subtraction, and per-limb borrow branch with one fixed-width helper. For base
`B = 2^WIDTH`, each limb computes only non-negative bounded values:

```text
t       = original[i] + B - modulus[i] - borrow
diff[i] = bitAnd t (B - 1)
borrow  = 1 - shiftRight t WIDTH
```

After the final limb, `keepDiff = 1 - borrow`: it is 1 exactly when the
unconditional subtraction did not borrow. Blend every output limb without a
branch:

```text
out[i] = original[i] + keepDiff * (diff[i] - original[i])
```

For field limbs 0 through 3, `WIDTH = 52`; for the field top limb (4),
`WIDTH = 48`. For scalar limbs, `WIDTH = 16`. The helper always visits all 5
or 16 limbs and always performs the blend. It is straight-line or recurses
only on the public limb index.

The formula intentionally avoids negative masks and comparison booleans.
Field `t` stays below `2^53` (below `2^49` at the top limb), scalar `t` stays
below `2^17`, and the blend remains within one limb. `diff[i] - original`
wraps modulo 2^64 when negative, and multiplied by `keepDiff` and added back
it gives the exact limb.

An implementation using `if gte...`, an early-return compare, a branch on
`d < 0`, or `hashBool`/another Bool-to-Int conversion does not satisfy this
contract. Native `if` lowers to an LLVM branch and Wasm `if` remains a Wasm
control instruction; neither is a constant-time select guarantee.

### 5.1 The limb carrier, narrowing, and shift amounts

Limbs are stored as non-negative `Int`s, in `Array Int`. Arithmetic on them
is `U64`: operands widen through `U64.truncate`, every step computes modulo
2^64, and a result narrows through `U64.toIntTruncating` before it is stored.
`U64`
`+`, `-` and `*` wrap and have no branch; with a literal shift amount, the
conversions, the bit operations and the shifts are inline kernels fused with
that arithmetic, so the whole expression is straight-line code that neither
calls nor allocates. `Int` traps on overflow (#3377): an `Int` `+`, `-` or
`*` is the operation plus a branch on the overflow flag, and on a secret
operand that is a secret-dependent jump even where the headroom proofs above
show it is never taken. So no secret value meets `Int` arithmetic; the only
`Int` `+ - *` on these paths is on public counters and indexes, which
`pds/test/constant_time_reductions.sh` proves operand by operand in the
emitted IR. The narrowing keeps 63 bits and is exact below `2^62`; the proofs
in §3 through §5 bound every stored value below that, and inside one
expression an intermediate may exceed it or wrap (as `diff[i] - original`
does) with the narrowed result still exact.

Secret condition bits are `Int` 0 or 1 and combine only through `bitAnd`,
`bitOr` and `bitXor` (`bitXor b 1` for `1 - b`), which cannot overflow and
do not branch. The `*Bit` predicates cross the module boundary this way, and
`pds/lib/secp256k1.mdk` combines them the same way.

Two rules follow, and hold for every secret-bearing value in `pds/`:

1. A secret-derived value narrows only through a masking conversion:
   `u64.toIntTruncating`, `u64.truncate`, or a narrower type's `truncateU64`
   (`u8.truncateU64`). The checked doors, `fromInt`, `tryFromInt` and
   `toInt`, test their argument and are
   therefore branches; they never take a secret-derived operand. A byte held
   as an `Int` enters `U64` through the masking `U64.truncate`; a `U8`
   through the total `U64.fromU8`.
2. A shift amount is never secret-derived. `U64.shiftLeft` and
   `U64.shiftRight` give 0 for an amount of 64 or more through a select, and
   panic on a negative amount through a branch on the amount; with a public
   amount both are fixed. Every shift in the reduction helpers passes a
   literal, so none of them is a call, and
   `pds/test/constant_time_reductions.sh` checks that in the emitted IR. A
   byte codec that shifts by a public bit counter calls the `u64` wrapper,
   whose branches test only that counter; the field's codecs shift by
   literals.

A `U64` stored in an array, a tuple, a list or a record is a boxed cell
(`docs/design/INTEGER-TYPES-DESIGN.md` §6.2). The native backend keeps a
`U64` `let` in a register unless it would be boxed more than once in its
scope, and an annotated single-clause top-level function passes its `U64`
parameters and result raw. A `U64` named inside an array literal is boxed, so
a result limb is narrowed into an `Int` `let` before the literal that stores
it. The reductions gate pins every audited helper's cell allocation count at
0.

The field (§3.1) computes on registers throughout. Each operation reads a limb
once through `U64.truncate` and binds its intermediates as `U64` lets, and
only the result limbs are narrowed. A 104-bit product is
`let (hi, lo) = U64.mulWide x y`, which the native backend inlines as a
multiply and a high multiply into two registers, with no tuple. A 128-bit
accumulator is such a pair, and adding a product to it is
`lo' = lo + l` and `hi' = hi + h + carryOut lo l lo'`, where `carryOut x y s`
is the top bit of `(x & y) | ((x | y) & ~s)`: no comparison, no branch.
`U64.addCarry` and `U64.subBorrow` are not used, because their carry is a
`Bool` built with `||` and a match, which branch. The field's helpers pass
registers to each other: `canonicalizeLimbs`, `subPSelect`, `carryOut` and
`zeroBitOf` take and return `U64` raw.

## 6. Verification mechanism

The implementation PR must carry all of the following as one review unit.

### 6.1 Value preservation

- `pds/test/field_vectors_test.mdk`: all 944 externally generated field rows
  pass;
- `pds/test/scalar_vectors_test.mdk`: all 1028 externally generated scalar
  rows pass;
- the existing focused in-language PDS arithmetic tests pass;
- both corpora remain byte-identical and retain their provenance ledger rows.

The corpora establish values, not constant-time structure.

### 6.2 Adversarial count witnesses

Add committed inputs that need the last permitted round. Demonstrate before
landing that field `1 -> 0` and scalar `4 -> 3` mutations make the focused
regression red. A pass-count grep alone is insufficient because it could
protect a needlessly large or semantically unused number.

### 6.3 Structural anti-rot gate

Add a registered POSIX-shell PDS gate scoped to the dedicated reduction
helpers. It must:

- require the exact field-one and scalar-four schedules;
- require the unconditional borrow-and-blend helper shape for both moduli;
- reject calls from the reduction entry points to the retired early-exit
  comparison or conditional-subtraction helpers;
- reject secret-derived `if`/comparison inside the helpers;
- carry a non-zero assertion floor.

Mutation controls must prove the gate reds for each reduced pass count and for
replacing arithmetic blending with a conditional selection. Mutations are
transactional and restore the exact source on success, failure, and signal.

### 6.4 Emitted-control check

A small PDS probe must force the reduction helpers through native emission. The
gate must inspect helper-scoped generated control flow, not grep an entire
output file:

- native: the relevant helper bodies contain only the approved arithmetic and
  bit operations and no limb-derived conditional branch;
- native C bit helpers used by the formula and the final linked reducer are
  disassembled for the tested target and checked not to introduce a
  limb-derived conditional jump;
- a conditional-selection mutation must make the emitted-control checker red,
  independently of the source-structure checker.

Eval and Wasm run the same value witnesses and corpora for semantic parity.
They are not emitted constant-time evidence: Wasm's transitive integer boxing
is value-dependent, and eval is not the deployed PDS engine.

Generated IR is evidence about the reviewed compiler/target pair, not a
universal hardware timing proof. The gate must identify its target and compiler
configuration in its receipt.

### 6.5 Operational cost

Record focused native and Wasm timings for field multiplication and scalar
inversion before and after the redesign. These are cost receipts, not acceptance
thresholds and not constant-time proofs. A material regression is reviewed
rather than hidden; it does not license restoring a secret-dependent shortcut.

### 6.6 Empirical timing control

An empirical timing test is supplementary, never the primary proof. If added,
it must compare populations chosen to exercise the old pass/subtract branches,
pin its sampling method and statistical threshold, and demonstrate that the old
implementation or an explicit branch mutation is distinguishable. It must not
be a required shared-runner gate unless its false-positive rate is first shown
acceptable on both supported development platforms.

## 7. Acceptance and reporting

#1724 closes only when sections 3 through 6 land together and the exact-head
review verifies the producer census in section 2 still holds. The landing note
must report:

- the fixed counts and their proofs;
- mutation receipts for both reduced counts and conditional selection;
- exact 944/944 and 1028/1028 corpus grades;
- native emitted-control grade and eval/Wasm value-parity grades;
- focused native/Wasm cost receipts;
- any empirical timing evidence with its limitations;
- an explicit statement that arbitrary-operation/signing constant-time status
  remains governed by P15 and the future secret-bearing call-graph audit.

Only after this contract is accepted, implemented, and #1724 is closed may
#1700 feed a private key, RFC 6979 nonce, or derived secret through these
reduction paths in the native PDS. A Wasm secret-bearing signing deployment
remains blocked on its separately accepted uniform-carrier/backend design.
