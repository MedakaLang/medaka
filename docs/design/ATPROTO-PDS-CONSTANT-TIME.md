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

Field `canonicalize` has exactly four direct producer classes:

- `feFromBytesReduce`: a 256-bit byte value;
- `feAdd`: ten non-negative limbs below `2^27`;
- `feNegate`: a representation of `p - a`, at most `p`;
- `feMul`: the carried/folded schoolbook result, with every raw limb below
  `2^43` (the module's conservative producer contract).

`feSub`, `feSquare`, and `feInverse` reach those producers transitively. No
caller-supplied raw limb array may reach `canonicalize`.

The scalar is eight limbs of 32 bits, libsecp256k1's `scalar_8x32` layout. It
has two private reduction entry points. `reduce512` takes sixteen limbs, each
below `2^32`, and has exactly one direct producer:

- `scMul`, the product of two canonical scalars, below `n^2 < 2^512`.

`subNSelect` takes eight limbs, each below `2^32`, and a carry bit that stands
for `2^256`, and requires the whole value to be below `2n`. It has exactly
four direct producer classes:

- `reduce512`'s third fold, below `2^256 + 2c < 2n` (§4);
- `scAdd`, the sum of two canonical scalars, below `2n`;
- `scNegate`/`scNegateCt`, `n - a` for a canonical `a`, in `[1, n]`, carry 0;
- the canonical, reducing and fixed-width byte decoders through `reduce256`,
  a 256-bit value, below `2^256 < 2n`, carry 0.

`scSub` and `scInverse` reach them transitively. The `< 2^512` precondition of
`reduce512` and the `< 2n` precondition of `subNSelect` are load-bearing, and
nothing checks them at run time (see §4 and §5); fixed-count reduction does not
widen the accepted domain.

Any new producer or relaxed magnitude bound invalidates this contract until its
maximum pass count and fixnum headroom are re-derived.

## 3. Field schedule: exactly three carry/fold rounds

Replace `reduceCarry`'s value-dependent recursion with exactly three calls to a
round shaped as:

1. run the fixed ten-limb `carryPass`;
2. unconditionally add `overflow * 977` to limb 0 and `overflow * 64` to
   limb 1.

The third round's overflow is required to be zero by proof, not checked by a
secret-derived branch.

Why three rounds suffice under the conservative producer contract: each limb is
below `2^43`. Let `M = 2^256` and `c = 2^32 + 977`. Carry entering limb 9
means the first pass can return at most `H0 = 2^21`. After its fold, the total
value is `V1 = L0 + H0*c`, where `L0 < M`, hence `V1 < M + 2^54` and the
second carry overflow is at most 1. If that overflow is zero, the second folded
value is already below `M`. If it is one, its remainder is below `2^54`, so the
second folded value is below `2^54 + c < M`. The third carry pass therefore
returns zero. All three rounds execute even for already canonical input.

The implementation must retain the module's non-negative intermediates and
existing `2^62 - 1` ceiling argument, which bounds every stored limb (§5.1).
A `3 -> 2` mutation must be rejected by
the permanent pass-count control and by the conservative-bound witness with
limbs 0 through 8 equal to `2^26 - 1` and limb 9 equal to `2^43 - 1`. That
witness is private test access to the reduction precondition, not a fabricated
public `Fe`.

## 4. Scalar schedule: exactly three folds, then one subtract-and-select

`reduce512` is straight-line: exactly three unconditional folds, then
`subNSelect` (§5), the same shape as libsecp256k1's `scalar_8x32`
`reduce_512` (512 -> 385 -> 258 -> 256 bits, then a final overflow reduce).
Each fold replaces `V = H*2^256 + L` by `H*c + L`, where `c = 2^256 - n`.
Because `2^256 = c (mod n)` the fold preserves the value mod `n`. It is a
fixed set of column sums whose width depends only on the fold, never on the
value, and it runs in full when `H` is zero: that fold adds zero.

`c` is `0x14551231950b75fc4402da1732fc9bebf`, five limbs with a top limb of 1,
and `2^128 < c < 2^128.35`, so `c^2 < 1.62 * 2^256` and `4c < 2^131`. For
every sixteen-limb workspace `W < 2^512`, which contains every admitted
product (`n^2 < 2^512`):

1. **Fold 1** (13 output limbs): `m = W_low + W_high*c <= (2^256 - 1)(c + 1)
   < 2^385`. Its high part `m >> 256` is at most `c`, and its top limb `m12`
   is at most 1.
2. **Fold 2** (9 output limbs): `p = m_low + (m >> 256)*c <= 2^256 - 1 + c^2
   < 2^257.39`. Its high part `p8 = p >> 256` is at most 2.
3. **Fold 3** (8 output limbs and a carry): `r = p_low + p8*c <= 2^256 - 1 +
   2c`. The carry out of the eighth limb, `kd7 = r >> 256`, is 0 or 1.
4. **Subtract-and-select** with that carry: the value `kd7*2^256 + R` (`R` the
   eight limbs) is below `2^256 + 2c`, and `2^256 + 2c < 2^257 - 2c = 2n`
   because `4c < 2^256`. That is `subNSelect`'s precondition, so the result is
   the canonical value mod `n` (§5).

Three folds is the minimum for this domain, and both halves of the final
step are needed:

- after two folds `p8` can be 2, so the value can be at least `2^257 > 2n`,
  which no single subtraction of `n` repairs. The `3 -> 2`
  mutation replaces fold 3's high part `p8` by zero (the fold then adds
  nothing, exactly as if it were absent) and must be rejected by a committed
  workspace whose `p8` is 2;
- `kd7` is 1 only when `p8 >= 1` and `p_low >= 2^256 - p8*c`, with a
  probability near `2^-128` for a product of random scalars, so no random
  test reaches it. A committed workspace with `kd7 = 1` must reject the
  mutation that drops `kd7` from the selection bit. When `kd7` is 1, `R`
  is below `2c < n`, so the subtraction borrows and its difference
  `R - n + 2^256` is the value minus `n`;
- a committed workspace whose three-fold result lies in `[n, 2^256)` with
  `kd7 = 0` exercises the subtraction itself, which a random product also
  reaches with probability near `2^-128`.

The gate's witnesses are private test access to the reduction precondition,
not fabricated public `Sc` values. Each is graded against the same value
computed by Horner's rule over its sixteen limbs through `scAdd` alone, a
path with no fold.

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

For field limbs 0 through 8, `WIDTH = 26`; for the field top limb,
`WIDTH = 22`. For scalar limbs, `WIDTH = 32`. The helper always visits all 10
or 8 limbs and always performs the blend. It may recurse only on the public
limb index; the scalar's `subNSelect` is straight-line, one expression per
limb.

The scalar's input carries one more bit, a carry that stands for `2^256`
(§2, §4), so its selection bit is `keepDiff = carry OR (1 - borrow)`, computed
with `bitOr`. When the carry is 1 the low limbs are below `n`, the subtraction
borrows, and the kept difference is the value minus `n`; the two terms of the
`OR` are then never both 1.

The formula intentionally avoids negative masks and comparison booleans.
Field `t` stays below `2^27` (below `2^23` at the top limb), scalar `t` stays
below `2^33`, and the blend remains within one limb. `diff[i] - original`
wraps modulo 2^64 when negative, and multiplied by `keepDiff` and added back
it gives the exact limb.

An implementation using `if gte...`, an early-return compare, a branch on
`d < 0`, or `hashBool`/another Bool-to-Int conversion does not satisfy this
contract. Native `if` lowers to an LLVM branch and Wasm `if` remains a Wasm
control instruction; neither is a constant-time select guarantee.

### 5.1 The limb carrier, narrowing, and shift amounts

Limbs, columns and carries are stored as non-negative `Int`s, in `Array Int`.
Every arithmetic step on them is one `U64` expression: its operands widen
through `U64.truncate`, the expression computes modulo 2^64, and its result
narrows through `U64.toIntTruncating` before it is stored or bound. `U64`
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
   `pds/test/constant_time_reductions.sh` checks that in the emitted IR. The
   byte codecs shift by a public bit counter, which calls the `u64` wrapper;
   its branches test only that counter.

A `U64` stored in an array, a tuple, a list or a record is a boxed cell
(`docs/design/INTEGER-TYPES-DESIGN.md` §6.2), which is why limbs are stored as
`Int`. Under the N5 emitter a `U64` bound by `let` stays a register, and so do
the `U64` parameters and result of an annotated single-clause top-level
function; the scalar passes limbs between its helpers that way. The
reductions gate pins every audited helper's cell allocation count at 0.

**The scalar on 8 x 32.** Every scalar helper on a secret path is
straight-line: each limb widens once through `U64.truncate` into a `let`, every
step is `U64` `+ - *` and bit operations with literal shift amounts, and each
result limb narrows once through `U64.toIntTruncating` into one array literal.
There is no loop, no recursion and no index other than a literal. A 32 x 32
product fits in 64 bits, so it is plain `U64` `*`; no 128-bit product
(`U64.mulWide`) is needed. Column sums accumulate in one `U64`, not a
`(hi, lo)` pair: each product is split into its low and high 32-bit halves,
the low halves and the incoming carry sum into the column, and the outgoing
carry is that sum shifted down 32 plus the high halves. Every carry is
therefore a shift, never a comparison, and no sum comes near `2^64`:

| Quantity | Bound | Margin |
|---|---|---|
| Stored limb | `< 2^32` | 30 bits below the `2^62` narrowing ceiling |
| Product `a_i * b_j` | `<= (2^32 - 1)^2 < 2^64` | exact; the one full-width value, never narrowed |
| `scMul` column sum (columns 7 and 8) | `< 15 * 2^32 < 2^35.91` | 28 bits below `2^64` |
| `scMul` carry | `< 2^35` | 29 bits |
| Fold product `w_i * c_j` | `< 2^62.34` | 1.6 bits; never summed whole |
| Fold 1 column sum (column 5) | `< 2^34.82` | 29 bits |
| Fold 2 column sum (column 4) | `< 2^34.64` | 29 bits |
| Fold 3 column sum (`p8 * c_j` added whole) | `< 2^32.97` | 31 bits |
| `scAdd` limb sum, subtract-and-select `t` | `< 2^33` | 31 bits |

These are interval bounds, every input limb at `2^32 - 1` and every carry at
its maximum, so they hold whatever the value; §4's value bounds are needed
only for the fold count and the final selection. The only values narrowed to
`Int` are result limbs, below `2^32`, and condition bits, 0 or 1, so every
stored value is exact and far below `2^62`.

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
landing that field `3 -> 2` and scalar `3 -> 2` mutations make the focused
regression red. A pass-count grep alone is insufficient because it could
protect a needlessly large or semantically unused number. The scalar also
needs a committed workspace whose third fold carries out, which must make the
mutation that drops that carry from the selection bit red (§4).

### 6.3 Structural anti-rot gate

Add a registered POSIX-shell PDS gate scoped to the dedicated reduction
helpers. It must:

- require the exact field-three and scalar-three schedules;
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
