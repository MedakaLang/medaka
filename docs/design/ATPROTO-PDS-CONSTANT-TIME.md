# atproto PDS field/scalar constant-time reduction contract

**Status:** accepted implementation contract for #1724; implementation complete,
landing pending.

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
branch and allocate below any PDS helper. A Wasm constant-time claim therefore
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

Scalar `reduceWide` has exactly five direct producer classes:

- canonical and reducing byte decoders;
- `scAdd`, below `2n < 2^257`;
- `scNegate`, at most `n`;
- `scMul`, below `n^2 < 2^512`.

`scSub` and `scInverse` reach them transitively. The existing `< 2^512`
workspace precondition and carry-out panic remain load-bearing; fixed-count
reduction does not widen the accepted domain.

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
existing `2^62 - 1` ceiling argument. A `3 -> 2` mutation must be rejected by
the permanent pass-count control and by the conservative-bound witness with
limbs 0 through 8 equal to `2^26 - 1` and limb 9 equal to `2^43 - 1`. That
witness is private test access to the reduction precondition, not a fabricated
public `Fe`.

## 4. Scalar schedule: exactly four fold/carry rounds

Replace `reduceLoop` and `highIsZero` with:

1. one fixed 32-limb `carryAll`;
2. exactly four unconditional `foldOnce` plus `carryAll` rounds.

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

For field limbs 0 through 8, `WIDTH = 26`; for the field top limb,
`WIDTH = 22`. For scalar limbs, `WIDTH = 16`. The helper always visits all 10
or 16 limbs and always performs the blend. It may recurse only on the public
limb index.

The formula intentionally avoids negative masks and comparison booleans.
Field `t` stays below `2^27` (below `2^23` at the top limb), scalar `t` stays
below `2^17`, and the blend remains within one limb. These are within Medaka's
non-negative bit-operation contract and far below its fixnum ceiling.

An implementation using `if gte...`, an early-return compare, a branch on
`d < 0`, or `hashBool`/another Bool-to-Int conversion does not satisfy this
contract. Native `if` lowers to an LLVM branch and Wasm `if` remains a Wasm
control instruction; neither is a constant-time select guarantee.

## 6. Verification mechanism

The implementation PR must carry all of the following as one review unit.

### 6.1 Value preservation

- `pds/test/field_vectors.sh`: all 944 externally generated field rows pass;
- `pds/test/scalar_vectors.sh`: all 1028 externally generated scalar rows
  pass;
- the existing focused in-language PDS arithmetic tests pass;
- both corpora remain byte-identical and retain their provenance ledger rows.

The corpora establish values, not constant-time structure.

### 6.2 Adversarial count witnesses

Add committed inputs that need the last permitted round. Demonstrate before
landing that field `3 -> 2` and scalar `4 -> 3` mutations make the focused
regression red. A pass-count grep alone is insufficient because it could
protect a needlessly large or semantically unused number.

### 6.3 Structural anti-rot gate

Add a registered POSIX-shell PDS gate scoped to the dedicated reduction
helpers. It must:

- require the exact field-three and scalar-four schedules;
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
