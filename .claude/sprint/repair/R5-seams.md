# R5 — seam audit across the five concurrent typecheck.mdk units

Trunk `arch/stage-a-sprint` @ `0b953165`, read-only, no rebuild. Binary verified to carry
the head commit (`strings ./medaka | grep -c T-REQUIRES-UNROUTED` → 1) and
`MEDAKA_STRICT=1` clean on every probe. All probe programs live under
`/var/tmp/medaka-scratch/.../scratchpad/{s1,s2,s3,i1,i2,c1,c2}`.

Predicate reader set, **DERIVED from code** (comments excluded):
`declEnvVisibleAt` → `declEnvVisibleTo`:2981, `ieRowsVisibleAt`:4320, `ceLookupAt`:4759,
`ceRowsVisibleAt`:4782. `ieCandidacyVisibleAt` → `ieSnapAt`:4293 only. No open-coded `<=`.

---

## F1 — LIVE, S1/S2. `checkSuperImpls` contradicts the engine, and import-line order decides it

**Units that disagree:** A-3.5b (`ieRowsVisibleAt` kept on `declEnvVisibleAt`) vs A-3.6
(`ieSnapAt` → `ieCandidacyVisibleAt ≡ True`).
**Ruling status:** RUN-039 and RUN-042 both recorded this as UNRULED/UNOWNED, both RELAYED
from Lane B. **It is now DERIVED, first-hand, with a discriminating pair.**

`s1/`: four modules. `iface` declares `Sup`, `Sub a requires Sup a`, `data W`.
`subimpl` declares `impl Sub W`; `supimpl` declares `impl Sup W`; neither imports the other.
The two entry files differ **only in the order of two import lines**:

| entry | import order | `check` | `run` |
|---|---|---|---|
| `main.mdk` | `subimpl`, then `supimpl` | **exit 1** `subimpl.mdk:4:16: 'impl Sub W' requires a superinterface 'impl Sup W', which is missing` | exit 1, same |
| `control.mdk` | `supimpl`, then `subimpl` | exit 0 | **42** |

That is the #1564 shape on a fresh axis — a legal program accepted or rejected by import
order in a *third* module — and A-3.6 is what made the two channels disagree (before it,
candidacy was a prefix too, so both agreed and the reject was merely a false one).

**The contradiction inside ONE program** (`s2/`, `subimpl.mdk` gains
`useSup w = bump w`, a `Sup W` goal at its own ordinal, still not importing `supimpl`):
exactly ONE diagnostic is emitted — the super-existence one. `useSup` typechecks, i.e.
candidacy **does** see the later module's `impl Sup W` while the check beside it calls that
same impl missing.

**Positive control** (`s3/`, same graph with `impl Sub W` deleted): `run` prints **42** at
exit 0 — graph-global candidacy resolves and the evidence routes for the concrete goal, so
the probe discriminates rather than merely producing an error.

**Fail direction: LOUD.** `ieRowsVisibleAt` can only under-report existence, so this is a
false reject, never a silent accept. Falsifies no ruling; it *converts RUN-039 from an
unverified worry into a measured defect*, which is the escalation RUN-039 asked for.

---

## F2 — LIVE, S2. Door 4 fires where there is no evidence to route

**Units:** Door 4 (RUN-047) vs A-3.6.

`i2/` is `1564`'s fixture with **one variable changed**: `impl Tag (Wrap a)` carries **no
`requires`**. Rejecting order → `T-REQUIRES-UNROUTED` at `nest.mdk:3:16`. Control order →
exit 0, prints `wrap`, and `build --keep-ir` shows `define i64 @mdk_nest__nest(i64 %arg0)`
— **arity 1, no dict parameter**. So for this shape no dictionary is ever passed, yet the
message asserts *"accepting it would build a program that reads a dictionary that was never
passed."*

Code-level derivation, not just the probe: `residualPredsOf`'s `Some (subst, [])` arm and
its old `None` arm both yield `[]`. `unroutedResidual`'s guard is `implMatchesU` alone — it
never asks whether the matched impl **has** requires — so it converts exactly the
no-requires case, whose correct answer is `[]` either way, into a hard error.

Not a regression against `main` (pre-A-3.6 this program was rejected as `T-NO-IMPL`), so
this is an incoherence between Door 4's **guard** and its **claim**, not new breakage.
**OWED:** whether the mid-sprint accept of this shape compiled correctly cannot be settled
without a pre-Door-4 binary, and rebuilding was out of scope.

---

## F3 — LATENT. `ordHere == -1` now fails in two opposite directions

`checkModuleFullDiags` passes `ordHere = declEnvsOrdOf mid declEnvsHere` (documented
fail-CLOSED, `-1` on an unknown id) to both checks. At `-1`:
`checkSuperImpls` → `ieRowsVisibleAt -1` → no rows → every super reported missing (**loud**);
`checkCoherence` → `cohRowsOwnedBy -1` → no rows → **coherence silently checks nothing**,
where the pre-A-3.7 `checkCoherence prog` checked the decl list unconditionally.
Latent today — the mids come from the list `buildDeclEnvs` indexed (typecheck.mdk:2921).
**What makes it live:** a fourth Module-mode driver, or any path stamping a mid
`buildDeclEnvs` did not index. A-3.7 introduced a silent arm under a sentinel the arc
documents as fail-closed.

---

## F4 — `runFinalChecks` verdict: CORRECT on both paths

Three call sites, all checked against the two decl populations they name:
`checkToLines` (`progIe` twice, `hasPrelude=False`); `seedAndCheckSplit`
(`flatImplEnvOf userDecls` / `flatImplEnvOf prog`, `False`); `checkModuleFullDiags`
(`declEnvsHere.deImpls` twice, `ordHere`, `True`). `ownCe`/`cycCe` line up with
`checkPhantomMethods` / `checkInterfaceCycles`+`checkSuperImpls`. No swapped arm despite two
adjacent `ClassEnv` and two adjacent `ImplEnv` parameters.
`globalCoherenceConflict`'s new source (`driverState…deImpls`) is written by
`checkModulesPreamble` from the **same** `modules` value both callers previously walked, and
`declEnvsRef` has exactly two writers (27301, 27780). Behaviour confirmed on the Module path:
`c1/` (intra-module hard conflict in a non-entry module) and `c2/` (in the entry module) both
reject; `test/dict_fixtures/s6-1c-multimodule-overlap` reports the intra-module **and** the
cross-module `W-INCOMPARABLE-IMPLS` exactly once each on `check` and on `run`, value 11 — so
A-3.7's `CohSweep` fix for the `cohSoftInScope` proxy holds.

## F5 — coherence vs candidacy on interface identity: no live divergence found

`1438/main.mdk` now runs and prints 3. `i1/` (same-spelled interfaces, impls at a shared
head, bodies made distinguishable 100/200) prints `100`/`200` — dispatch does not collapse
through the bare-spelling leg here, because two interfaces in one graph cannot share a
method name, which is what would be needed to observe the collapse. **Latent**, gated by that
language rule.

---

## Ledger / prose defects (all DERIVED by grep on this tree)

1. **`test/registry_keying_ratchet.sh` still says "A-3.5b remains owed and DOES read IE".**
   A-3.5b landed in `5efc8525`. FALSIFIED.
2. **`ieRowsVisibleAt` appears ZERO times in the ratchet.** The `declEnvsRef` row's post-A-3.6
   enumeration of who kept the ordinal filter lists "this seed, the alias table, the ctor
   overlay pool, the field-owner multimap, the data param-kind table, and both CE lookups" —
   and omits the one **IE** reader that kept it. The ratchet is the arc's account of that
   reader set, and the omitted entry is precisely F1's seam.
3. **`flatImplEnvOf` appears ZERO times in the ratchet**, whose Flat-arm paragraph still reads
   "all three relocated checks build a single-module **ClassEnv**". It is now four checks and
   two env kinds.
4. **A-3.7 has no ratchet row at all** — `cohSameIface`, `cohRowsOwnedBy`, `ieRowsAll`,
   `ieRowsOwnedBy` are absent, while the same row still carries the history sentence
   "`deImpls` has none [no reader] either outside the temporary `ieShadowCompare` instrument".
5. Ratchet `declEnvsRef` row keeps "under A-3.6 they reduce to `adPub && adOrd != cur`, the
   intended end state" immediately before its own retraction of that claim. The in-source
   `aliasVisibleTo` comment deleted the clause; the ratchet only appended a ⚠️. Cosmetic
   relative to 1–4, but it is the same not-re-cut pattern.

No `DECISIONS.md` ruling is falsified by what landed. RUN-039/RUN-042 are *upgraded*: the
seam they recorded as unruled is measured live (F1).

## Could not determine

- Whether the mid-sprint (A-3.6-only) accept of F2's no-requires shape miscompiled — needs a
  pre-Door-4 binary.
- Whether F3's `-1` is reachable through the LSP/MCP drivers; only `typecheck.mdk`'s own
  callers were enumerated.
