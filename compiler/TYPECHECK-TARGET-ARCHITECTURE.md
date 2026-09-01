# Typechecker Target Architecture — the ground-up design

**Status:** PROPOSAL — the idealized architecture for the full type-system pipeline
(resolve identity → declaration analysis → inference → entailment → elaboration →
global checks), designed from the semantics in `docs/spec/DICT-SEMANTICS.md`,
`docs/spec/EFFECTS-SEMANTICS.md`, and `docs/spec/SHADOW-SEMANTICS.md`, informed by
the derived map in [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md). It
answers *"what would this system look like designed from scratch, knowing what we
now know?"* and maps every element to the current implementation and to a staged
migration in which `main` stays green at every step.

**Review provenance.** This document went through four independent adversarial
reviews before finalization (2026-07-29): spec-rule conformance, migration
feasibility against the live tree, issue-tracker fidelity, and a code-reality red
team on the two largest claims. Both central claims — the promotion fixpoint is a
scheduling artifact (R1), and identity-stamped dispatch removes #1072's mechanism
(B-2) — **survived with corrections**, all of which are folded in below. Four of
the review's defects were places where a first draft *paraphrased* a spec rule
more loosely than the spec wrote it; where a rule matters here, it is now quoted
or restated at the spec's own precision, and the reader should treat any residual
paraphrase as subordinate to the spec text.

**What this is not.** Not a description of current behavior (that is the map), not
a license for a big-bang rewrite (§7 is explicit that every increment is a
mergeable PR), and not a re-derivation of the specs — where the target disagrees
with today's code, the spec is the authority; where the spec is silent, §6 files
the owed spec paragraph as its own task.

**Reading order.** §1 states the design laws. §2 gives the component model. §3
maps it to the current code. §4 is the traceability matrix — the reason to believe
this architecture *eliminates classes* rather than instances. §5 lists the
decisions this proposal reopens (with justification) and the ones it deliberately
does not. §6 is the migration DAG. §7 is verification doctrine. §8 is risks. §9 is
the first per-unit design in this document: **A-3.4, the `IE` registry** — read it
only when implementing that unit; §2 K and §6 A-3 remain the architecture of
record above it.

---

## 1. Design laws

Every recurring defect class in this subsystem's history violates one of five
laws. The target architecture is the smallest structure in which all five are
enforced by construction rather than by discipline.

**L1 — One judgment, one implementation.** Each spec judgment (entailment,
elaboration, the effect judgment, the shadow resolution function, exhaustiveness)
has exactly one implementation, parameterized where call sites differ, never
forked. A "second copy for the other path" is the repo's #1 recurring bug shape
(P0-9, the imported-module bug, #873, #992's table of divergences, the 8-vs-9
stamper orders). Where two realizations are irreducible (interpreter vs emitter),
they consume one *decision* computed upstream and a differential gate diffs them —
and "consume, never re-derive" extends to every derived artifact of a decision
(dispatch words, admissibility predicates, route keys): an engine that recomputes
one from its own view of the world has forked the judgment (#1068 is this, in
wasm).

**L2 — Identity is resolved, never re-derived from spelling.** After the resolve
phase, no component keys anything by a bare `String` name. Types, aliases,
interfaces, methods, records, constructors, and bindings all carry
module-qualified identity assigned once, at resolve (the Haskell/Rust model,
decided 2026-07-25). A flat table keyed by bare name, populated across module
boundaries, is last-write-wins with silent loss — 10 confirmed instances
repo-wide (#1070), and for five of them per-table re-keying is *impossible*
because the collapse already happened upstream in the `Mono` representation.
The law therefore lands at the substrate: `TCon`/interface/method references
carry identity, so a bare-name table becomes unwritable, not just inadvisable.
(How identity is *represented* — interned ids vs encoded keys — is a real
decision owned by task A-1 in §6, decided in writing rather than by
measurement (A-1a, filed for that measurement, is withdrawn — see §6). It
is driven primarily by **source safety** (an encoded qualified spelling
written back into `TCon` risks `medaka fmt` corrupting source, §2) and by
**this law's own enforceability** (whether a representation's *type*
actually forbids a bare-spelling key, or merely discourages one, §2) —
performance is a distant third factor, not the primary one. The law here
is about where identity is *acquired*, not its encoding.)

**L3 — Order is either specified or irrelevant.** Wherever the spec makes a
result order-free (instance selection: *"never of search order, declaration
order, or resolution position"*, DICT §3; C4's single instance environment),
the implementation must be structurally order-free — computed once from a
whole-graph environment, not re-derived from a per-module view (#1072's
mechanism). Wherever order is genuinely semantic (route-stamper sequencing,
C5; numeric-literal defaulting relative to obligation checking), it is written
in exactly one place — one table, one driver — so "the two paths disagree on
order" (§5.3 of the map) cannot be expressed. Residually order-sensitive scans
that exist to match oracle behavior stay order-preserving until the clause
governing them says otherwise (see §5, reopened decision R2).

**L4 — Evidence is structured, and uniform at every binder.** Evidence is the
tree of DICT §2: superclass dicts in a distinguished `supers` component
(projection, never re-resolution — the missing `entailSuper` rung), instance
context captured at construction. Every binder that generalizes over a
constraint — top-level fn, impl method, default method, **and local
`let`/`where` binding** — abstracts dictionary parameters by the same `gen`
rule (DICT §4). The current exception for locals (`dict_pass` touches only
top-level defs and impl methods) is the structural cause of the whole
C family (#866-interim/#1040/#1043/#1052) and of the interim pin that is itself
unsound (#1052); #1082 is this law's migration vehicle. The spec's `gen` is
stated over `let` generically, but three things it does not yet say become
load-bearing at local binders — predicate-deferral across nested binders, the
value-restriction gate on which locals may abstract at all, and evaluation-timing
neutrality (wrapping a strict non-value binding in `λd̄.` moves a binding-time
panic to use time) — so the local-`gen` paragraph is an owed spec clause
(S-2(f)) and F-1 is gated on it.

**L5 — The spec is executable.** Every normative clause has (a) a row in a
per-spec enforcement table (clause → site → keying assumption — the form
SHADOW §3 already has and the S0-densest layer lacks), and (b) at least one
conformance fixture whose expected value was derived from the clause by hand,
never captured from an engine. Engines are not oracles here: derive the
known-wrong set from the tracker rather than trusting any count written down
(`gh issue list --label "S0: silent wrongness" --state open`), and remember
that all three engines agreeing proves nothing — #1047's wrong answer is
unanimous. A rule with no site is an unimplemented clause; a site with no
clause is an owed spec paragraph; both are findings, and the table makes them
enumerable instead of discoverable-by-incident.

---

## 2. The component model

Seven components. Boundaries are drawn by *contract*, not necessarily by file —
§5 (R3) explains which are separate modules and which are regions of
`typecheck.mdk` with a single gateway, respecting the evaluated-and-rejected
HM-core/dispatch file split.

```
  R  resolve identity      (frontend/resolve.mdk — namespace resolution created here)
  K  declaration analysis  (whole-graph: CE, IE, DataEnv — new gateway)
  I  inference             (the 25-arm infer walk — kept intact)
  S  solving               (ONE entailment engine + ONE resolution pass)
  E  elaboration           (gen/gen-rec/gen-sig at every binder; SCC-scheduled marking)
  G  global checks         (coherence, escape/launder, kinds, exhaustiveness bridge)
  D  diagnostics           (error-path machinery — extracted)
```

### R — Identity (in `resolve.mdk`, upstream of typecheck)

Resolve assigns every declaration a qualified identity `(originModule, name)` and
resolves every occurrence to it, for **all** namespaces: values, types, aliases,
interfaces, interface methods, records/fields, constructors. Two modules may
declare the same name; the collision surfaces at a *use site* as an ambiguity
diagnostic (`Ambiguous occurrence`), never at the declaration, never silently
(decided: Haskell/Rust model). The AST carries the resolution —
`DInterface`/`DImpl`/`TyCon` reference identities, not spellings.

🚨 **CORRECTION (2026-08-05): the value namespace is NOT already done, and the
sentence above used to claim it was.** It read *"values (already done via binder
ids), types, aliases, …"* — a parenthetical nobody re-derived, and the only
namespace this document ever exempted from Stage A. Re-derived against `main`
@ `73ceccdd`, what binder ids actually provide is **intra-module and per-run**
identity, and nothing else:

- They are sequential integers over one decl list, with **no module component**:
  `stampBindingIds decls = let top = numberFrom 1 (dedup (topBinderNames decls))`
  (`compiler/frontend/resolve.mdk:3402-3403`).
- They are minted **inside typecheck**, not at resolve. The one call is
  `let stampRes = stampBindingIds prog` (`compiler/types/typecheck.mdk:15447`),
  in the body of `checkBodyImpl` (`compiler/types/typecheck.mdk:15432`) — and
  `prog` there is the *current pass's* declaration list (on `Module`, one
  module's decls; on `Flat`, `coreProg ++ prog0`), so two modules' bindings are
  independently numbered from 1.

**Per-run integers do not cross a module boundary.** The value namespace
therefore has identity **within** a module and none **across** one — which is the
only place any defect in family A lives.

This document already said the true thing one paragraph down and never propagated
it into the claim above: the *Honesty about scope* paragraph immediately
following calls value binder ids "the one identity precedent" and records that
they are "minted by `stampBindingIds` *inside* `checkBodyImpl`, per run".
`docs/spec/DICT-SEMANTICS.md`'s §11 **I4** row states it at full strength — value
binder ids "are per-run integers, not `(module, name)`"
(`docs/spec/DICT-SEMANTICS.md:2138`). ⚠️ That row's own two line citations for it
are stale (`compiler/frontend/resolve.mdk:3106`, `compiler/types/typecheck.mdk:13798`);
the live ones are the two above, re-derived here exactly as §11's preamble
instructs. The *claim* is correct; only its coordinates had rotted.

**Two defects were that seam failing in opposite directions**, which was the
evidence they were one unit rather than two bugs: **#1326** — a
same-named cross-module binding's context is attributed to an *unconstrained*
sibling, so a legal program is rejected at its own call site (fails **closed**);
and the **re-export residual on #845** — a declared context is not found across
one `export import` hop, so the obligation is never checked and `check` greens
(fails **open**). Both ask *"which `(module, name)` does this local spelling
denote?"* of **import syntax** rather than of resolve. Adjudications: the
2026-08-05 comments on #1326, #845 and epic #1122.

⚠️ **UPDATE (structured-predicate-carry sprint, #1948): both members are now
DRAINED, so this seam is history, not a live pair of bugs.** The re-export
residual on #845 was already recorded CLOSED elsewhere in this document (§4
family A/H, #1114/PR #1328). **#1326** — which this document's own 2026-08-09
UPDATE 2 (below, in the A-2 scoping section) said "stays OPEN" — has since
been measured fixed too: `docs/spec/DICT-SEMANTICS.md`'s §4.2 OD6 row records
`check`/`run`/`build` agreeing under both import orderings (exit 0, printing
`ok / 5`), regression-guarded by
`test/import_order_fixtures/1326-samename-sibling-constraint-misattributed-import-order/`.
Its GitHub issue remains open for bookkeeping only — the defect itself is
drained. Neither member is live evidence for the seam-unification argument
any longer; the mechanism analysis above (one un-keyed name-resolution seam
producing a false positive in one direction and a false negative in the
other) stands as the historical reasoning that motivated it.

**Not this seam, and named here so the scope does not drift:** #1330 and the
`Debug (Int -> Int)` residual on #792 are POLICY defects on channels whose keys
are correct for their job, adjudicated 2026-08-05 onto B-3-ext (#1114). Identity
work cannot drain either — #1330's dedup key has already been through A-2's
re-key and still merges two predicates with the identical `TCon "__tuple2__"`
head.

**Why this is recorded as a correction rather than silently edited:** a wrong
*"already done"* is worse than a missing entry. A missing entry gets noticed at
scoping; an "already done" is the reason nobody looks. That is not a hypothetical
here — the 2026-08-05 architecture audit adjudicated four defects and **two of
them landed on no filed owner, both in this one gap** (#1122). §6's Stage A tail
now carries the owed unit; §4 family A marks its drains ◇A-values.

Honesty about scope: today resolve does **not** resolve type/interface names at
all (`checkType` checks existence; type-name→origin resolution happens inside
typecheck via `fromAstTypeE` + `universeAliasTable`), and the one identity
precedent — value binder ids — is minted by `stampBindingIds` *inside*
`checkBodyImpl`, per run. R is therefore *created*, not extended: namespace
resolution moves to the resolve phase and the identity-minting seam moves out of
mid-typecheck. §6 A-1 carries the mechanics (named-field AST records; structural
dumps strip identity fields the way `ELoc` is stripped, which is what makes the
first PR byte-identical at all).

Consequences downstream:

- The typechecker's `Mono` representation distinguishes two modules' `Cfg` — the
  five #1070 tables whose re-keying was *impossible* ("both modules' `Cfg` are
  the same `Mono`") become keyable, and then become unnecessary as tables get
  replaced by K's environments.
- **Shadow detection stays a surface-name intersection — by definition.** A
  shadow is a surface-name pun between two things whose resolved identities are
  *necessarily distinct* (`M.size` vs `Sizeable.size`), so SHADOW S1's
  per-module bare-name intersection is computed at resolve, where both sides'
  identities are in hand; what identity buys is that detection **records the
  resolved pair**, so the build path never re-derives it through `mangledName`
  forward-construction (the S1 keying row behind bug `0b4a7882`). Routing then
  keys on the recorded identities, per S1–S9 unchanged.
- `private_mangle` stays emit-only and stops being load-bearing for semantics:
  it renders identities into symbols; it no longer *creates* the only
  disambiguation that exists (#1070's root cause note).

### K — Declaration analysis (whole-graph, before any body inference)

One pass over the topologically-loaded module graph builds three environments,
keyed by qualified identity, **assembled once and never per-module**:

- **`CE`** (class environment): interfaces with declared parameter kinds
  (EFFECTS §6.1–§6.5), method schemes, superclass predicates; W1 acyclicity;
  the method-effect-var well-formedness rules (Option A + argument-occurrence
  coverage, EFFECTS §6) checked here, at the declaration, where they are
  decidable without dispatch.
- **`IE`** (instance environment): every impl with its full head, context, and
  method table; impl completeness and phantom-method rejection
  (currently enforced with no spec — the owed paragraph is task S-2 in §6);
  declaration-time overlap diagnostics (advisory (a)-warnings; acceptance stays
  per-goal C1(c)).
  ⚠️ **W2 is NOT among these, and this bullet claimed it was.** No static,
  declaration-time W2 (instance-context termination / Paterson coverage) exists
  anywhere in the tree. What exists is a *dynamic* resolution-time cutoff —
  `argImplRequiresRoutesRecD`'s `if depth >= 32 then []`
  (`compiler/types/typecheck.mdk`) — under which a non-shrinking context
  (`impl C (T a) requires C (T (T a))`) terminates by silently yielding no
  further requires-routes rather than being rejected, and, per DICT §11's W2
  row, *"the program is accepted either way."* This design **keeps the fuse and
  leaves W2 unenforced**: making it static would *reject* programs `main`
  accepts today — a language-visible acceptance **narrowing**, and §5 R2's two
  enumerated exceptions are both widenings carried by a could-not-pass-before
  fixture, a bar a narrowing cannot meet. Promoting W2 to a static check is
  therefore a separate, owner-adjudicated decision with its own migration and
  fixture story, deliberately **not** taken here. Note the consequence for K's
  outputs: because the fuse can truncate a requires chain, IE's derived route
  data is *not* total at depth ≥32, and no clause below may assume otherwise.
- **`DataEnv`**: datatypes, constructor schemes, records and field ownership,
  aliases with cycle rejection.

**Why whole-graph is load-bearing, not a style choice.** C4 (single instance
environment) and I2 (global `IE` after import resolution) are *spec clauses*.
The current architecture approximates them by marshalling per-module universe
snapshots — the cells are the `universe*`/`obUniv*` fields on the driver
record; derive the count rather than trust a number here — this parenthetical
said `23`, and re-derived 2026-08-12 with the two commands below it reads
**15 `universe*` + 0 `obUniv*`** (A-3.4 PR2 deleted all three `obUniv*`
accumulators; #1512 and #1557 retired four more `universe*` rows). It will rot
again; run the commands:
`grep -rn '^\s*universe[A-Za-z0-9_]* *:' compiler/ stdlib/ | grep -v '\.md:'`
plus `grep -rn '^\s*obUniv[A-Za-z0-9_]* *:' compiler/ --include=*.mdk`
(`loadDataUniverse`/`storeDataUniverse`/
`appendUniverseAccums`) — and the approximation is exactly where #1072 lives:
a site's module sees only its own slice of `IE`, concludes there is no
collision at a head, and stamps a bare-head key that the emitter then ORs into
every arm. When `IE` is one global environment consulted at solving time,
*"the site's module didn't see the other impl"* becomes inexpressible.
Import scoping remains a **visibility** filter applied at name resolution (R),
never a candidacy filter on instances — that is C4's own sentence (*"two
modules resolving the same predicate must consult the same instance set"*),
with I2 adding that scoping affects the visibility of *names*, not the identity
of evidence. Note this has one deliberate, language-visible consequence beyond
golden churn: an impl living in a topo-*later* module of the loaded graph
becomes usable by an earlier module (orphan-instance-style acceptance change);
§5 R2 owns it, and S-2(a) writes the candidacy sentence into the spec.

**Candidate collection is complete; an index may narrow it only when it
provably cannot drop a match.** IE's candidate set for a goal `C τ̄` is every
instance of `C` that matches `τ̄`. Any index over IE is admissible only if it is
**match-preserving**: every instance the index excludes from a lookup provably
cannot match that goal. Head-tycon bucketing is match-preserving *only for
instances that have a head tycon*, so **tyvar-headed (`__none__`) instances must
be unioned into every bucket lookup** — exactly as `implMatchesU` /
`implMatchesReceiverU` / `findMatchingImplReqsU` already do today via
`univHeadless` on the obligation-checking path.

✅ **The route-stamping path now does it too (F-3b, 2026-08-01, #1128 CLOSED).**
This paragraph read "and exactly as the route-stamping path's `KeyBuckets` does
**not** (`keyEntryOf` emits no entry when `headTyconTy` is `None`, so a
fully-general `impl C a` is absent from it entirely — #1128)". `keyEntryOf` now
registers a tyvar head under `noneHeadTag` and `candidateBucket` unions that
bucket into `matchingEntries` / `matchingEntriesByIface`. The union is a stable
merge on a declaration index carried by `KeyEntry`, not a concatenation:
concatenating would make "concrete always first" the tie-break
`pickMostSpecificEntry` falls back on, which is an arbitrary internal constant
and is invisible to the declaration-order permutation differential.
⚠️ **Registration and union are NOT the whole clause.** A headless winner is
*selectable* the moment the union lands and still not *routable*: `keyForSite`
upgraded the route key only on a head-tag collision, and a headless winner sits
alone in its bucket, so it answered `None` and the caller fell back to the
goal's head tycon. Two independent implementations of exactly the text above
were inert for this reason. Completing candidate collection obliges you to
check that the selected candidate survives to the route.

Two implementations of one judgment, one complete and one not, was an L1 fork;
K's IE is the single environment both must read, and that consolidation is still
owed — F-3b closed the *completeness* gap on the route path without merging the
two registries. ⚠️ Note that `matchingEntries`' pre-F-3b completeness argument was
circular — its bucket was exhaustive *because* tyvar-headed entries were dropped
at construction — so "the buckets already collect the same entries" must not be
read as evidence against this clause.

⚠️ **Sequencing constraint (loud-over-quiet) — ✅ DISCHARGED by F-3c (2026-08-01,
#1155).** It read: completing the candidate set routes strictly *more* goals into
`pickMostSpecificEntry`, which resolves a non-unique winner by **silently keeping
the head of the list** — declaration order, no diagnostic — so landing
completeness before the C1 per-goal-unique-minimum diagnostic would enlarge the
population reaching a silent-wrong-answer path, a severity increase even though
each individual fix is correct. F-3c made that arm a located
`T-AMBIGUOUS-INSTANCE` naming the goal and every competing impl head
(`reportAmbiguousOverlap`), so the population it was worried about is now loud.
⚠️ **Read the discharge narrowly: it holds for CLOSED goals only.** The reject is
gated on §6.2 T3 closedness (`goalsClosed`) because T4 defers a goal still
carrying an unbound metavariable rather than deciding it; at a non-closed goal
the silent head-of-list pick survives. That residue is **reachable and pinned** —
`test/dict_fixtures/s6-2-t3-closed-goal-reported.mdk` and its one-token sibling
`…-t4-open-goal-deferred.mdk`. ⚠️ An earlier revision of this paragraph said
*"unreachable today"*, which is a different and false claim: a declaration-time
rejection is **not** an early exit (errors accumulate), so the impls are still
registered and the goal still reaches the selector.

✅ **F-3d landed 2026-08-01 and the residue is now USER-VISIBLE, which is the
sequencing constraint above cashing out.** Two corrections to what this paragraph
predicted:
1. F-3d did **not** "remove the coherence reject" — the 2026-08-01 owner decision on
   #311 **demoted (a) to a warning** (`W-INCOMPARABLE-IMPLS`) and kept the
   mutually-`⊑` class a hard error, because α-equal heads satisfy (a) while failing
   C1 and nothing downstream catches them.
2. The open half is now an **ACCEPT that runs**, and its value is decided by
   `impl`-block order at exit 0 (`1`, or `2` with the blocks swapped). The warning is
   what keeps that from being a loud→silent transition; it does not make the answer
   order-free. Tracked at **#1183**, pinned as a KNOWN-BAD permutation row in
   `test/diff_compiler_dict_semantics.sh` §4. **Closing it is §6.2 T4's own work — a
   quiescence post-pass — which T4 forbids landing before I5.**

### I — Inference (kept structurally intact)

The 25-arm `infer` walk, application/method/match/pattern/binop inference, HM
with levels and value restriction, effect-row inference per EFFECTS §3. This
component is deliberately conservative: the map shows the HM core is good, the
file-split around it was evaluated and rejected, and the `pending*` deferred-site
channels are HM-forced (a route depends on which tyvar survives unification).
Three changes only:

- **Sites and obligations get one record shape each.** Dispatch sites of every
  flavor (return-position method, binop/unop, arith, arg-stamp, rec-dict,
  method-dict, RLocal) are recorded as one `Site` record with a kind field, into
  channels that remain per-kind but share storage discipline (`Windowed`), and
  obligations complete the #991 unification (one `UObligation` with live
  provenance arms; `implOblToU` retired).
- **Numeric-literal defaulting becomes a solving step** (see S), not an
  interleaved family of five cells whose ordering differs per driver path.
  Inference *records* literal sites and taints; it does not decide representations.
- **Row unification consults one polarity discipline, computed per parameter,
  not guessed per arm.** The re-open machinery already implements EFFECTS §5's
  polarity-carrying subtyping encoding correctly for arrows; the defects are
  positions that don't consult it. The target rule, at the spec's precision
  (EFFECTS §9: the safe widening direction for a covariant occurrence is
  exactly the unsafe one for a contravariant occurrence):
  - **the `Effect`-kinded index slot is invariant** (#1094-class; the
    closed~closed no-op arm is correct *for arrows* and wrong for indices), and
    the same-tail arm must still check the atom prefix (#1103), and `rowArgOf`'s
    catch-all must be a kind error, not `pureRow`;
  - **every type parameter gets a computed polarity** (covariant /
    contravariant / mixed) from its field occurrences, propagated transitively
    through nominal types; contravariant-or-mixed occurrence ⇒ no covariant row
    leniency at that argument. Write channels (`Ref`/`Vector`/`HashMap`,
    #1098) are the co∧contra *special case* of this rule, not the rule — a
    contravariant occurrence in an ordinary immutable datatype
    (`data Taker a = MkTaker (a -> Int)` holding an effect-bearing arrow) is
    the same laundering channel with no mutation anywhere, and a write-channel
    proxy misses it. The `List` control (covariant-only) stays accepted.
    This remains compiler-internal — no user-facing variance annotations
    (decided 2026-07-27);
  - **two boundary cases are named, not defaulted**: grade-join positions
    (`f (e ⊔ e₂) b`, once #821 lands) are checked by *grade subsumption*,
    a third discipline that is neither arrow-covariant unification nor index
    equality; and a position reached through a `type` alias takes its mode from
    the **post-expansion** kind (an alias parameter can never be
    `Effect`-kinded today, so pre-expansion mode computation silently reads
    `Type`).

### S — Solving: one entailment engine, one resolution pass

**Entailment** is DICT §3 verbatim, in one engine (today's `entail` is already
the file's best subsystem — 620 lines, 5 cells; this component *finishes* it):

- `assum` → `super` → `inst` with the assum/super-over-inst precedence;
- **`entailSuper` becomes a real rung**: superclass evidence is a projection
  into the evidence tree's `supers` component (#993's target), replacing the
  flatten-into-sibling-slots pass (`expandSupersTable`) and the four duplicate
  super-closure walks with **one** closure combinator parameterized by payload;
- **every goal that reaches `inst` goes through the one `min⊑` selector** — and
  *only* those goals. Stated at the spec's precision because the loose form
  ("every position uses the selector") is itself an S0: an `assum`-discharged
  goal (a dict parameter in scope) or a `super`-discharged goal (a projection)
  has **no selected instance**, and re-resolving an in-scope rigid goal through
  `inst` rebuilds general evidence where the construction site's more specific
  dict must be forwarded — the #203 nested-obligation defect class. Routes
  therefore carry **evidence references**, not instance names:
  `InstId` (an `inst` commitment) | `DictParam k` (assum) | `SupersPath`
  (projection). Identity is stamped **wherever `inst` runs** — at
  evidence-construction/commit points: a `var`-site residual predicate that is
  ground there, a receiver-grounded method occurrence, a nested `requires`
  discharge, a supers fill. For dict-parameter-supplied dispatch the carrier is
  the **dictionary word built at the construction site**, which the runtime
  dispatcher reads — a polymorphic body site has nothing to select and nothing
  to stamp. Emitted dispatch tables key their arms on instance identity (plus a
  disjoint word class for synthesized default-method arms, which exist for
  receiver tags with no impl at all and must not be collapsed into the instance
  namespace), so an engine cannot re-derive the choice from a coarser key
  (#1072; family B: #1071/#1062/#1046/#1075).

**Commitment timing (the rule R1's schedule must obey).** `inst` never fires on
a goal containing a free unification metavariable that is still externally
constrainable. Generalized bindings close their variables at `gen`; ground goals
commit where they stand; but a **value-restricted / non-generalized binding**
keeps live metavariables a later SCC (or module) can still ground — committing
its goals at SCC close would make instance selection depend on where an SCC
boundary fell, exactly the order-dependence DICT §3 forbids. So: *generalization
and marking are per-SCC; route resolution, `inst` commitment for non-closed
types, and numeric-literal defaulting are whole-graph post-passes at
quiescence.* Whether module-boundary monomorphic types instead *freeze* at
module close with an ambiguity diagnostic is a semantics choice S-2(b) must make
explicitly; this document defaults to quiescence (matching today's
whole-module-then-stamp behavior, extended to the graph).

**Arg-tag dispatch, at the spec's condition — not a paraphrase.** DICT §5:
arg-tag is sound *iff* the class parameter occurs in an argument position whose
head constructor **uniquely determines the most-specific matching instance**,
*and* that argument is evaluated. "No overlap below the head" is strictly weaker
and licenses an S0 with no overlap in sight: `impl C (T Int)` / `impl C (T Bool)`
do not overlap, yet the tag `T` determines nothing; a multi-param interface's
first-argument tag cannot separate instances differing in the second parameter.
Target rule: admissibility is a per-(class, argument-position) predicate —
every constructor reachable at that position must map to exactly one
`min⊑`-winner for every goal that can reach the site — **computed once from the
final whole-graph `IE` after K, frozen into the elaboration output as data, and
consumed (never re-derived) by every engine.** An engine that recomputes
admissibility from whatever instance universe it happens to have loaded has
rebuilt #1072 inside the optimization.

**Resolution (the stamper pass)** drains the recorded sites **in one order,
written once**. Today two drivers run 8 vs 9 stampers in different orders and
the source's own ordering comment is stale (map §5.3); C5-style constraints
("RLocal must override what resolveSites/resolveArgStamps stamped on the same
ref") become *the order table's* content, asserted in one place. With a single
driver (E below) there is exactly one instance of this pass.

**Defaulting** (numeric literals) runs here, at quiescence, at a specified point
relative to obligation checking — identical on every path because there is only
one path — with the spec paragraph (currently: none) written as part of the
migration (#563/#564 get their protection rule from that paragraph, not from
cell placement; #564's recorded "needs level discipline first" prerequisite is
part of that task).

### E — Elaboration: one driver, one mode, marking on the schedule

The single most consequential structural change, and the one the map shows is
missing with no issue filed (§7.1, §7.6):

**One driver.** The multi-module driver is the only driver; a single file is a
1-module graph. This is DRIVER-COLLAPSE-PLAN's own stated invariant ("the
degenerate 1-module case automatically satisfies the flat path's invariants") —
marked IMPLEMENTED while §5 of the map measures 20 `match mode` branches, two
divergent stamper sequences, and a `Flat`-mode re-entry inside the promotion
fallback. The target deletes `CheckMode` entirely — but the migration must
respect what the Flat path *is* today: not a legacy remnant but (a) the live
production fallback for any multi-module program with an unsignatured
constrained function, and (b) the substrate of the repl, LSP hover/single-file
env, playground, single-file doctests, `snapshot`/`check_policy`/`doc`, and the
`elaborateDict`-driven gate entries (`llvm_emit_typed_main`,
`core_ir_dict_pp_main`) whose golden families pin Flat behavior. §6 Stage E is
therefore a consumer-by-consumer migration, then the collapse, then the
schedule change — three separately-gated moves, not one.

**SCC-scheduled marking dissolves the promotion fixpoint.** Precision matters
here, because the naive framing overstates the novelty: per-module SCC ordering,
per-SCC generalization, and `gen-rec`'s shared dict prefix **already exist**
(`processTopGroups` → `tarjanSCCs` → `processSCC`; recursive occurrences are
realized post-hoc by `realizeRecDictApps`, which is `gen-rec`'s "no fresh
entailment" already implemented), and cross-module SCCs cannot exist (the loader
rejects module cycles). What forces today's fixpoint is that **marking**
(`EVar`→dict-app rewriting) is a whole-tree syntactic pre-pass run before any
inference, so a caller's forwarded constraint materializes only after a re-mark
— one call-chain layer per pass ("one layer of a call chain promotes per pass",
the fixpoint's own header) — and a non-empty harvest forces the bare sweep's
results to be **discarded** and redone flat. Every input marking needs is
declaration-level (verified: `marker.mdk` and `prePassDictArg` consume decl
names, signatures, D3a indices — never inferred schemes) *except* the promoted
set itself, which is exactly what the schedule carries. So the delta is two
things and two things only: **(1) marking happens per-binding, on the schedule,
after its callees generalize** — this alone dissolves the fixpoint and the
discard; **(2) promotion facts cross module boundaries in the environment**
instead of via `crossModuleFunConstraintsRef` snapshots harvested from a
scratch joint typecheck. Three whole hack families dissolve with the flatten:
`dropShadowedCore` (bare-name shadow collisions in the joint program), the
sticky-error snapshot/restore around the scratch typecheck, and the #194
empty-harvest bimodality itself.

Corrections the red team imposed, now part of the design: schemes are final
per-SCC **for generalized bindings only** — non-generalized (value-restricted)
bindings keep live metavariables, so route resolution and defaulting stay
whole-graph post-passes per S's commitment rule; the schedule's marked-node set
must enumerate **impl bodies, default bodies, prop and test bodies** (today the
whole-tree pre-pass covers them for free; a schedule that walks only `DFunDef`
groups silently regresses them — the exact `DLetGroup`-skipped shape
`marker.mdk` itself documents); and the schedule's cleanliness **depends on
Stage A** (per-caller alias-spelling marking and the mangled shadow maps are
what makes the joint-flatten machinery ugly today, and identity is what retires
them), which is why E-4 sits after A in the DAG.

**Evidence at every binder (L4).** `gen`/`gen-rec`/`gen-sig` apply uniformly to
top-level bindings, impl methods, default methods (one `MethodBodyKind`-merged
driver per #992, keeping the load-bearing two-unify as a kind parameter), and
**local bindings** (#1082): a `let`/`where` binding that generalizes over a
constraint abstracts its own dict params, routed per use site — gated on the
S-2(f) spec paragraph (deferral across nested binders; the value-restriction
gate; timing neutrality — dict abstraction only where the value restriction
already licenses generalization, where wrapping is evaluation-order-neutral).
The interim all-or-nothing pin (PR #1021) and its unsoundness (#1052) retire
with it.

**Output contract.** Elaboration produces the typed, dict-explicit, route-stamped
AST that *both* engines and the Core-IR lowering consume — one elaboration
(decided 2026-07-15: the owner would sooner retire the tree-walker than keep two).
Dispatch decisions live entirely in evidence references and frozen admissibility
data (single-evaluator law, §7); engines project and apply, never select.

The output additionally carries, **per binding and per method, its arity and
calling convention** — leading dict-param count and order (DICT §8 I1), source
arity, eta-expansion target — as data. **No engine derives arity from a clause
pattern count or from a declared signature.** Both routes exist today and
disagree: `eval.mdk`'s `implMethodValue` builds a closure from the impl clause's
`pats`, while the emit side's `methodArityOf` (`backend/emit_support.mdk`) reads
a table `core_ir_lower`'s `methodIfaceTable` builds from `methodArgTys`, which
walks the declared signature's whole arrow spine
(`methodArgTys (TyFun a b) = a :: methodArgTys b`) — so a method whose result
type is itself a function is over-counted and lowered to a PAP whose strict
prefix never runs (#1034); #826 is a third disagreement, define vs call site.
This is L1 applied to arity: one decision, computed once, consumed. It does not
by itself fix #1034 — the over-count still needs one
correction in the lowering, and `a -> (Unit -> Unit)` and `a -> Unit -> Unit`
remain the same `Ty` — but it removes the substrate that keeps regrowing it.

⚠️ **This clause must ship with a hand-derived conformance fixture for arity
(L5), and the reason is not hygiene.** #1034 was findable *only because the
engines disagreed*: eval was right, native was wrong, and `diff_compiler_engines`
had a divergence to show. Centralizing arity makes both engines consume the
*same* arity — so a wrong centralized arity becomes a **unanimity no differential
can see**, which is #1047's failure mode exactly. Removing the only signal that
found this class, without replacing it with an oracle derived by hand from the
clause, converts a visible divergence into silent wrongness — a severity
increase disguised as a consolidation. The fixture is the replacement signal,
not paperwork.

### G — Global checks

Coherence (C1 per-goal unique minimum — migrating the enforced condition from
(a) global comparability to the spec's (c), #311/#614), superclass-consistency
auditing (C2 as an invariant check), signature authority (`gen-sig`: reject, not
narrow — #830's silent narrowing becomes a def-site diagnostic, with the
vector-valued entailment side condition per DICT §9), W3 rigidity with the #817
carve-out retiring on the graded arc (#823), and the exhaustiveness bridge.

The effect soundness walks converge **only where the spec's timing allows**:
the binding-boundary escape check and the #995 post-unify shape work
(`launderEscapeFromLog` + `checkImplEffVarRigidity`) become one traversal — but
the **#803 impl-body bound keeps its pre-unification placement**, because its
exactness *is* its timing: checked before the body's rows unify into the
declared type, `argContributable` is all variables and only a concrete atom can
launder; post-unification the same check either under-rejects (S0) or
over-rejects (breaks `map`/`traverse` impls — the blanket ban EFFECTS §6
explicitly refuses). The declaration-time coverage rules likewise stay at the
declaration (once unification runs, the same-tail arm has already absorbed the
atom). The rigid-skolem idealization that would subsume the bound remains
blocked on #817/#820 exactly as #995 records; until the graded arc retires the
carve-out, the pre-unify bound is load-bearing. The eliminator obligation for
graded methods (EFFECTS §6.7) is enforced here for interface methods (#1095: a
result-index occurrence is a promise about force time, never a charge at call
time; and per #1100, an abstract-head row-kinded argument must be *collected*
by the coverage rule at all); for declared eliminators it is already a
consequence of the §5 escape check (EFFECTS Q4, resolved half). All of this
runs over K's environments; none of it holds private registries.

### D — Diagnostics

The ~1,050 lines / ~96 functions of error-path-only machinery (message
construction, mis-framing provenance, cascade suppression) extract to a sibling
module with a narrow interface (push a structured `TcDiag`, read the
accumulators). Fires only on failure, must not perturb inference, has no inbound
dependency from the inference core — the map's safest extraction (§7.4). The
accumulating-errors discipline and `typeErrorsSticky`'s position outside every
reset bundle are unchanged (settled).

> ⚠️ **Issue 1147 shrank D and falsified one of its stated invariants.**
> *Swapped-argument detection* was a fourth item in that list (~145 lines,
> 14 functions); it is deleted, and the figures above are the old
> 1,200/~110 minus it. More importantly, "fires only on failure" and "must not
> perturb inference" were **not true** of that component: it ran ahead of
> inference on every two-argument application whose last argument was a literal
> (measured 3.2% / 1.2% of application nodes) and called `instantiate` there. The
> perturbation turned out to be unobservable — deleting the component left 170
> programs and the emitted LLVM IR byte-identical — but nothing *checked* that,
> and nothing checks it for the surviving components either. Treat this
> paragraph's invariants as design intent to be verified at extraction time, not
> as properties the current code has.

> 🚨 **D AS DESIGNED CANNOT BE BUILT. Stage F-2 (#1120) was WITHDRAWN 2026-07-30,
> not deferred, and the paragraphs above are the specification it was withdrawn
> against.** Two independent adversarial passes falsified **all three** of D's
> stated invariants, plus both implied ones:
>
> - *no inbound dependency from the inference core* — **false.** `unifyN` itself
>   calls `typeMismatch`, which calls `poisonMismatchVars`; 55 external callers,
>   21+ in the core.
> - *fires only on failure* — **false.** `inferAppExpr` called
>   `detectSwappedArgs2` before any error existed, and `tupleCallShapeHint`
>   unconditionally.
> - *must not perturb inference* — **false.** `detectSwappedArgs2` **replaced**
>   the inference result with a fabricated `freshVar ()`. (The #1147 note above
>   is the surviving half of this finding; the component it describes is gone.)
> - *pure extraction, byte-identical* — **false.** 36 of 61 functions need
>   back-imports, so the 2-module split is a **loader cycle**: it does not build.
> - *"push a structured `TcDiag`"* — **the interface does not exist.** `TcDiag`'s
>   message field is an already-rendered `String`, and the obvious repair (carry
>   operands, render downstream) was separately adjudicated and rejected at
>   **+58 special cases, −0 duplicated judgments** — relocation presented as
>   removal.
>
> Sizing was also ~2× over (~590–720 real lines, not ~1,200) because the per-row
> counts were taken from banner spans.
>
> **Tree check, not inference:** `ls compiler/types/` → `annotate.mdk`
> `registry.mdk` `route_key.mdk` `typecheck.mdk`. **There is no extracted D
> module and there is not going to be one under this design.**
>
> **What replaced it, both since CLOSED:** **#1146** (sever inference's
> control-flow dependence on the diagnostic accumulator — the *fourth* false
> thing, and the one that explains the other three: the dependency is not merely
> present but **inverted**, inference reading the error path's accumulator as a
> control signal at 5 sites, 3 gating) and **#1147** (retire the
> `detectSwappedArgs2` speculative-unifiability duplicate). **#480** unbundled
> and landed on its own.
>
> ⚠️ **The goal was right and the mechanism was wrong.** Getting diagnostics out
> of inference remains a live aim; *extracting a D module* is not the way to it,
> and the seven-component end state in this section still draws D as if it were.
> **An owner decision is owed** — fold D's duties into their host components, or
> re-scope a buildable D — and until it is taken, read every D row in this
> document as unreached, not pending. Tracked by **#1660**.

### Cross-cutting substrate

- **Registry discipline (the #1070 "owed gate").** One registry abstraction for
  cross-module tables: keyed by qualified identity, and either write-once-
  with-conflict-diagnostic or explicitly commutative (multimap/set). The
  structural ratchet covers **any cross-module-populated map in the pipeline,
  regardless of bundle** — `CrossRun` fields, `PerRun`/`DriverState`/loose
  refs, and the engine-side frame tables (`installConsts`/`findCell` in both
  parallel evaluators key their environments by the same resolved identity;
  the emit side is covered via `private_mangle` rendering). A bare-`String`
  key fails the check — the ratchet that prevents "registry #16 next month",
  which lint cannot see (a dataflow property, per #1070's own analysis).
- **Identity representation is a named decision, not an afterthought.**
  No interning mechanism exists in the tree today, and every hot map is
  `Map String` (`OrdMap a = Map String a`; `TcEnv`) — but the lookups on that
  map are **already dict-passed today**: `stdlib/map.mdk`'s
  `get : Ord k => k -> Map k v -> Option v` is constrained on `Ord k`, and
  `compiler/support/ordmap.mdk`'s `omLookup` is a monomorphic wrapper over
  that same constrained `get`, with no specialization pass in between. A
  composite (module, name) key does not newly introduce a dict-passed
  comparison — it is already there. The measured **+56% self-compile figure
  was a different mechanism**: routing hot monomorphic helpers
  (`elem`/`any`/`all`/`length`) through prelude `Foldable` folds instead,
  which loses `||`/`&&` short-circuiting (`.claude/workstreams/PERF.md`).
  Comparison cost is a **distant third** consideration; the two that
  actually discriminate between candidates are, in priority order:

  1. **Source safety.** `compiler/tools/printer.mdk` renders a `TCon`
     verbatim: `printType (TyCon n _) = text (tyConSurface n)`, and
     `tyConSurface`'s own comment records the exact failure class this can
     produce — it exists *because* `TyCon "__tupleN__"` once round-tripped
     through `medaka fmt` as a raw internal spelling that re-parsed as a type
     *variable* and corrupted the impl head. If `TCon`'s payload becomes a
     directly-qualified spelling (e.g. `"amod.T"`), `medaka fmt` writes that
     spelling into the user's source verbatim — and a qualified name in type
     position is a parse error, so the file becomes unparseable on the next
     read. That is source destruction, this project's worst severity class,
     from the printer alone; it disqualifies encoding a qualified spelling
     directly into `TCon`'s `String` regardless of anything else.
  2. **L2 enforceability.** A representation earns L2's "unwritable" (not
     merely "inadvisable") only if its *type* forbids constructing a key
     from a bare spelling — an intern table yielding an opaque id does
     this; a `String` does not, whether it is one qualified string or a
     `(String, String)` pair (see the third candidate, §6 A-1a) — nothing
     stops a future call site from building either shape by hand from a
     bare name, which is exactly the "inadvisable, not unwritable"
     weakening L2 warns about.
  3. **Allocation.** The real, in-tree-documented hazard for a *built* key
     is allocation on the GC-bound `check` stage, not comparison cost:
     `compiler/support/util.mdk`'s discussion of a built vs. reused key
     measures ~9x more bytes at n=3 and ~15x at n=400, with no crossover in
     that range, and invisible to both CI perf arms.

  Identity representation is still a named decision (§6 A-1, decided in
  writing — see below) — it is just weighed on the right axes.
- **Fused lockstep tables (#994).** Slot-parallel pairs
  (`funConstraints`+`Ifaces`, `methodConstraints`+`Positions`, the bare/Qual
  mirror pairs — the latter dissolve entirely under L2) become single
  record-valued tables; the lockstep invariant lives in one writer.
- **State model.** The four-bundle + `Windowed` discipline is kept (it worked —
  1,199 of 1,443 functions are pure; only 7 cells have diffuse ownership). The
  reset lifecycle simplifies with the driver: `CrossRun`'s marshalling triplet
  disappears into K (at stage E-4, not before — see §6 A-3's honest scope);
  `DriverState`'s mode flags disappear with `CheckMode`.

---

## 3. Mapping: current → target

Keyed to the map's §4 layers. "Kept" means structurally unchanged.

| Map layer / mechanism | Target component | Disposition |
|---|---|---|
| L0 unify/generalize/value restriction/`fromAstTypeE` | I | Kept. `fromAstTypeE` reads K's `DataEnv`+alias table (identity-keyed) instead of `universeAliasTable` |
| L1 refinement domains, α, row machinery | I (+ G checks) | Kept; row unifier gains per-parameter polarity + index invariance + the two named boundary cases (#1094/#1098/#1103 + the contravariant-parameter channel) |
| L2 `infer` and satellites, 57 cells | I | Kept intact — the settled no-split verdict stands |
| L2 numlit defaulting (5 cells, path-divergent ordering) | S | Re-homed as a quiescence-time solving step with a written ordering rule |
| L3 `processTopGroups`/SCC processing | E scheduler | Already SCC-ordered per module; gains per-binding marking + cross-module promotion carriage; letrec order becomes specified |
| L4 `entail` | S | Kept as the core; gains `entailSuper` rung |
| L4 obligation channels + checkers | I record / S check | #991 storage completion; one record, live provenance |
| L4 impl/default body drivers | E (`MethodBodyKind`) | #992 merge; two-unify kept as kind parameter |
| L4 `expandSupersTable` + 4 super-closure walks | S | Retired → tree evidence + one closure combinator (#993) |
| L4 specificity selection (`pickMostSpecificEntry` etc.) | S | The one `min⊑` selector; every `inst`-reaching goal routes through it |
| L4a the 8 `pending*` channels + 9 stampers | I (record) / S (drain) | Channels kept (essential); ONE drain order, one instance |
| L4a RLocal pinning (#1040/#1052/#1043/#1082) | E | Locals dict-abstracted (L4); pin machinery retired |
| L5 coherence | G | Kept pure; condition (a)→(c) |
| L5 field/record registry (`recordByNameRef` LWW) | K | Identity-keyed `DataEnv`; LWW impossible |
| L5 kind checks (`checkGradedImplHeads`) | K + G | ✅ **LANDED at A-3.5c (#1557).** Declared kinds (EFFECTS §6.1–§6.5) are read from `CE` at the reading module's ordinal (`ceSlotKindsAt`); the `ifaceParamKindsRef`/`universeIfaceParamKinds` pair and its writer are retired. ⚠️ The "**coordinate: #822 owns this machinery**" caveat that stood here is a **stale premise, not a live gate** — #822 CLOSED 2026-07-25. The impl-HEAD walk deliberately still iterates `prog`, not `IE.ieRows`: that is the mechanical condition under which A-3.5c is an A-3a unit at all |
| L6 shadow machinery (both kinds) | R (detect) + S (route) | Surface-name detection at resolve, resolved pair recorded; routing per SHADOW S1–S9, single decision point |
| L7 `checkBodyImpl` spine, `CheckMode`, promotion fixpoint | E | One driver, one mode; fixpoint → scheduled marking (staged: consumers → collapse → schedule) |
| L7 universe marshalling (`load`/`store`/`appendUniverse*`) | K | Retired at E-4 (the marshalling serves the fallback path; a shim survives until then) |
| L7 import seeding/aliasing/ctor overlay | R + K | Visibility filtering at R; identity makes overlay collision-free (#733/#756) |
| L8 error-path machinery | D | 🚨 **NOT extracted — F-2 (#1120) WITHDRAWN as unbuildable 2026-07-30.** This row read "Extracted" for three weeks after the withdrawal. The machinery stays in `typecheck.mdk`; the live descendants are #1146 (sever inference's control-flow dependence on the accumulator) and #1147 (retire `detectSwappedArgs2`), both CLOSED. See §2 D's warning block — an owner decision on the component model is owed |
| `marker.mdk` `EVar`→`EMethodRef` | R (adjunct) | Kept as pre-pass (decl-level inputs only); dict-app marking for unsignatured fns moves onto E's schedule |
| `private_mangle.mdk` | backend | Emit-only rendering of identities; no longer semantics-bearing |

---

## 4. What becomes unrepresentable — the traceability matrix

The claim "eliminates bugs through architecture" is checkable: each row names a
bug family, its structural cause in the current architecture, the design element
that removes the *cause* (not the instance), and the open issues it drains.
Markers: ◇`X` = drained only together with the noted stage/arc; issues with no
marker drain at the family's own stage.

| Family | Structural cause (today) | Design element (target) | Open issues drained |
|---|---|---|---|
| A. Bare-name cross-module collision | Identity never acquired at resolve; tables faithfully reflect a pre-collapsed namespace | L2/R: qualified identity substrate; K: identity-keyed environments; registry ratchet | #1047, #1069, #1070 (5 of 7 confirmed + method tables), #1092, #1090 (comment), #733, #756; **the VALUE half** — #1326 ◇A-values, the `export import` residual on #845 — ⚠️ **MEASURED AND DRAINED by #1114/PR #1328**, not pending: it was listed here while its observable was still *predicted from a diff*; it has since been run (`check` 0 · `run` `unknown op '+'` · `build` **0, binary written** · that binary **139, segfault**) and repaired by attributing what a module RE-EXPORTS, at depth 1 and 2, pinned in `run_check_agreement_fixtures/`. **#1337 keeps #1326** and the wildcard read-key question; it no longer has a fails-open member (unit **#1337**; §2 R's correction; §6 Stage A tail) |
| B. Dispatch key under-discriminates | Selection re-derived downstream from keys coarser than instance identity (bare head tycon; per-module `IE` slice; superset word-sets) | S: one `min⊑` selector at `inst`; evidence references stamped; frozen admissibility; K: global `IE`; emitter word-set retirement | #1072, #1071, #1062; #1046 ◇F-1, #1075 ◇F-1 (both reach dispatch through a local lambda — arg-tag survives at their sites until locals carry evidence); #1068 ◇B-2-wasm |
| C. Locals not dict-abstracted | `gen` applied at only two binder kinds; interim pin merges rigid vars | L4/E: uniform `gen` at every binder (#1082, gated on S-2(f)) | #1040, #1043, #1052 (and the #866-interim pin retires; #866/#1045 themselves are CLOSED) |
| D. Impl/default & Flat/Module forks | Two implementations of one judgment kept in sync by hand | L1/E: `MethodBodyKind` merge; one driver, one stamper order | #992, #873-class, #462 ◇E-2, map §7.6 (unfiled → task E-2) |
| E. Supers flattened & re-resolved | No `entailSuper`; evidence is a flat slot list; 4 duplicate closure walks | L4/S: tree evidence, projection rung, one closure combinator | #993, #679, #741; #323 ◇B-1-scope (drains only if the evidence tree extends to *recursive instance-context* capture and both engines consume it — #993 as filed is supers-scoped; B-1's design doc must decide this) |
| F. Effects rules with unreached arms | Row unifier's leniency is per-arm, position-blind; polarity not computed; coverage counts promises as charges | I/G: per-parameter polarity + index invariance; eliminator obligation; collection-domain fix | #1094-class (spec'd), #1098, #1100, #1103, #797 ◇D-1; #1095 ◇graded-arc (if #823 resolves to the uncharged-signature option, the launder stays representable and only the arc closes it) |
| G. Laundering via method schemes | W3 checked with flexible vars in places; carve-out for Async | G: W3 rigid everywhere; #803 bound keeps pre-unify placement | #830 (gen-sig authority), #819 (adjacent); #817 ◇graded-arc, #825 ◇graded-arc (the arc is a peer, not a subtask — these drain there, not here) |
| H. Obligation storage & deferral drift | 2 storage shapes, dead provenance arms, bespoke numlit channel; deferral policy per-channel by accident | I/S: #991 completion; ONE written deferral policy (B-3's scope — **LANDED as DICT-SEMANTICS §4.2 OD1–OD6 + its §11 rows**, #1114); defaulting as specified quiescence step | #991, #563, #564; **#845 and #792 DRAINED (#1114)** — pinned by `run_check_agreement` fixtures, two shapes each. ⚠️ **They are NOT one rule between them**, though a draft of this row said so ("both were D1 violations"): #792 is `DICT §4.2` **OD1** (a channel *discarded* a decidable predicate — one of OD1's four named discard mechanisms), whereas #845 is **OD2/OD6(a)** — no channel discarded anything, the cross-module *store* never held the predicate, which is a missing store rather than a discard. §6 B-3's own summary of the fix says the same thing in the implementation's vocabulary ("adds a store with a key" vs "changes a rollback's predicate"). ⚠️ **#845's mechanism as filed here and in the issue was wrong**, corrected by measurement rather than reading: the discriminator is **declared-vs-inferred context**, not the import spelling. A signed callee's `Num a =>` was already checked through `import m.{f}` before #1114; an *unsignatured* one was dropped through **every** cross-module spelling, because the store the check path read (`funConstraintsRef`, whose inferred half is `dictEligibleSetRef`-gated) holds only declared contexts. Independently, `import m.*` and `import m as A` dropped it for a **signed** callee too — so the real defect was a 2×3 matrix, and a fix matched to the filed spelling would have drained one cell of six |
| I. Order-dependent results the spec forbids | Per-module env slices; promotion discard-and-redo; two stamper orders | L3/K/E: whole-graph env, scheduled marking, one order table — ◇S-2(b) (the commitment-timing rule is what makes the schedule order-free for non-generalized bindings) | #1072 (also B), letrec order (owed spec) |
| J. Coherence condition mismatch | Enforced (a) global comparability vs spec'd (c) per-goal minimum | G: per-goal unique-minimum check at `inst` | #311, #614 |
| K. Registry recurrence risk | Nothing prevents the next bare-name table | Registry ratchet (structural check, all bundles + engine frames) | #1070's "owed gate" |

Hygiene items (#176 ref-growth probe, #480 duplicate loc-helpers) ride along
with the stages that touch their code and are listed in §6 rather than here.

⚠️ **#845 is deliberately SPLIT across families H and A, and reading either row
alone misreports it.** Its filed subject — a cross-module constrained callee not
obligation-checked at its call site — is a deferral-POLICY defect and belongs to
family H / B-3-ext (#1114). Its **re-export residual** is a different mechanism
in the same issue: the store's write key is the *definer* module and its read key
is the module the *importer* spelled, so one `export import` hop misses. That is
family A's keying defect one namespace over from #1283, and no policy rule
decides which binding a local spelling denotes. Family H's cell governs the
first; the ◇A-values marks above govern the second.

**Explicitly NOT in this matrix (engine-realization defects — architecture
cannot drain them, and claiming so would mislead §7's capture-ban logic):**
**#1034** (native-wrong/eval-correct: `methodArgTys` arity over-count in
`core_ir_lower` eta-expanding impls — the over-count is not recoverable from
the type, so no selection/identity work touches it), #826 (same root
distortion), #1101, #1020, and #1043's emitter half. These stay on the
known-wrong-oracle ban list until fixed *in the engine*, independent of any
stage here landing.

**What the matrix does NOT claim.** Nothing here substitutes for the
graded-interfaces arc (#820–#824), which this design *assumes* as the
resolution of family G's carve-out and family F's #1095 and therefore treats
as a peer arc, not a subtask.

---

## 5. Decisions reopened, and decisions deliberately kept

Per the working agreement: default is to keep settled semantics; where the
ground-up ideal disagrees, the reopening is stated with its cost. Three
reopenings; R2 now owns two *language-visible* acceptance changes, both
spec-mandated.

**R1 — Scheduled marking replaces the promotion fixpoint (and the Flat
fallback with it).** *What it challenges:* DRIVER-COLLAPSE-PLAN (status
IMPLEMENTED) and the shape of `elaborateModules`. The plan's invariant — flat ≡
1-module — is a stated invariant with a measured counterexample, so this is
less "reopening a decision" than "finishing one whose completion was
misrecorded." *What is genuinely new* (red-team-corrected): NOT SCC ordering,
per-SCC generalization, or shared rec-dict prefixes — all exist — but (1)
marking per-binding on the schedule after callees generalize, and (2) promotion
facts carried in the environment across modules instead of harvested via a
scratch joint typecheck. *Why:* it makes the fixpoint, harvest-discard,
re-marking, `dropShadowedCore`, and the sticky-error snapshot hack structurally
unnecessary; it turns letrec scheduling from unspecified emergent behavior into
a written rule; it removes the only consumer of `Flat` mode. *Costs to manage:*
the per-module `resetState` lifecycle changes (the 52-survivor discipline must
be re-derived, not assumed); the LSP's post-run scheme-read seam must be
preserved by contract; per-module diagnostic attribution and output ordering
must not move; the schedule must obey S's commitment-timing rule (non-closed
types resolve at quiescence — S-2(b) decides the rule before E-4 implements
it); and the marked-node set must be the full declaration universe (impl/
default/prop/test bodies), not just `DFunDef` groups. This is the highest-risk
element and is staged accordingly (§6, Stage E: consumers → collapse →
defaulting rule → schedule).

**R2 — Spec-mandated semantics changes, enumerated and owned.** The settled
change-control rule ("golden drift from a map-ification means I changed
semantics") stays the default. Two deliberate exceptions, both licensed by
clauses:

- *Instance-selection order-freedom* (#1072, family B): goldens pinning
  order-dependent selection get re-derived from the spec (hand-computed
  winners), justified clause-by-clause in the PR. The red team adjudicated the
  spec question: commit-at-elaboration-site (§6.1.3) governs non-ground goals
  only; #1072's goal is ground at the caller, C4/I2 decide it, and "specific"
  is the spec answer — no prior spec ruling needed.
- *Global-`IE` candidacy* (C4): an impl in a topo-later module of the loaded
  graph becomes usable by an earlier module. This is an acceptance-widening
  visible in the language, not just in goldens; S-2(a) writes the candidacy
  sentence, and A-3's PR carries the could-not-pass-before fixture per §7.

Everything else (coherence conflict report order, first-Loc selection, display
order) stays order-preserving.

**R3 — Two extractions from `typecheck.mdk`, without relitigating the
file-split rejection.** The rejected split was HM-core vs dispatch — state read
at `infer` depth across the 25-arm walk; that verdict stands and this proposal
does not thread records through `infer`. The two extractions here sit *outside*
that coupling, on the map's own dominance evidence: **D** (error-path machinery
— fires only on failure, no inbound dependency from inference) and **K**
(declaration analysis — runs before any body inference; its outputs are
read-only during I/S/E). Both clear the §7.7 seam list: D exports the push/read
interface; K owns what `loader`-adjacent marshalling owns today. If K-as-a-file
proves to fight the build (import cycles, `SMap` layering — the trap that
blocked the Tarjan extraction), K lands as a gateway-owned region of
`typecheck.mdk` instead; the *contract* (whole-graph, identity-keyed, built
once) is the architecture, the file boundary is not.

**Kept, explicitly (do not re-derive):**

- **HM-core/dispatch file split: rejected.** (ARCH-REVIEW PASS 2; map §8.)
- **`pending*` deferred-site channels: essential.** Bundled, never eliminated.
- **`typeErrorsSticky` outside every bundle.** Sound *because* it survives resets.
- **Effect rows transparent in matching** (single-meaning law; EFFECTS §8).
- **Most-specific-wins as specified** — head-only `⊑`, per-goal unique minimum,
  commit-at-elaboration-site (choice-points §6.1 all stand).
- **Module-qualified identity with use-site ambiguity** (not reject-at-decl —
  note this *supersedes* #1070's own priority-1 recommendation, which predates
  the 2026-07-25 decision; A-2 updates the umbrella so no one implements
  reject-at-decl from its text).
- **One elaboration across engines** (single-evaluator law; the two-mode
  emitArgStampPasses class stays dead).
- **Declared kinds replace inference; `Effect` kind; `Deferred*` naming; `defer`
  keyword** (graded arc decisions, 2026-07-26).
- **No user-facing variance annotations** — internal polarity computation only.
- **Graded interfaces arc as designed** (#822 → graded-lite → #823 → #824; #821
  deferred). This design treats `Effect`-kinded slots as invariant positions
  and otherwise takes the arc as given; the D-3/#822 machinery overlap is a
  named coordination point (§8), and D-3 must not outlaw the arc's canonical
  join signature (its `e₂` argument occurrence is justified by the index
  fidelity + eliminator obligation pair, not by call-time coverage).
- **No catchable panics; IO not a monad; lazy top-level nullary; hot helpers
  monomorphic and short-circuiting** (+56% self-compile measured; L5's
  conformance machinery must not delegate hot scans to Foldable).
- **The interpreter stays** — as a refinement consuming the one elaboration.
  Retiring it is an owner-only decision this proposal does not need.

---

## 6. The migration DAG

**Tracking: epic #1122** (stage table with all issue links). Six stages. Every
task is a mergeable PR series with `main` green throughout. ⊕ marks tasks
*already filed* and adopted (re-scoped where noted) rather than duplicated;
tasks filed by this arc carry their numbers inline (S-2 #1107 · S-3 #1108 ·
A-1a #1109 WITHDRAWN, folded into A-1 · A-1 #1110 · A-2 #1111 · A-3 #1112 ·
B-2 #1113 · B-3-ext #1114 · E-1 #1115 · E-2 #1116 · E-4 #1117 · D-1 #1118 ·
D-2 #1119 · F-2 #1120; the review-found contravariant-row S0 is #1121).
Verification bars per task follow §7's doctrine; compiler-source
tasks all carry the standing bar (snapshot + selfproc-legA blessing, fixpoint
C3a/C3b, `typecheck_compiler_source`).

**Landing is serialized; development is parallel.** Every stage below edits
`typecheck.mdk`, whose goldens are re-cut from source and never text-merged —
one compiler-source PR in flight is the repo rule, and it binds this arc too.
"Parallel lanes" (B-3/C/D alongside A) means independent *worktrees and
review*, interleaved *landing* — the DAG orders dependencies, the merge queue
orders merges, and the plan does not pretend otherwise.

**Stage S — Spec & conformance substrate (no compiler changes; unblocks everything)**

- **S-1 ⊕ (#616, re-scoped). Conformance suite scaffolding.** A clause-indexed
  fixture corpus for DICT/EFFECTS/SHADOW: each fixture names its clause, states
  its expected value *and how it was derived* (by hand from the rule), and is
  wired either as a passing gate or a `must_fail` pin when the engine is
  known-wrong. Starts from the existing shadow matrix gate (the model) and the
  `run_check_agreement` family. **Includes CI wiring as an explicit subtask**:
  a gate absent from `test/gates.toml` silently never runs, and shard placement
  is not a choice at all: since #2178 `shard` is derived from measured cost by
  `medaka gate balance`. Enrol the gate; the balancer places it.
- **S-2. Owed spec paragraphs.** (a) Cross-module identity of types / aliases /
  records / interfaces / methods (DICT §8 I-series extension — the decided
  Haskell/Rust model, the use-site ambiguity rule, **and the C4 candidacy
  sentence**: instance candidacy is graph-global, import scoping filters name
  visibility only); (b) letrec/SCC scheduling **and the commitment-timing
  rule** (what a later group may observe; where `inst` and defaulting may
  commit relative to quiescence for non-generalized bindings); (c)
  numeric-literal defaulting (placement relative to obligation checking, taint
  rules, level discipline per #564); (d) impl completeness / phantom-method
  rejection; (e) driver unimodality (retiring DRIVER-COLLAPSE's stale
  IMPLEMENTED claim); **(f) local-binder `gen`** (predicate deferral across
  nested binders, the value-restriction gate, evaluation-timing neutrality) —
  F-1's gate. Each lands with its enforcement-table row (L5).

  ✅ **LANDED 2026-07-30 (#1107): all six, in `docs/spec/DICT-SEMANTICS.md`** —
  (a) **§8 I4/I5**, (b) **§6.2**, (c) **§6.3**, (d) **§5.1**, (e) **§7.1**,
  (f) **§4.1**, each with a §11 row. Three of them settle a question this document
  left open or stated loosely, and the differences bind:
  - **§6.2 T4/T5 adopt quiescence and explicitly REJECT freeze-at-module-close**,
    the choice §2 S delegated here. But T3/T4's row records that today's drain is
    keyed on the **module** boundary (`elabModuleStamp`) while the tyvar cells
    outlive it — so quiescence *extends* today's behaviour rather than describing
    it, and §2 S's parenthetical *"matching today's whole-module-then-stamp
    behavior"* must be read as *extends*, not *describes*. **E-4's S-2(b) gate is
    lifted.**
  - **§8 I5's consequences of global candidacy are NOT one, and the list is derived
    rather than enumerated** — a new candidate can change the outcome at whether a
    `⊑`-minimum exists, at which instance it is, and at whether that instance's own
    context is dischargeable. §5 R2 sees only the acceptance widening (1). The others
    are (2) **new C1 ambiguity rejections**, where a newly-visible `⊑`-incomparable
    instance destroys a minimum a smaller candidate set had; (3) **silent answer
    changes**, where a newly-visible instance is strictly more specific than the
    previous winner; and (4) **new rejections with C1 fully satisfied**, where the
    newly-visible instance wins uncontested but its own `requires` context is
    unsatisfiable and `inst` does not backtrack — an error naming an interface the
    author never wrote, from a module they never imported. A-3's
    could-not-pass-before fixture covers (1) only; (2), (3) and (4) each need their
    own accounting in that PR, and (4) is the one with the worst diagnostic.
  - **⚠️ Sequencing: E-4 (T4) must not land before A-3 (I5)** — §6.2 T4 now says so
    normatively. Deferring commitment while candidacy is still the topological prefix
    puts two candidate sets in one program (closed goals see the prefix at their
    group's end, deferred goals see the whole accumulation), which is a C3/C4
    violation the deferral itself creates. The DAG already orders A before E; this is
    the semantic reason, not just a dependency.
  - **§5.1 M3 decides (d) in the direction that NARROWS THE CHECKER**, so #1134 is a
    fix: `test/dict_fixtures/s5-phantom-determined-use-rejected.mdk` goes red on the
    fix and re-pins to ACCEPT `7`, and the "relabel by hand" contingency in both
    phantom fixtures' headers does not apply.
  - **One K-relevant relocation**: §5.1 **M2** (an impl may not define a method the
    interface does not declare) is enforced **at resolve**, not typecheck —
    `checkMethodMember` → `MethodNotInInterface` / `R-METHOD-NOT-IN-INTERFACE`, with
    `inferImplMethod`'s own arm inert. §2 K lists impl completeness among the checks
    that move to declaration-time analysis; this half of it already lives upstream of
    typecheck, and A-3 should relocate it deliberately rather than discover it. (This
    row was first recorded here as "no implementing site" — wrong, and corrected: the
    search was scoped to `typecheck.mdk` and the check lives one stage earlier. §11's
    preamble now carries that lesson.)

  **F-1's S-2(f) gate is lifted**, with one constraint added: §4.1 **G4** forbids the
  interim pin's shape by name — an implementation that cannot dict-abstract a local
  must **reject** the multi-type use, never monomorphise (#1052).
- **S-3. Enforcement tables for DICT and EFFECTS** (clause → site → keying
  assumption), SHADOW-§3-style, added to the specs and gated by the doc gates.
  The map's §4 spec column is the seed.

**Stage A — Identity substrate (family A) — the widest-blast, highest-value stage**

- **A-1a. WITHDRAWN — #1109 closed by this change.** The task as filed
  proposed deciding the identity-representation question ("intern table" vs
  `String`-encoded qualified keys) by an interleaved-A/B wall-clock
  measurement on the self-compile. A read-only scoping pass found the
  measurement rests on a factual error, independently re-verified: the
  premise that a composite key newly introduces dict-passed comparison in
  the hottest lookups is false — `stdlib/map.mdk`'s `get` is already
  constrained on `Ord k`, and `compiler/support/ordmap.mdk`'s `omLookup` is
  a monomorphic wrapper over that same constrained `get` with no
  specialization pass in between (see the corrected §2 bullet above). Two
  more facts sink the measurement rather than merely delaying it: its
  harness (`test/bench.sh`) is macOS-only and exits 2 without measuring
  anything on this project's Linux dev box (#1187), and the workload is far
  too small for a constant-factor comparison-cost effect to clear noise
  inside a GC-bound stage even where the harness runs. **A probe whose two
  arms cannot differ in the dimension it claims to measure reads exactly
  like a real measurement** — that is why this is a withdrawal, not a
  re-schedule.

  The representation is instead **decided in writing, inside A-1**, on L2
  (identity resolved once, never re-derived from spelling) grounds, plus
  registry-ratchet enforceability (§2's "Registry discipline" bullet),
  rather than by measurement. (L4 — evidence uniformity at every binder,
  the local-`let`/`where` dict-abstraction gap, #1082's bug class — is a
  real law in this document but not a relevant one here: it is about
  *whether* a binder abstracts a dictionary parameter, not about how an
  identity key is represented, so it is dropped from this decision's
  grounds rather than stretched to cover it.) A-1's own PR answers the
  standing questions in `.claude/workstreams/TYPECHECK.md` as part of
  making that decision, weighing the §2 bullet's three considerations —
  source safety, then L2 enforceability, then allocation — in that order.

  The tree already ships a **third candidate this document did not list**:
  `compiler/types/typecheck.mdk`'s cross-module qualified tables
  (`crossModuleFunConstraintsQualRef` and siblings) are keyed by
  `(String, String)` — module and name — and read by `lookupQualArity`, a
  hand-written monomorphic comparator with no dict at all. This is exactly
  the `(module, name)` keying #1070's own remedy prescribes, and it is
  already load-bearing in-tree. Its one caveat: a **tuple** key does pick up
  a nested dict-passed comparison via `stdlib/core.mdk`'s
  `impl Ord (a, b) requires Ord a, Ord b` — the one place the withdrawn
  bullet's "composite key means dict-passed comparisons" claim was true, and
  it is true of the candidate the doc never named, not of either candidate
  it did. **It does not restore L2's `"unwritable"` guarantee either** — a
  `(String, String)` pair is exactly as forgeable by hand as one encoded
  `String`; the type system stops neither. What it does avoid, *as
  currently shipped*, is the §2 printer/source-safety disqualifier: those
  tuples key cross-module constraint TABLES, not `TCon`'s own payload, so
  they are never rendered by `printType`. That distinction would not survive
  reusing the same string-pair encoding to represent `TCon` identity itself
  — an open question this bullet deliberately does not resolve (see A-1's
  TCon-fold note below).

  The interleaved wall-clock A/B is **retained as the intended landing bar**
  on A-1 and A-2 (§7/§8 already assign this bar to those stages; see below)
  — but it is **currently blocked on a working instrument**: the only
  harness for it, `test/bench.sh`, is the same one this withdrawal already
  established does not run on this project's Linux dev box (#1187). A bar
  whose instrument does not run is not a bar yet; A-1/A-2 cannot claim to
  have cleared it until #1187 lands a working harness, and any future use of
  it here must additionally carry a stated positive control and a stated
  minimum detectable effect, per the general rule that an A/B whose arms
  cannot disagree is not evidence.
- **A-1. Resolve-acquired qualified identity.** *Creating* resolve-phase
  namespace resolution (not extending — resolve only existence-checks type
  names today) and relocating identity minting out of mid-typecheck
  (`stampBindingIds`). AST carries origin via **named-field records**; the
  structural dumps and printer **strip identity fields the way `ELoc` is
  stripped** — the stated invariant that makes the first PR series
  byte-identical; use-site ambiguity diagnostics (R-series codes). The
  selfproc-legA "additive-only" recapture rule is explicitly waived per-PR
  with justification where existing bindings' rendered schemes change.
  **Folded in from the withdrawn A-1a: identity must reach `Mono`/`TCon`,
  not stop at the AST decl layer.** ✅ **Landed as A-1 unit D (#1110):**
  `compiler/types/typecheck.mdk`'s `Mono` declares `TCon String
  TyConOrigin`, minted through four named helpers that
  `test/typecheck_compiler_source.sh` pins as the only construction sites.
  Carrier only — no comparison reads the field yet. The paragraph below
  described the pre-unit-D state (`a bare TCon String arm`) and is kept
  because its *bounding* argument is unaffected: #1070's own remedy states
  a shared
  `(module, name)` keying helper is insufficient for five of its seven rows
  (`universeDataParamKinds`, `universeIfaceParamKinds`, `universeAliasTable`,
  `universeRecordByName`, `universeDataEnv`) — but #1070's own "precisely
  because those read sites only ever hold a bare head-tycon string" reasoning
  is **wrong for at least three of the five**, not one, and all three wrong
  ones land outside `TCon`'s own identity space:
  - `universeIfaceParamKinds` is not read off a head tycon at all (⚠️ **and it no
    longer exists — A-3.5c/#1557 retired the row, its `perRun` half and its writer;
    the content is `CE`'s `ceRowParamKinds`**): its key was built from an interface
    name and a slot index, and its one read site, `checkGradedImplTys`,
    was called as `checkGradedImplTys iface 0 tys` from
    `checkGradedImplHeadDecl (DImpl { iface, tys, ... })`
    (`typecheck.mdk:1332-1333`) — an **interface name** off a `DImpl`, not a
    `TCon`. The code's own neighboring comment already says so: re-keying it
    properly "would need a resolved module identity, and typecheck.mdk
    carries none for an interface... That is #1047's territory, upstream of
    #822" (`typecheck.mdk:1354-1356`).
  - `universeDataEnv` is a `Ref TcEnv` (`typecheck.mdk:2549`), and `TcEnv`'s
    own comment names its second field `ctors` (`typecheck.mdk:4558`):
    `addVariants` inserts every constructor via `addCtor env cname (...)`
    keyed on `cname`, the **variant's own constructor name**
    (`typecheck.mdk:8634-8636`, `4592-4593`), and its one read site,
    `inferPatCon`, is driven straight off a match pattern's written
    constructor name (`inferPat env (PCon name pats) = inferPatCon env name
    pats`, `typecheck.mdk:4615/4685-4686`) — never a head tycon, and never
    `TCon` either. Constructor names are their own namespace, distinct from
    type names: `data Cfg = MkCfg { … }` collides on `MkCfg`, not `Cfg`.
  - `universeRecordByName` is likewise not read off a head tycon in
    general: `registerRecordInfoKeyed`'s own comment says "for a record
    [key and type name] coincide, but a named-field data variant is keyed
    by its constructor" (`typecheck.mdk:8332-8334`), and its sole call
    site passes the **constructor** name as the key —
    `registerRecordInfoKeyed cname tyName params fields`
    (`typecheck.mdk:8614`, via `registerNamedFieldVariants`). Its read
    sites are driven by a written constructor name too: `inferPatRec`
    (`typecheck.mdk:4634`), `inferRecordCreate` (`typecheck.mdk:5528`),
    `inferVariantUpdate` (`typecheck.mdk:5839`). The one shape where key
    and type name coincide is the record short form (`data X = { … }`),
    where the parser mints the variant's constructor as the type's own
    name (`Variant tyName (ConNamed fields True)`, `parser.mdk:3029`) — so
    `TCon` identity drains this row only for that shape, not in general.

  That correction **bounds what this fold actually buys**: `TCon` identity
  is TYPE-name identity, so folding it into A-1 drains `universeAliasTable`
  and `universeDataParamKinds` outright, plus `universeRecordByName` only
  for the record short form (where its constructor-keyed entries coincide
  with the type name) — hence #1069 and #1090 — but it does **not** address
  `universeIfaceParamKinds` (needs interface-name identity, #1047's
  territory), does **not** address the separate `methodIfaceParamsRef`
  collision (needs method-name identity, #1092), and does **not** address
  `universeDataEnv` or the non-short-form entries of `universeRecordByName`
  (both need constructor-name identity — a third namespace again distinct
  from both interface-name and method-name; #1070 itself names no
  standalone issue for either row beyond its own S1 writeup, so this gap is
  currently tracked only inside #1070). Folding `TCon` re-typing into A-1
  is necessary for A-2 to close **two of #1070's five cited rows outright,
  plus the record short form of a third**, not all of it; the
  interface-name, method-name, and constructor-name identity gaps are real
  and are **not** resolved by this decision. Whether any of them land
  inside A-1/A-2's scope or a later stage is itself part of what is owed to
  the scoping pass below, not decided here.

  Landing identity at the AST decl layer alone would still leave A-2
  re-keying tables whose read sites collapse to bare-`TCon` collisions on
  the type-name rows, which is not a fix for those two (nor, beyond the
  record short form, the third). **This bullet records the decision to
  fold `TCon` re-typing into A-1's scope, not a mechanism or a PR
  staging** — a scoping pass on exactly that question is running in
  parallel and has not concluded; the mechanism and how it splits across
  A-1's PR series (and whether it also covers the interface-name /
  method-name / constructor-name gaps) are owed to that pass.
  *Collision surface: parser, `resolve.mdk`, `ast.mdk`, printer/fmt, sexp,
  every golden family; the single biggest golden move of the arc.*
- **A-2. Identity-keyed environments + registry ratchet.** Re-key the surviving
  `universe*`/method/record/kind tables; land the write-once-or-diagnose
  registry abstraction; structural check over all bundles. **Updates #1070's
  body**: its priority-1 remedy (reject-at-decl) is superseded by the decided
  use-site-ambiguity model. *Drains #1047/#1069/#1092/#1090; #1070 umbrella
  closes when its audit rows are all drained or reclassified.*

  ⚠️ **STATUS (2026-08-26, sprint `stage-a-closeout`, `S-stage-a-ledger`):
  #1047/#1069/#1092/#1090 are all CLOSED.** #1070 itself stays OPEN — its
  umbrella still carries live rows (`universeMethodIfaceParamsRef` → #1276,
  the constructor rows → #1319, `universeMethodDispatchIdxRef`/
  `universeIfaceMethodsRef` → #1354/#1351/#1353) not drained by this sprint.
  This sprint's own drains (#1150, #1675, #1427) are a different mechanism
  family (value-restriction misclassification, ambiguous-reexport resolution,
  scheme-environment alias routing respectively) and do not correspond to any
  row in #1070's audit table — cite 24, not 25, for `cross_allowed`'s current
  row count (PR #2012 independently removed `universeRegisteredIfacesRef` on
  `main`). **#1111 therefore does NOT close yet** (its own closure text
  requires #1070's rows all drained/reclassified, which they are not).
- **A-values #1337 (A-2 tail). Cross-module identity for the VALUE namespace — a
  SCOPING PASS, not an implementation plan.** Added 2026-08-05 with §2 R's
  correction: values were the one namespace this document exempted from Stage A,
  and the exemption was wrong. Peer of **#1319** (the constructor namespace,
  filed the same day, likewise an A-2 follow-on); with #1280/#1317 (types and
  the dispatch-key demand half) the two complete **the four-namespace set**.

  **The pass's question, stated so it can be answered wrong:** *what makes a
  value occurrence denote a `(module, name)` rather than a spelling, and which
  read sites must consume it?* Members on the table at scoping: **#1326** (fails
  closed — false reject) and the **`export import` residual on #845** (fails
  open — dropped obligation). One un-keyed name-resolution seam producing a
  false positive in one direction and a false negative in the other is the
  argument for one unit rather than two patches; the pass's first job is to
  confirm or refute it.

  ⚠️ **UPDATE (#1114 / PR #1328): the fails-OPEN member is drained, and that is
  evidence bearing on the one-seam hypothesis rather than merely a smaller
  membership.** Its observable was recorded here as *predicted, not measured*; it
  has now been measured and repaired — and repaired **without any occurrence →
  module resolution work**, purely by making the *write* side's notion of what a
  module contributes match the language's (declares ∪ re-exports), reusing the
  import side's own spelling table. No new AST carrier, no change at the read
  site. So the pass's question 1 is answered **for that member**, in the
  negative, and the two members are not obviously one seam after all. **#1326 is
  untouched and still reproduces** (re-confirmed with #1328's own lookup ablated
  and with both bindings signatured), as does the wildcard read-key question —
  `importDefinersOf` is still built from import syntax only, and every other
  consumer of `currentImportDefinersRef` still has that blind spot.

  ⚠️ **UPDATE 2 (Val, 2026-08-09): #1326's FIX no longer lives here — it was
  re-homed to #1425**, which owns the issue plus all three coupled sites. PR
  #1424 implemented the provenance filter and it worked (the repro flips to exit
  0, order-independently, with a 36-cell over-widening matrix showing four
  changed cells, all improvements) — but removing the bad attribution rows
  removed the compensation two OTHER laundering sites in the same seam were
  leaning on, and two gates went red including the `§8 I1` conformance pin for
  the very clause the fix implements. PR #1424 was narrowed to its re-export arm
  (draining #1369) and the rest went to #1425. **#1326 stays OPEN and its
  must-fail fixture stays pinned.**

  ⚠️ **UPDATE 3 (structured-predicate-carry sprint, #1948): #1326 is now
  DRAINED — this "stays OPEN" verdict is stale.** See the UPDATE at :190-201
  above for the measurement (`docs/spec/DICT-SEMANTICS.md`'s §4.2 OD6 row,
  both import orderings, `check`/`run`/`build` all exit 0 printing `ok / 5`,
  regression-guarded by `test/import_order_fixtures/1326-samename-sibling-
  constraint-misattributed-import-order/`). Its GitHub issue remains open for
  bookkeeping only. This paragraph is left standing, unedited otherwise, as the
  historical record of the #1425 route that fixed it — do not read "stays
  OPEN" below this UPDATE as current.

  ⇒ **Membership as it actually stands, since both original members have moved:**
  the fails-OPEN member (`export import` residual on **#845**, now CLOSED) is
  drained; the fails-CLOSED member (**#1326**, fixed via **#1425**) is now also
  DRAINED (UPDATE 3 above). What is
  left to this unit is the *question*, not the two patches — and #1337 is
  flagged on the epic as a **shell**: a scoping pass whose members have been
  re-homed out from under it. **Do not read #1337 as an implementable unit
  without re-scoping it first.**

  **Deliberately open — do NOT pre-decide** (per the epic's 2026-08-05
  instrument note, *"stop pre-clustering residuals into guessed units; scoping
  passes partition them"*; the epic's own ledger records A-2's plan errors as
  *"carriers predicted necessary weren't; a false dependency; defect scopes too
  narrow"* — every prediction wrong in the same direction):
  - whether a **new AST carrier** on value occurrences is needed at all, or the
    resolution already reachable at the read site suffices;
  - whether the remedy is a **keying** change (the tables ask for the wrong key)
    or a **supply** change (nothing supplies an identity to key on) — types
    needed both, split across #1280 and #1317;
  - whether **#1326's live read site is one place or two.** ⚠️ This is an
    *unresolved inference*, not a finding. Two candidates are named on the
    issue: (1) `lookupSchemeObls x 0` degrading to `lookupSchemeOblsByName`, a
    bare-name first-match scan (`compiler/types/typecheck.mdk:7228-7241`) taken
    for cross-module occurrences because they carry no binder id; (2) the
    promotion fixpoint's scratch joint typecheck, in which two modules' `h`
    become two top-level `h`s in one program — this document's own
    "bare-name shadow collisions in the joint program" (§2 E). The *class*
    verdict is stable across both, which is why the unit can be scoped before
    the settling experiment; **one instrumented build settling which route
    records the predicate is owed work, and E-4 is not a substitute** (it
    retires route (2) by construction, but per-run integer binder ids do not
    become `(module, name)` because the flatten went away).

  **Dependency on A-3 (#1112), derived rather than assumed: independent — this
  unit neither precedes nor follows it.** A-3 supplies **no part** of value
  identity, because none of its three environments holds a value binding: CE is
  interfaces / method schemes / supers, IE is impls, DataEnv is datatypes /
  constructor schemes / records / aliases (§2 K, and #1112's own body). A
  binding's scheme and its deferred predicate set live in the obligation and
  scheme stores — §3's L4 row homes those in I/S, i.e. B-3's storage, not K's.
  Nor does A-3 *consume* value identity: what it keys on is type-head identity
  (#1280/#1317's supply) and, for its ctor rows, constructor identity (#1319).
  **The #1280-before-A-3 argument therefore does not transfer**: that ordering
  exists because A-3's environments *are* keyed by type-head identity, so
  building them under the transitional absence rule would bake it into the new
  substrate — there is no value-keyed environment in K for this unit's absence
  to be baked into. *The one thing that would overturn this verdict, stated so
  it is checkable: if a scoping pass grows K to include a whole-graph **value**
  environment (a global scheme environment), A-3 becomes a consumer and the
  ordering must be re-derived. Neither §2 K nor #1112 proposes one today.*

  *Otherwise unblocked and off the spine, exactly like #1319 — name identity,
  not origin supply. Serialize only on the one-typecheck.mdk-PR-in-flight rule.
  Severity-direction warning, kept as historical record (⚠️ #1326 itself is now
  DRAINED per UPDATE 3 above — this is no longer live prescriptive guidance for
  #1326, only the general methodological point): #1326 was an over-rejection,
  and the tempting local fixes (widen the import-definer test; suppress the
  bare-name fallback) would have converted a false reject into a dropped obligation
  — loud → silent, a severity increase, and untestable from the diff by
  construction since every existing fixture for this channel covered the
  rejecting case. The fix that actually landed avoided that trap.*

  ⚠️ **UPDATE 4 (2026-08-26, sprint `stage-a-closeout`, `S-stage-a-ledger`):
  #1337 STAYS OPEN, confirmed against its own current retirement condition**
  (its 2026-08-12 re-scope: drains only when BOTH #1425/U2's `UseWild`/
  `UseAlias` read-key arms land AND the #1427/#1472 scheme-environment unit
  lands). #1427 CLOSED this sprint (the build panic was fixed pre-sprint by
  PR #1671, not by this sprint's slice 4 — see #1427's correction comment);
  #1425 is unchanged, still fully OPEN. So one of #1337's two conjuncts is
  met and the other is not — it stays open. A status comment to this effect
  was posted on #1337 directly this sprint; not re-quoted here.

- **A-ctors #1319 (A-2 tail, peer of A-values above).** RE-CUT 2026-08-26
  (sprint `stage-a-closeout`, comment on #1319 + `S-stage-a-ledger`'s own
  ledger comment): its four originally-filed members #1283/#1284/#1376/#1377
  are all CLOSED, and the table-keying half of its scope (`universeDataEnv`'s
  ctor entries, `universeRecordByName`'s non-short-form entries) is routed to
  **#1593's re-cut, #2007** (the elaborated-trio unit), not owned here
  anymore — running both units on the same tables from opposite ends was the
  risk the re-cut heads off. #1319's surviving, still-OPEN scope is exactly
  three issues: **#1373** (S1, named-field variant through `export import`),
  **#1292** (S0, `ctorToTypeRef` runtime-tag collision, engine-side), and
  **#733** (re-repro the #674 overlay residuals under the landed A-2.6
  overlay — currently labelled `verified`/`S1: loud breakage`, **not**
  `needs-repro` as its own stale title and a same-day #1319 comment both
  still say; the label history shows the reclassification happened
  2026-08-05, three weeks before this note).
- **A-3. Whole-graph declaration analysis (K) — honest scope.** Build
  CE/IE/DataEnv once; the **Module path** reads K; the Flat fallback keeps a
  marshalling **shim** (the retirement of the universe-marshalling cells —
  see §2 K above for how to derive their count rather than trust a bare
  number — completes at E-4, whose path is the marshalling's only remaining
  consumer — teaching the fallback to read K would mean editing the 20 mode
  branches E-2 deletes anyway). Impl
  completeness + kind checks move to declaration time. ⚠️ **"coordinate with #822,
  which owns the kind machinery — one of the two arcs rewrites it, not both" stood
  here and is now a STALE PREMISE: #822 CLOSED 2026-07-25**, so A-3 takes the kind
  machinery. The kind half landed at **A-3.5c** (#1557); completeness is A-3.5a.
  Error-*ordering* golden drift is enumerated per family (this stage is
  explicitly not byte-identical). Carries the global-candidacy
  could-not-pass-before fixture (R2). *Depends on A-1/A-2; serialize against
  every other typecheck PR.*
  📐 **A-3 is split into A-3a (`CE`+`DataEnv`) and A-3b (`IE`) and decomposed
  into seven units with fixed edges `3.1 → {3.2,3.3,3.4} → 3.5 → 3.6 → 3.7` —
  read #1112's split header and its 2026-08-08 scoping comment before starting
  any of them.** A-3.1 (the ordinal-filtered envelope) has landed;
  **A-3.4's own unit design is §9 of this document**.

  ⚠️ **STATUS (2026-08-26, sprint `stage-a-closeout`): #1112 STAYS OPEN.**
  The sprint's slice 1 (`S-elaborated-trio`, #1593) ran as a SPIKE-FIRST and
  took branch (b) — filed a re-cut (**#2007**, the identity-keyed elaboration
  cache for the `universeRecordByName`/`universeDataEnv`/`universeCtorIdentsRef`
  trio) rather than implementing a rewrite this sprint. Branch (a) did not
  happen, so #1112 does not close on this sprint's work — confirmed against
  #1112's own body, which the sprint left open, with a status comment posted
  explaining the branch-(b) outcome.

**Stage B — One selection discipline (families B, E, H)**

- **B-1 ⊕ (#993). Evidence tree + `entailSuper`** — as filed: distinguished
  `supers`, one closure combinator, `expandSupersTable` + census twins retired.
  **Scope decision owed in its design doc:** whether the tree extends to
  *recursive instance-context* capture at nesting depth ≥2 (what #323 needs) or
  stays supers-scoped as filed — say which, so #323's drain claim is honest.
  Blast: `Value` rep in eval, `Route`, both emitters, dict-arity readers —
  design-first, staged, adversarial bar (its own text already says so).
- **B-2. Identity-stamped evidence + frozen admissibility.** The full
  commit-point formulation of §2 S: evidence references
  (`InstId`/`DictParam`/`SupersPath`) in routes; identity stamped where `inst`
  runs; dict words carry construction-site identity; per-(class, position)
  arg-tag admissibility computed post-K, frozen, consumed by every engine.
  **Blast list (this is emphatically not typecheck-only):** typecheck stamp
  side (`keyForSite*`, `KeyBuckets` slices), the LLVM emitter's
  `implEntryRouteWords` superset-OR retirement + `noneHeadTag` catch-all
  re-key + the disjoint default-tag word namespace, `wasm_emit`'s peer arm
  (#1068's leg — **coordination note: #1068's filed fix direction would build
  in wasm the superset arm this task deletes; do them together, not
  sequentially**), `eval.mdk`'s mirrored dispatch, `Route`/`core_ir_lower`,
  and the IR-text golden (`diff_compiler_llvm_typed_ir`). Changes the
  compiler's own emitted IR ⇒ **seed re-mint discipline** (refresh twice; a
  stale seed can SEGFAULT the fixpoint on a correct change). *Depends on
  Stage A: pre-A "canonical keys" are bare-name-composed strings that #1047
  makes collide — identity-stamping built before A under-discriminates with
  keys that merely look unique.* *Drains #1072/#1071/#1062; #1046/#1075
  complete at F-1.*

  🚨 **Correction — the commit-point formulation above is OVERTAKEN. B-2 did not
  deliver "C4/I2 by construction"; it delivered CONJUNCT 2 ONLY.** The standing
  ruling is the owner's own third measurement (#1113's closing comment; Phase
  4/4b close-out relocated to #1659):
  > **"C4/I2 holds as CONJUNCT 2 ONLY … Evidence is order-invariant; the
  > instance consulted is not."**
  >
  > Identity landed in the **word**, not in the **key**.
  >
  **Three live failing shapes name the gap, all still OPEN:** **#1182** (two
  interfaces declaring the same method name — `impl` block order decides which
  runs), **#1620** (the same collision inside ONE file), **#1619** (a
  cross-module interface default silently hijacked by a same-spelled interface).
  Phase 4b — the `keyForSite` selector re-key — is **deferred and owned by
  #1182**, and `implEntryRouteWords`' superset-OR is **still live** in
  `compiler/backend/llvm_emit.mdk`.

  **Conjunct 1 is therefore still unmet and is the head of the remaining spine**
  (`#1351 ∧ #1450 → #1182`, per the 2026-08-17 re-derivation on epic #1122),
  carried by sprint **selector-identity (#1832)**, whose §8 exit criterion is
  explicitly *"C4/I2 conjunct 1 asked a FIFTH time, and measured, not
  asserted"*. ⚠️ **Read every "B-2 landed" marker in this document as conjunct 2
  only.** A planner who reads B-2 as having settled dispatch identity will scope
  #1832's work as already done — which is the exact misrouting this row's
  staleness caused before (#1660).
- **B-3 ⊕ (#991, #994) + the deferral policy.** Obligation storage completion
  and lockstep-pair fusion — mechanical, byte-identical bars, independent of
  Stage A. **Scope extension:** one *written* obligation-deferral policy
  (which channels defer non-ground obligations, and why check and build must
  agree), because #845 (selective-import spelling never reaches the
  declared-obligation channel) and #792 (accepted at check, rejected at build)
  are deferral-*policy* defects that storage unification alone does not drain.
- **B-4 ⊕ (#1318). A dict slot is a PREDICATE** — routed in-arc 2026-08-17 (the
  #1661 routing rulings; this row was previously owned by no stage): slot
  cardinality and payload follow the predicate, with the full argument vector
  carried to route selection and the obligation channel (the
  #1161-residual/#1177/#1169 class). **Hard-sequenced before or with E-5
  (#1137), never after** — centralizing arity first would freeze the wrong slot
  cardinality into the elaboration contract (the coupling both issues state).
  Also on the emitter arc's X-C path (#1402 sits behind #1318 → #1137). Not
  byte-identical; moves emitted dict-param arity ⇒ seed re-mint discipline and
  the adversarial bar, per the issue.
  **✅ LANDED 2026-08-23** (sprint predicate-slots, PR #1862; #1318/#1177/#1154
  and #1161's unsatisfiable leg closed): slot identity = (interface, full
  argument vector) on the signatured, single-module path; emitted dict-param
  arity moved lockstep across eval/native/wasm. The review round measured four
  places the identity does not yet reach — same-interface slot collapse
  (#1866), cross-module (#1867/#1868), inferred bindings (#1869) — owned by
  **B-4.2 ⊕ (#1871)**, which inherits this row's before-or-with-E-5 coupling:
  the 2026-08-23 desk-note on #1137 records the arity rule B-4 froze AND names
  #1866 as the one shape where that rule is false in the compiler today, so
  E-5 must adjudicate #1866 explicitly before its cardinality freezes.

**Stage C — One method-body judgment**

- **C-1 ⊕ (#992). `MethodBodyKind` merge** — as filed, two-unify retained as a
  kind parameter, module-placement probes both ways.
- **C-2 ⊕ (#830). Signature authority** — more-general-than-body ⇒ def-site
  reject (never silent narrowing); vector-valued entailment side condition per
  DICT §9.
- **C-3 ⊕ (#1136). W3-inst instance-head fidelity** — routed in-arc 2026-08-17
  (the #1661 routing rulings) as C-2's sibling in the same
  declaration-is-authority bucket: every impl-head type variable must survive
  the checking of every method body of that impl unconstrained, else reject at
  the impl declaration (#819's class; extends `checkMethodRigidityCore` keyed
  on the head vars). Its spec paragraph joins the S-2 (#1107) owed set.

**Stage D — Effects soundness (family F) — independent of A/B; interleaves with the graded arc**

- **D-1. Index invariance + row-arm fixes**: the invariant index arm
  (#1094-class as spec'd in EFFECTS §6.7), same-tail prefix check (#1103),
  `rowArgOf` catch-all kind error, and the two named boundary cases (grade-join
  positions route to subsumption when #821 lands; alias positions take
  post-expansion kinds). #797 rides this unifier work.
- **D-2. Per-parameter polarity computation** — covariant/contravariant/mixed
  from field occurrences, propagated transitively through nominal types;
  contravariant-or-mixed ⇒ invariant row treatment. Write channels (#1098) are
  the special case; the **contravariant immutable-datatype channel**
  (`data Taker a = MkTaker (a -> Int)` — found by this design's adversarial
  review, reproduced on both engines, filed as **#1121**, pin owed) is the
  general case the write-channel proxy misses. `List` control stays accepted.
- **D-3. Coverage/charge separation** (#1095 ◇graded-arc): result-index
  occurrences never discharge argument coverage; abstract-head row-kinded
  arguments are *collected* at all (#1100); the eliminator obligation for
  interface methods per EFFECTS §6.7. **Must not outlaw the graded join
  signature** — its argument-side `e₂` is justified by index fidelity (D-1) +
  the eliminator obligation, which is the replacement rule the graded arc
  supplies. Coordinates with #822/#823; if #823 resolves the eager-arm fork to
  the uncharged signature, the launder remains representable and the arc — not
  this stage — closes it. **Fork resolved 2026-08-17 (Val, recorded on #823):
  DEFER the arm — the uncharged-signature conditional above no longer arises,
  and D-3 + #823 run as one coordinated sprint (§8).**
- **D-4 ⊕ (#995). Effect-walk convergence** — post-unify checks only; the #803
  pre-unification bound explicitly stays where it is (its exactness is its
  timing); rigid-skolem idealization stays blocked on #817/#820 as filed.

**Stage E — One driver (family D/I) — after A-3; the riskiest stage, now four moves**

- **E-1. Flat-consumer migration. ⚡ RE-CUT / effectively closed 2026-08-27
  (sprint `flat-exit-floor`, slice `S-e2-entry-ledger`) — see #1115 for the
  closing comment and `test/CHECK-WRAPPER-CALLERS.txt` for the DERIVED,
  gate-enforced consumer set (never trust a count in this row; re-derive via
  `sh test/run_gates.sh 'diff_compiler_check_wrapper_callers*'`).** The
  Flat-vs-Module divergences were enumerated as a set from the 22 real `match
  mode` branches (23 grep hits, one a header comment) — six named classes plus
  a seventh, `populateEffectDomains` ("BREAK #3" per the source's own
  vocabulary), judged inert for one/few-module comparisons — each behavioral
  class getting a fixture in `test/diff_compiler_flat_vs_onemodule.sh` before
  any consumer moved. **Migrated onto the Module arm** (`checkOneScheme`/
  `checkOneDiags`/`checkOneToLinesWithRuntime`/`checkOneErrorsWithRuntime`/
  `checkOneSchemeFull`, via `checkModulesEntryFull`/
  `checkModulesEntryFullSplit`): `driver/diagnostics.mdk`, `driver/
  main_autoprint.mdk`, `tools/check.mdk` (the front door), `tools/repl.mdk`,
  `tools/doc.mdk`, `tools/snapshot.mdk` (its scheme-dump call sites only),
  `entries/profile_main.mdk` (its typecheck-timing call only),
  `entries/check_batch.mdk` (`one-check-driver` sprint, PR #2025), and —
  closing out the #1116 precondition — `tools/lsp.mdk`, `tools/check_policy.mdk`,
  `entries/playground_main.mdk` (all three onto `checkOneSchemeFull`,
  `flat-exit-floor` slices 3/4). **Accepted behavior change** (Val's
  2026-08-26 decision): the front door's displayed scheme list narrows from
  Flat's folded prelude+user dump to the user's own declarations only — not
  byte-identical, reblessed across 12 goldens. **Remaining Flat-family
  callers, each with a recorded verb (`test/CHECK-WRAPPER-CALLERS.txt` +
  `test/diff_compiler_flat_vs_onemodule.sh`'s header), none of them
  residual work — all three are terminal dispositions, not a to-do list**:
  `entries/check_match_main.mdk` (`checkMatchToLines`) — KEEP-PINNED, migration
  declined on measurement (`flat-exit-floor` slice 4): no Module-arm wrapper
  exists for its match-error-lines rendering shape, and building one is E-2's
  job, not a pre-collapse migration. `entries/selfproc_tc_probe.mdk` and
  `entries/typecheck_main.mdk`'s `withTarget`/no-runtime half (both
  `checkToLines`) — KEEP-PINNED, both deliberately prelude-free single-file
  dev-harness probes (LEG D; `typecheck_main.mdk`'s diffs against
  `dev/tc_probe.exe`), not multi-module machinery, with no Module-arm
  equivalent needed. `entries/check_flat_diags_main.mdk`
  (`checkProgramDiags`) and `entries/origin_agreement_main.mdk`
  (`checkProgramSchemesWithRuntime`) — KEEP-PINNED CONTROLS: they exist to
  test the Flat driver itself and stay until `CheckMode`'s `Flat` constructor
  is actually deleted at E-2, at which point they are deleted WITH it (not
  migrated — there is nothing to migrate a Flat-driver probe onto). **Untouched
  by design, deferred whole to E-2/E-4:** the `elaborateDict` family
  (`llvm_emit_typed_main`, `wasm_emit_typed_main`, `core_ir_dict_pp_main`, plus
  the two `elaborateDict` call sites inside `profile_main.mdk`/`snapshot.mdk`)
  — pinned RETAINED for the code-generating emit path per its own header
  comment, categorically higher-risk than the diagnostics-only wrapper family
  this stage targeted, and OUTSIDE the wrapper family this row/ledger tracks.
- **E-2. `CheckMode` collapse. Entry condition DERIVED 2026-08-27 (#1116,
  comment posted by the `flat-exit-floor` orchestrator, not this row).** The
  wrapper-family reacher set is now exactly the five rows E-1 lists as
  KEEP-PINNED above (two controls, one declined-migration, two prelude-free
  dev probes) plus the `elaborateDict` family (out of this wrapper's scope
  entirely, tracked separately). Collapsing `Flat` means: (i) deleting the two
  control probes (`check_flat_diags_main.mdk`, `origin_agreement_main.mdk`)
  and their gate rows, since there is no Flat driver left to control-test; (ii)
  giving `check_match_main.mdk` and the `elaborateDict` family a Module-arm (or
  explicitly-scoped) replacement BEFORE the constructor goes, since those two
  classes have no Module-arm equivalent today; (iii) leaving
  `selfproc_tc_probe.mdk`/`typecheck_main.mdk`'s `withTarget` half on
  `checkToLines` only if that function itself survives the collapse as a
  prelude-free entry (i.e. `checkToLines` is NOT necessarily `Flat`-only
  plumbing — confirm its implementation doesn't route through
  `checkProgramSeededSplit`/`Flat` before assuming it survives unchanged).
  With that set fixed, collapse the mode branches and the second stamper
  order; the fallback is re-expressed against the Module path (this is where
  its behavior is pinned, not changed). Byte-identical on the Module path;
  enumerated sign-off per divergence fixture for the rest. #462's
  comment-truth item dies here with the single order table.
- **E-3 ⊕ (#2034). Defaulting placement** per S-2(c) — **lands before E-4**, so the
  scheduling change happens under an enforced representation rule rather than
  silently moving Int/Float choices (#563/#564 close against the rule).
- **E-4. Scheduled marking.** Replace the promotion fixpoint + harvest-discard
  with per-binding marking on the (existing) SCC schedule per S-2(b)'s
  commitment rule; retire the joint flatten, `dropShadowedCore`, the
  sticky-snapshot hack, and A-3's marshalling shim. Explicit sub-bars:
  reset-lifecycle re-derivation, LSP seam contract test, per-module diagnostic
  attribution unchanged, marked-node universe = all body kinds. *This is R1;
  it does not start until E-2 is green and soaked.*
- **E-5 ⊕ (#1137). Per-method arity + calling convention as output-contract
  data** — routed in-arc 2026-08-17 (the #1661 routing rulings): §2 E's payload
  sentence finally has an owner. No engine derives arity from a clause pattern
  count or a declared signature's arrow spine. **After or with B-4 (#1318)**,
  per the slot-cardinality coupling stated there. Ships with the L5
  hand-derived arity conformance fixture — centralizing makes a wrong value
  unanimous, and no engine differential can see unanimity.

**Stage F — Locals + extraction + residuals**

- **F-1 ⊕ (#1082). Dict-abstracted locals** — the deferred (C) remedy, on the
  uniform-`gen` substrate, gated on S-2(f); retires the interim pin and #1052
  with it, and completes #1046/#1075's drain (their sites route through
  evidence instead of arg-tag). Calling-convention change across
  typecheck/dict_pass/core_ir_lower/both backends: benchmark-emitter + seed
  re-mint discipline.
- **F-2. Extract D (error-path machinery)** — ~~pure extraction, byte-identical;
  #480's loc-helper dedupe rides in this diff.~~ 🚨 **WITHDRAWN 2026-07-30
  (#1120) — not deferred, not blocked, not rescheduled: the stage as specified
  cannot be built, and the version that could be is a net loss.** Every claim in
  the struck text is false (the split is a loader cycle, so "pure extraction,
  byte-identical" is unreachable); see §2 D's warning block for the full
  falsification. `#480` was unbundled and landed on its own. The live
  descendants — **#1146** and **#1147**, both CLOSED — are what the goal
  actually cashed out as. **Do not re-schedule F-2 from this line;** re-scoping
  component D is an owner decision, tracked by **#1660**.
- **F-3 ⊕ (#311/#614). Coherence (a)→(c). ✅ COMPLETE 2026-08-01** — landed as four
  ordered PRs, not one: **F-3a** (thread the full goal vector, #1154/#1161),
  **F-3b** (union headless impls into every bucket, #1128), **F-3c** (the
  no-unique-minimum arm becomes a hard `T-AMBIGUOUS-INSTANCE`, #1155 — a
  NARROWING), **F-3d** (`cohClassify` demotes the `⊑`-incomparable half of the
  declaration-time sweep to `W-INCOMPARABLE-IMPLS` — a WIDENING). ⚠️ The "single-PR
  sized" claim below is the sizing error this stage is the record of: c and d move
  acceptance in **opposite** directions, so bundling them makes CI unable to say
  which half moved a golden. Residue: **#1183**.
  ⚠️ Correction (2026-08-23, predicate-slots planning finding 2): F-3a's "thread
  the full goal vector" delivered a deliberately transitional per-slot vector
  (the `CSlot` layer), not predicate-identity threading — that landed at B-4
  (#1318, PR #1862), which retired the transitional layer. Do not read this
  row's ✅ as "goal vectors are done"; B-4.2 (#1871) tracks where they still
  are not.
- **F-4. Hygiene residuals**: #176 (ref-growth probe, after A-3 changes the ref
  population).

**Dependency spine:** S ⟶ A-1 ⟶ A-2 ⟶ A-3 ⟶ {B-2, E-1} ; (A-1a withdrawn —
its decision is made in writing inside A-1, not as a separate node) ;
B-1 ∥ C ∥ D (dependency-independent of A after S; landing interleaved) ;
E-1 ⟶ E-2 ⟶ E-3 (#2034) ⟶ E-4 ; B-3 anytime after S ; F-1 after C-1, E-2, and
S-2(f) ; ~~F-2~~/F-3 anytime after S (**F-2 WITHDRAWN**, see its §6 entry —
this node no longer exists). The graded arc (#822→#823→#824) runs as a
peer, coordinating at A-3 (kind machinery) and D-3 (coverage rules).

⚠️ **The spine above predates the 2026-08-05 audit, whose amendment on epic
#1122 is authoritative over it** and refines Stage A's interior: `#1280 →
#1317 → A-3 (#1112) → B-2 (#1113)`, with the two name-identity units — **#1319**
(constructors) and **A-values (#1337)** (values, above) — running **parallel**, and
#1114 parallel to the A-2 tail. Read the epic's stage table and its amendment
comments, not this line, when sequencing new work. **The 2026-08-17 roadmap
re-derivation comment on epic #1122 is the current amendment layer**: it
reconciles the post-2026-08-12 landings (B-2's terminal state, the B-2.4 cut to
X-E.C, sprint #1663) and supersedes the epic body's serialized-lane block; the
remaining spine it derives runs #1351 ∧ #1450 → #1182 first (conjunct 1 of
C4/I2), with #1319, the D-lane + graded sprint, the E-lane, the C-lane → F-1,
and the B-1 design run around it.

**Sizing honesty.** A is weeks of serialized work (every golden family moves at
least once; "fleet-parallel" applies to development, not landing); B-1, B-2 and
E-4 are the three design-first items; B-3/C-2/D-1/F-3 are single-PR sized (F-2
stood here too, and its sizing is the record of why this line is a guess: it was
~2× over on line count and infinitely over on feasibility — see §6).
Nothing in this plan is a side quest — #993's own warning generalizes to the
whole arc.

---

## 7. Verification doctrine

- **Conformance-first.** Stage S's clause-indexed fixtures are the *oracle of
  record* for every behavioral change; captured goldens remain the oracle for
  *unchanged* behavior only. Where the two disagree, the clause wins and the
  golden moves with a per-clause justification (R2's enumerated carve-outs).
- **The known-wrong-oracle rule.** No `CAPTURE=1` against a shape in a family
  this document names until that family's stage lands; pin with `must_fail`
  instead (the tracker self-drains). **Engine-realization defects (#1034/#826/
  #1101/#1020) are NOT lifted by any stage here** — their capture ban holds
  until the engine fix lands, which is why §4 evicts them from the matrix.
  Matching-arity/silent-only guards go in the pin comments (the #1070 lesson:
  the obvious repro is often the loud one).
- **A pin→stage map.** Each stage's issue lists which `must_fail` fixtures it
  is *expected* to flip green (the suite fails loudly on a flip, naming the
  issue); an unplanned flip mid-queue reads as a break, so planned flips are
  declared up front.
- **Byte-identical where claimed — with stated scope.** B-3, C-1
  (module-placement probes), E-2 (Module path only; per-fixture sign-off for
  Flat divergences) carry byte-identical bars — **F-2 stood in this list and its
  bar was unreachable: the split is a loader cycle, so there was no build to be
  byte-identical to** (#1120); A and B-2 explicitly do
  not (identity and selection *are* semantics) and say so per golden family.
- **Seed and emitter discipline.** Any stage that perturbs the compiler's own
  emitted IR (A at scale, B-2, F-1) runs the benchmark-emitter two-rebuild
  rule and the twice-run seed re-mint; a stale seed SEGFAULTing the fixpoint
  is a known failure mode, not a signal about the change.
- **The standing questions** (`.claude/workstreams/TYPECHECK.md`) apply to
  every S0 fixed in passing; adversarial review is mandatory for every
  behavior-touching increment in B-1, B-2, E-2, E-4, F-1 (this seam produced
  confirmed S0s in three separate reviews during the #839/#840 arc).
- **Loud-over-quiet.** Any task that converts a crash/reject into an accept
  must present the spec clause licensing the accept plus a fixture that could
  not pass before — the "new something is untested by construction" rule.

---

## 8. Risks, and what this proposal does not do

- **E-4's blast radius** is the honest maximum: reset lifecycle, LSP seam,
  diagnostic ordering, and the fixpoint's oracle-matching behavior all move.
  Mitigation is structural (E-1/E-2 first; E-3's rule in force; S-2(b) written
  before E-4 starts; full adversarial bar).
- **Perf.** Identity keys and whole-graph environments must not regress the
  self-compile: the representation is decided in writing inside A-1 (A-1a,
  which would have decided it by measurement, is withdrawn — §6); hot lookups
  stay monomorphic (the +56% lesson); the perf-scaling gate's alloc arm is
  blind to constant factors, so stages A and B-2 are meant to carry an
  interleaved wall-clock A/B on the self-compile as their own landing bar,
  with a stated positive control and minimum detectable effect. **That bar
  has no working instrument today** — its only harness, `test/bench.sh`, is
  macOS-only and exits 2 without measuring on this project's Linux dev box
  (#1187) — so A-1/A-2 cannot claim to have cleared it until #1187 lands a
  working harness; treat the bar as blocked, not satisfied by omission.
- **Graded-arc coordination — three named points as of 2026-08-17.**
  (1) *Kind machinery*: RESOLVED — #822 closed 2026-07-25 and A-3.5c (#1557)
  landed the declared-kind reads, so this arc owns that machinery now (the
  original "A-3 and #822 both rewrite it, whichever lands second rebases" hazard
  is spent; the L5 row's stale-premise note says the same). (2) *Coverage
  rules*: D-3 and #823 both touch them. ADOPTED 2026-08-17 (recorded on
  #817/#823): #817/#825 reach their terminal state via the graded arc only
  after D-3 is in force, and **D-3 + #823 run as one coordinated sprint** —
  ownership stays with the graded arc, execution folds into the D-lane. The
  eager-arm fork is RESOLVED (Val, 2026-08-17: DEFER the arm; the uncharged
  signature never ships). (3) *#1594 is a mandatory rider on #823*: the
  flat-path `TkBare` kind keying converts S3 → S0 the moment a graded interface
  lands in `core.mdk`.
- **Serialized landing.** Stages A and E occupy the whole `ws:typecheck` lane;
  B-3/C/D provide *development* parallelism, with landing interleaved through
  the one-PR-in-flight rule. The plan claims no more than that.
- 🚨 **Emitter-arc coordination — this arc HAS a downstream consumer, and until
  2026-08-14 this document did not say so.** The emitter rearchitecture epic
  #1398 sequences its X-E stage (#1403) *after* B-2 and cites #1113 five times
  (`compiler/EMITTER-TARGET-ARCHITECTURE.md:154`, `:571`, `:637`, `:723`,
  `:802`); this file cited that arc **zero** times. The citation being
  one-directional is how `B-2.4` came to be scoped as work #1403 already
  claimed by name — *"X-E still owns final evidence references and
  route-word/`KeyBuckets` retirement."* **Owner ruling, 2026-08-14, recorded on
  BOTH issues:** `B-2.4` is **CUT** and routed to X-E.C; B-2 ends at **B-2.3**
  (frozen admissibility) plus a new **B-2.3b**, the selector re-key repointing
  `keyForSite` from typecheck's `*ByMethod` candidate family to its `*ByIface`
  family (#1182). The order-dependent *selection* is made in `types/typecheck.mdk`,
  upstream of every route word — no engine participates — which is why cutting
  the engine leg defers no S0. #1621/#1265 route to X-E; #1068 stays co-owned
  (B-2 supplies, X-E cuts over, X-W owns any physical residual).
- **Not in scope:** engine-realization bugs (#1034/#826/#1101/#1020, the
  emitter E-PANIC halves, and — since the 2026-08-14 ruling above — the whole
  engine word-set leg, wasm parity included), the graded arc's own design forks
  (#823's eager-arm decision — made 2026-08-17, still not this arc's work), the
  `do`/`defer` routing implementation (#824), and any change to surface syntax. The `medaka check` CLI surface is unchanged
  throughout.

---

## 9. A-3.4 — the `IE` registry: unit design

**Status of this section:** DESIGN, no implementation. It is the first per-unit
design carried inside this document, because A-3.4's absence of one was the only
thing standing between it and implementation (#1112). Scope is exactly the
A-3.4 cell of the 2026-08-08 decomposition on #1112 — *"one registry replacing
three answers to «what impls exist»"* — under the fixed edges
`3.1 → {3.2,3.3,3.4} → 3.5 → 3.6 → 3.7`. A-3.5/3.6/3.7, #1265, #1482 and B-2
(#1113) are out of scope and this design must not be read as licensing work in
them.

Every claim below is labelled **MEASURED** (run first-hand while writing this),
**DERIVED** (read off the source at the cited coordinates) or **RELAYED**
(someone else's result, cited).

### 9.1 The three preconditions, re-derived

- **P1/T2 are present.** DERIVED at `99780077`: `data IfaceRef { irName,
  irOrigin : TyConOrigin }` and `Predicate { iface : IfaceRef, args }`
  (`compiler/types/typecheck.mdk:3060-3075`); the writer
  `insertUnivImpl`/`insertUnivImplKeys`/`insertUnivImplAt` and the readers
  `implCountForIfaceU`/`univConcreteBucket`/`univHeadless` all key the interface
  half in the `NsIface` namespace (`:17885-17949`, `:17981-17982`,
  `:18275-18297`). So `IE`'s interface key exists already; A-3.4 **reuses** it
  and mints no parallel scheme.
  ⚠️ **Not "the one mint" — say two, both `NsIface`.** DERIVED at `da16471c`:
  the writer calls `oblIfaceKeys` (**plural**, `:17887` → `:17928-17931`), which
  returns `[oblIfaceKey ir]` when the interface carries an origin and
  `[oblIfaceKey ir, TkBare NsIface ir.irName]` otherwise —
  `oblIfaceKey ir = tabKeyOf NsIface ir.irOrigin ir.irName` (`:17981-17982`) is
  one of the two. The second is the **bare compatibility leg** §9.4 discloses,
  and it is a *key* mint, not just a read. Leg 1 of §9.3 is unaffected — both
  mints are `NsIface`, which is what that leg's greppable proposition is about —
  but "one mint" sitting next to "identity-keyed" is the
  partial-identity-reads-as-complete shape this arc keeps paying for, so the
  count is stated rather than rounded down.
- **#1265 does NOT gate A-3.4** — and this reverses the gate the 2026-08-08
  scoping pass set, so the derivation is spelled out rather than asserted. The
  later adjudication already rules this way in two independent places: #1112's
  §1 **row 7** reads *"`methodIfaceTableRef` … **DOES NOT GATE — belongs with
  B-2**"*, and the same comment's precondition list reads *"Explicitly NOT
  preconditions: … #1265 …"*. The mechanics agree, three ways, all MEASURED:
  (a) #1265's body never names `methodIfaceTableRef` — `gh issue view 1265
  --json body | grep -c methodIface` → **0**; (b) its collapse key is an
  **emitted symbol**, `defaultFnName tag method = "mdk_default_\{method}_\{safeIdent tag}"`
  (`compiler/backend/llvm_emit.mdk:1361`, mirrored as `defaultFnNameW`,
  `compiler/backend/wasm_emit.mdk:4528`); (c) eval's default registry is
  **already identity-keyed** — `defaultCellName ifaceId method =
  "\{ifaceId}#\{method}"` (`compiler/eval/eval.mdk:335`) — so eval's wrong
  answer is produced by a **selector over two survivors**
  (`ifaceIdsAtTag`/`defaultOwnedBy`'s first-match fallback,
  `compiler/ir/core_ir_lower.mdk:1241-1248`,
  `compiler/backend/wasm_emit.mdk:4511-4518`), not by a bare table key.
  The residual bake-in worry is answered *by §9.3's constraint*, not by luck:
  the only way building `IE` could entrench #1265 is if `IE` grew a
  `(method, tag)`-keyed default registry, and §9.3 forbids that mechanically.
  ✅ **The conflicting record is retracted, and the invitation this section used
  to extend has been taken up and closed.** The 2026-08-10 cross-reference
  comment that named #1265 as A-3.4's binding gate
  (#1112 `issuecomment-5236675191`) was corrected by its own author the same day
  in #1112 `issuecomment-5237149420` (2026-08-10T07:27Z, MEASURED via
  `gh api repos/MedakaLang/medaka/issues/comments/5237149420`), which agrees with
  (a)/(b)/(c) above point-for-point and concludes *"A-3.4's start does not
  require a ruling on issue 1265."* The design review that followed reviewed the
  substance and **did not dissent** (RELAYED). So this is not an open question a
  later reader may re-litigate: the mechanics (a)/(b)/(c) are the durable record,
  and the earlier claim survives only as the retracted comment it is.
- **#1482 (U1b) does not gate A-3.4** — it binds A-3.6 (RELAYED from the
  2026-08-10 comment; independently DERIVED here: A-3.4 adds no goal producer and
  deletes no filter).

### 9.2 The candidacy filter is live, and A-3.4 keeps it ON

MEASURED at `99780077` on a cold-bootstrapped binary in an isolated worktree,
under `MEDAKA_STRICT=1`, exit codes read from unpiped invocations. Four modules;
the *only* difference between the arms is the topological position of the module
carrying the foreign `impl Sizer Int` (same spellings, same impl, same goal):

| arm | foreign impl's module | `check` |
|---|---|---|
| impl topo-**earlier** than the goal's module | before `cmod` | **exit 0, silent accept** (the #1438 S0) |
| impl topo-**later** than the goal's module | after `cmod` | **exit 1**, `No impl of Sizer for Int` at the call site |

The hand-derived correct answer for both, from DICT §8 I4 (a class is a
`(module, name)`), is the reject. So candidacy today is genuinely the
topological **prefix**, the ordinal filter A-3.1 landed reproduces it, and
**deleting that filter converts the second arm into the first** — a silent
accept. This discharges the experiment #1112's 2026-08-10 comment recorded as
OWED, in the direction that comment named as the bad one: A-3.6 widens #1438's
reach and is correctly gated on #1482.

**Consequence for this unit, non-negotiable:** every `IE` read goes through
`declEnvVisibleAt` (`compiler/types/typecheck.mdk:2712-2713`) via one accessor.
A-3.4 does not delete, weaken, or open-code that predicate.

> ⚠️ **This paragraph ended "A-3.6 remains the deletion of its body and nothing
> else." A-3.6 (#1558) has landed and it was NOT that.** By owner ruling
> (2026-08-12) the predicate **split**: `ieCandidacyVisibleAt` carries the
> INSTANCE-candidacy axis and is unconditionally `True` (graph-global — this is
> where A-3's C4/I2 claim is cashed), while `declEnvVisibleAt` **keeps its ordinal
> body** for every NAME-scoping reader (the alias table, the ctor overlay pool, the
> field-owner multimap, the data param-kind table, and both `CE` lookups). One
> deletion would have applied an instance-candidacy licence to five structurally
> different subjects, which `docs/spec/DICT-SEMANTICS.md`'s I5 boundary clause
> forbids by name — and one of them (field owners) would have NARROWED acceptance,
> which §5 R2's two exceptions, both widenings, cannot carry.
> `ieRowsVisibleAt` (A-3.5b) is an `IE` reader that deliberately stayed on the name
> axis: it answers a decl-time EXISTENCE question, not a candidacy one. Whether it
> should also widen is open and unruled.

### 9.3 THE CONSTRAINT: `IE` is keyed by impl identity; the default-arm word namespace is NOT `IE`'s

This is the design decision the missing doc left open, and it is stated first
because everything else is subordinate to it.

> **`IE` holds impls. An interface's default-method arm is a property of the
> INTERFACE declaration — `CE`'s content (A-3a) — and the emit-side
> method/default *word* namespace belongs to B-2 (#1113), whose body already
> claims "the disjoint default-tag word namespace". No `IE` key component may
> be a method name.**

A future `IE` that folded the default-body/default-arm registry in and keyed it
`(method, tag)` would rebuild #1265 in the new substrate: that pair is exactly
the key whose two survivors #1265 is the first-match over.

**Three legs hold an implementation to it. Prose alone would not.**

1. **Representation.** `IE`'s key is a `RegKey` built only from `TabKey`s tagged
   `NsIface` and `NsType` — the existing `oblIfaceKey` / `dispHeadTab` /
   `regKeyNTab` mints (`compiler/types/registry.mdk:507-530`,
   `compiler/types/typecheck.mdk:17940-17948`). A method name enters an `IE`
   row only as **payload** (`ieMethods`, the impl's own defined-method list),
   never through a key mint. `Ns` is a closed six-constructor enum — `NsType`,
   `NsIface`, `NsMethod`, `NsCtor`, `NsField`, `NsValue`, declared at
   `compiler/frontend/ast.mdk:193-200` (DERIVED at `da16471c`; ⚠️ **not**
   `compiler/types/registry.mdk:341-347`, which an earlier draft of this line
   cited — that range is `nsTag`, the *renderer*) — so "no method component" is a
   greppable proposition about which `Ns` constructors appear inside `IE`'s
   block, not a matter of taste.
2. **A ratchet check.** Add **check 4** to `test/registry_keying_ratchet.sh` —
   which already runs inside `test/typecheck_compiler_source.sh`, itself inside
   the required `soundness` job, so no new CI wiring and no shard-coverage
   hazard (that script's own header explains why folding in beats standing
   beside). The check delimits `IE`'s block by its banner comment and FAILS if,
   within it, any of these appears: a key mint naming `NsMethod`, `NsField` or
   `NsValue`; or any of `defaultFnName`, `defaultCellName`, `ifaceIdsAtTag`,
   `defaultOwnedBy`, `narrowDefaults`, `CImplDefault`, `methodIfaceTableRef`.
   Occurrence-level extraction (`grep -oE`), never a per-line containment test —
   the hole that script's own header documents.

   It ships with **four** executed positive controls, in the mutate/rerun/restore
   style that script's existing controls A–F use (`RUN ALL SIX if you touch any
   extraction/filter in this file`, `test/registry_keying_ratchet.sh:48-50` —
   those six grade checks 1–3 and stay as they are; these four are check 4's own,
   so the PR reports **ten**):

   - **G** — a `tabKeyOf NsMethod` **inside** the block → must **FAIL**.
   - **H** — the same text **in a comment** inside the block → must **pass**
     (a mention is not a mint; no false positive).
   - **I** — the same text **outside** the block → must **pass** (the delimiting
     works).
   - **J** — 🚨 **delete (or rename) the banner comment** so the block extracts
     **empty** → must **FAIL**. Without J the check has this tree's signature
     failure mode built in: a later refactor moves or rewords the banner, the
     block becomes empty, and check 4 passes having examined nothing — a green
     that tested less than it appears to. Check 1 already solves exactly this and
     the pattern is one `if` to copy: it counts its extraction and exits 1 with
     *"this check just validated nothing. Update the range markers — do NOT treat
     a zero extraction as a pass"* (`test/registry_keying_ratchet.sh:242-251`;
     the writer ratchet repeats it at `:319`). Check 4 must fail closed the same
     way — a zero-length `IE` block is a broken delimiter, never an empty answer.
3. **A declared non-flip.** `test/must_fail_fixtures/1265-two-ifaces-same-method-one-type-default-collapse`
   must stay RED across A-3.4, declared up front per §7's pin→stage map. It is
   the *observable* of this constraint: if A-3.4 changed the default-arm answer
   in any direction, the pin flips and the must-fail gate reds naming #1265.
   Fail-capable both ways, which prose is not.

The constraint is also stated in the ratchet's **existing `declEnvsRef` row**, so
widening it is an edit to a reviewed artefact rather than a silent drift — see
§9.8 item 3 for *which* row, which is not the obvious one.

🚨 **And the corollary this design owes, because nothing else in the tree covers
it.** Check 1 pins the field sets of **`CrossRun` and `DriverState` only**: it
`sed`-extracts from `data CrossRun = CrossRun {` and from `  | DriverState {` and
compares each against its allowlist (`test/registry_keying_ratchet.sh:231-274`,
DERIVED at `da16471c`; `grep -n DeclEnvs test/registry_keying_ratchet.sh` finds
the string only *inside* the `declEnvsRef` row's prose, never as an extraction
range). **`DeclEnvs`' own field set is therefore pinned by nothing** — so `IE`, a
program-global table, would enter the tree *outside* the very field ratchet that
exists for that shape — and A-3.2/A-3.3 will add their fields to the same
unpinned record (`DeclEnvs` today holds exactly A-3.1's three, `:2665-2669`), so
this is a gap that widens with each remaining A-3 unit rather than a one-off.
**A-3.4 should
extend check 1's extraction to `DeclEnvs` (and `DeclEnvModule`) with a third
allowlist.** It is a small change — one more `sed` range, one more `*_expected`
list, one more `/=` comparison, reusing the zero-extraction guard already there —
and it is the difference between "the ratchet covers the bundle `IE` lives in"
and "the ratchet covers the bundle that merely *points at* the bundle `IE` lives
in". Its own positive control follows check 1's control **B**: add a rogue field
to `DeclEnvs` → must FAIL.

### 9.4 Data shape, key, and identity

`DeclEnvs` (`compiler/types/typecheck.mdk:2665-2669`) grows **one** field. The
row type carries what §2 K specifies — *"every impl with its full head, context,
and method table"* — plus an instance identity:

- `ieOrd : Int` — the declaring module's ordinal (A-3.1's `demOrd`). The scope.
- `ieInst : InstRef` — the **instance identity**: declaring module id, ordinal,
  and the impl's sequence number *within the whole-graph build*. Minted in
  exactly one place, inside the builder.
- `ieIface : IfaceRef` — reused, not re-invented (P1's carrier).
- `ieTys : List Ty` · `ieReqs : List Require` — the full head and context.
- `ieMethods : List String` — the method table, **payload only** (§9.3).
- ~~`ieLoc : Option Loc` — for A-3.7's diagnostics.~~ 🪦 **NOT BUILT, and A-3.7 did not
  need it.** The row carries the raw `ieTys`, and the parser stamps every `TyCon` leaf
  with its span, so `firstTyLocList` recovers from the head exactly the blame span
  coherence used when it walked decls — no new field, no `DImpl` change. `ImplRow`'s own
  header argues the omission from `Decl` having no `Loc`, which is true and beside the
  point for any consumer that can read the head.

Index: the same three buckets the obligation channel already has, with the same
keys — `MultiRegistry` for concrete heads keyed `regKeyNTab [oblIfaceKey ir,
dispHeadTab hk]`, `MultiRegistry` for headless heads keyed
`regKeyOfTab (oblIfaceKey ir)`, and `Registry SetRegistry` for the
iface→head-tag set. `mregAppendK`, not `mregAddK`: forward declaration order
within a bucket is semantic (`findMatchingImplReqsU`).

**Why `InstRef` is part of this unit and not a nicety.** `cohClassify`'s own
ledger records that tightening coherence needs *"INSTANCE IDENTITY this tree
does not have (`bucketKeyEntriesFrom` restarts its numbering at 0 per module, so
two distinct impls in different modules share an index) … L2 / A-3 / B-2 work"*
(`compiler/types/typecheck.mdk:12930-12937`, DERIVED). A-3.4 is where that
identity is minted; A-3.7 and B-2's `InstId` consume it. A-3.4 itself reads it
nowhere — it is a deliverable, not a behaviour change.

**The head half stays bare, by decision, with its measured reason.** Do not read
"identity-keyed `IE`" as covering both halves: `dispHeadTab`
(`compiler/types/typecheck.mdk:18163`) is spelling-keyed because the **goal**
side cannot match an identity there, and re-keying it re-introduces the closed
S0 #1277 (the #1317 T1 rule; RELAYED, with the derivation written at
`dispHeadTab`'s own block). The compatibility leg in `insertUnivImplKeys` —
index an identity-carrying impl **also** under its bare spelling, for goals
minted by the two remaining `ifaceRefBare` producers — is carried into `IE`
unchanged, which is why **#1438 still accepts after A-3.4** and its pin still
holds. That drain is #1482's (U1b), not this unit's.

### 9.5 Where it is built, and why building it is observationally inert

Built inside `buildDeclEnvs` (`compiler/types/typecheck.mdk:2683-2690`), folding
`deModules` in ordinal order. It must run after the driver's
`stampGraphTyOrigins`, for the same reason A-3.1 records: identity lives on the
decls.

**The equality argument, which is the whole byte-identical bar.** Today's
Module-arm universe is grown one module at a time in `appendUniverseAccums`
(`:21809-21836`), whose own comment records that it feeds `growImplUniverse` the
*same* `implDeclsWithReqs` triples the old per-module rebuild consumed.
`implDeclsWithReqs` is a `flatMap` (`:18707-18708`) — pure and
order-preserving — and `growImplUniverse` is a left fold that appends per key
(`:17878-17880`). Therefore, for the ordinal prefix `d₀ ++ … ++ dₖ`:

```
growImplUniverse (implDeclsWithReqs (d₀ ++ … ++ dₖ)) empty
  ==  the k-fold accumulation appendUniverseAccums has after module k
```

— same rows, same buckets, same within-bucket order. That is what makes a
prefix-filtered `IE` at ordinal *k* the same value the accumulator holds when
module *k* is checked, and it is the proposition PR2 below must *measure*, not
assume.

⚠️ **The fold algebra above is the part that is verified, and it is not where
this breaks. Name the other half as its own sub-proposition:**

> **DL — the decl-list identity.** `envs.deModules`' `demDecls` at ordinal *k*
> **is** the `prog` that `appendUniverseAccums` was called with for module *k*,
> for every *k*, in the same order, exactly once each.

DL is assumed, not shown, by the algebra: `appendUniverseAccums prog` takes the
module's own decl list as its argument (`:21809-21810`, DERIVED) while `IE`'s
builder reads `demDecls` (`:2662`, `:2695`), and those are two independently
constructed lists. DL is false if the two disagree about the prelude's shape
(one node vs concatenated), about a `DAttrib` unwrapping, about which arm supplies
a re-exported decl, or about how many times a driver runs over one graph — and
`graphMethodExportsRef`'s ratchet row already records that *"a driver may run
twice over one graph"* (`test/registry_keying_ratchet.sh:206`, DERIVED). **The
equality is the conjunction of the algebra and DL.** An implementer who verifies
only the algebra has verified the half that was never in doubt.

**Two ordered PRs.**

- **PR1 — carrier + builder.** The `DeclEnvs` field, the row type, `InstRef`,
  the ordinal-filtered accessor, the ratchet check 4, its allowlist-row edit
  (§9.8 item 3) and the shadow-compare below. **Zero readers**; the filter is on.
  Byte-identical by construction (the only new code is unreached by any
  judgment).

  🚨 **PR1 cannot otherwise fail on the value it builds, and that is a defect in
  the staging, not merely a limitation to note.** With zero readers, a mis-built
  `IE` — wrong ordinal, dropped rows, wrong within-bucket order — is
  unobservable: check 4 grades **namespace hygiene**, the doctests grade the
  **mints**, and neither looks at the population. PR2's gate is then *"zero
  program-output golden movement"*, which cannot see an order divergence inside a
  bucket whose first-match only matters for shapes the corpus does not contain.
  That is a silent widening deferred to a later unit — the shape §9.9's first
  falsifier is supposed to catch and structurally cannot.

  **Remedy, with in-tree precedent: PR1 ships a temporary shadow-compare.** At
  each point `appendUniverseAccums` grows the accumulators, also project `IE` at
  the current ordinal and **panic on disagreement** (rows, buckets, and
  within-bucket order), then delete the instrument in PR2. The precedent is this
  file's own #1277/#1317 work, which built the compiler with exactly this
  instrument: *"a panic on disagreement, which fired `answer=1 spell=2 at ff` on
  #1277's `main.mdk` and stayed SILENT on `main = println "hi"` and on #1277's own
  control … so the instrument discriminates"*
  (`compiler/types/typecheck.mdk:15280-15290`, DERIVED). That is the property
  wanted here in both directions: it makes PR1 **fail-capable**, and running it
  over the gate corpus **discharges DL and the algebra as a measurement before
  PR2 commits to them** — which is strictly better than PR2 measuring the same
  equality through goldens that cannot see order. It must be a hard panic, not a
  diagnostic: a diagnostic would move goldens and be blessed away.

  ⚠️ Two constraints on the instrument, both from this tree's own record. It is
  a *whole-graph projection per module*, so it is **quadratic by construction**
  and must not be left in — hence "temporary", stated in the code beside it and
  in the PR body. And a panic is `<Panic>`-shaped in a stage that accumulates
  errors rather than raising (`AGENTS.md`, "Errors accumulate"), which is exactly
  why it is an instrument that PR2 deletes and never a shipped check.

  **Retirement condition for PR1, stated up front.** If the PR2 flip re-scopes
  onto A-3.5 (§9.9's first falsifier), PR1 has added a `driver_allowed`-side row
  with none removed — and by A-3.1's own rule *a unit that adds a row without
  shrinking another has not moved the arc*. In that outcome PR1 is **not**
  retroactively fine: the owner decides between (i) keeping it as declared
  substrate for A-3.5/3.7 with the re-scope written into the epic's stage table
  and the shadow-compare **kept** until a reader exists, or (ii) reverting it so
  the arc carries no unread field. Do not leave that choice implicit — an unread
  field with no reader in sight is how shelf-ware enters, and #1112's stage table
  is where the answer is recorded.
- **PR2 — one reader flip, conditional.** The **Module** arm's obligation
  universe becomes a projection of `IE` at the current ordinal instead of the
  three `obUniv*` accumulators; the **Flat** arm keeps `buildImplUniverse` as
  the shim, and no `match mode` branch is edited (E-2 deletes those). This is
  what makes `IE` real rather than shelf-ware, and it is the unit's mechanical
  progress signal: the three `obUniv*` rows leave `cross_allowed` while the
  `declEnvsRef` row in `driver_allowed` grows to own their contents (§9.8 item 3
  — no new row is added; that is the point) — per A-3.1's note, *a unit that adds
  a row without shrinking another has not moved the arc*. **PR2 lands only if the
  §9.5 equality holds as a measurement** (zero program-output golden movement).
  If it does not, PR1 ships alone and the reader flip is re-scoped onto A-3.5
  with the measured divergence written up — that is a scoping outcome, not a
  golden to bless.

**What A-3.4 explicitly does not touch:** `keyForSite*` and the `KeyBuckets`
slices must not appear in its diff at all (the 2026-08-08 landing check; B-2
deletes them, and re-keying their counting scans re-introduced #1277 in a
measured experiment); `universeRegisteredIfacesRef` stays bare; the three
`*CollidedRef` detectors stay bare (merging by bare name is their purpose).

### 9.5a PR2 as executed — the reader flip, its measurement, and A-3.6's widening

§9.5 above is the design as written *before* PR2 landed; this subsection records what
actually happened, so the code site (`moduleImplUniv` in `compiler/types/typecheck.mdk`,
`grep -n 'THE .IE. READER FLIP'`) can keep pointers and its two tripwires rather than the
whole narrative.

**WAS → NOW.** WAS (#154 PR3, retired by PR2): `ImplUniverse obUnivConcreteRef.value
obUnivHeadlessRef.value obUnivIfaceTagsRef.value` — three `CrossRun` accumulators grown one
module at a time by `appendUniverseAccums prog0`. Those three fields are GONE, not merely
unread: these were their only readers, so leaving them would have left two sources of truth
for "what impls exist" (design law L1) and the `cross_allowed` ratchet would still carry three
rows the unit exists to retire. NOW: a projection of the whole-graph `IE` through
`ieUniverseAt`. A-3.5b later added a second `IE` read, `ieRowsVisibleAt`, so "the ONE place"
is no longer true and must not be re-instated at the code site.

**The `ieShadowCompare` instrument is gone with it.** §9.5's PR1 remedy shipped a hard `panic`
into the released compiler for exactly one job — measuring the §9.5 equality before the flip
committed to it. PR2 deleted it, on a strictly stronger measurement than PR1's per-module
slice.

**WHY THE FLIP IS EQUALITY-PRESERVING, MEASURED AND NOT ASSUMED.** §9.5's argument is the
conjunction of (a) the fold algebra and (b) `DL`, the decl-list identity the algebra assumes
rather than shows. PR1's `ieShadowCompare` measured the per-module SLICE. PR2 measured the
proposition the flip actually rests on: the WHOLE PREFIX universe at the read site — both
`MultiRegistry` buckets and the tag `Registry`, digested key-by-key and entry-by-entry in
bucket order, `IE` against the accumulator, panicking on any disagreement. Run over the
compiler's own graph (both the `checkModules` and the `elaborateModules` driver), `make
check-self`, the multi-module differential gates, and 193 multi-module fixture projects: ZERO
disagreements. Fail-capable in two directions, both executed — projecting at `ord - 1`
panicked with the prelude's whole population on one side and an empty universe on the other,
and a name-triggered control proved `medaka check` on a two-module project reaches the line
carrying a real module id at a real ordinal. That measurement, not the algebra alone, is why
the binding is allowed to exist.

**A-3.6 (#1558) removed the ordinal-prefix filter, and that is where the C4/I2 claim is
cashed.** PR2's own comment said the projection was "filtered to this module's ordinal
prefix … the filter stays ON here (it must)", which was PR2 correctly refusing to do A-3.6's
job early. A-3.6 has now done it: `ieSnapAt` routes through `ieCandidacyVisibleAt`, which is
`True`, so the binding is the WHOLE GRAPH's impl universe regardless of `mid`'s ordinal.
Everything an obligation check on the multi-module path knows about which impls exist comes
from that line, and it now knows the same thing in every module — which is what *"import
scoping never decides which instances exist"* (§8 I5) means operationally.

⚠️ **What this widens, said out loud.** #1482's measurement showed topological prefix scoping
was accidentally load-bearing for #1438's same-spelled-interface shape, so #1438's reach grows
at this line. That is expected and licensed by §8 I5, not a regression — but it is an
acceptance delta. 🚨 The pin PR2's comment named as the grader,
`test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order`, **no longer exists in the
tree** (derive: `ls test/must_fail_fixtures | grep 1072`), so the widening currently has no
named grading fixture. Whoever next touches this line should re-establish one rather than read
the absence as "already drained".

### 9.6 The subsumption enumeration — derived by SHAPE, not by prefix

Derived three ways, because a `universe*` prefix grep provably misses members
(`.claude/workstreams/TYPECHECK.md` trap 12): (i) the record enumeration of
`CrossRun` and `DriverState` (the two `awk` recipes in #1112's 2026-08-09
comment); (ii) *every* function in `compiler/types/typecheck.mdk` that matches a
`DImpl` pattern — `grep -n 'DImpl' compiler/types/typecheck.mdk` — which is what
reaches the impl-side answers that live in **no** ref at all and are recomputed
per call; (iii) the engine/emit side, which no `types/`-anchored derivation can
reach. Run the three commands rather than trusting this table's membership.

| today's answer to "what impls exist" | shape | A-3.4 |
|---|---|---|
| `obUnivConcreteRef` / `obUnivHeadlessRef` / `obUnivIfaceTagsRef` (`ImplUniverse`) | `CrossRun` registries, identity-keyed interface half | **SUBSUMED** (PR2) — this *is* `IE` |
| `buildImplUniverse` / `growImplUniverse` / `implDeclsWithReqs` | pure builders over a decl list | **SUBSUMED** as `IE`'s builder input; the Flat shim keeps them |
| `universeKeyBucketsRef` / `buildKeyTable` / `keyEntryOf` / `matchingEntries*` / `keyForSite*` / `headCollides*` / `implExistsForHead` (`KeyBuckets`) | route-word registry, head half bare by design | **LANDED — `S-keytable-payoff` (`75f4148f`) deleted the whole closed pass-through cycle.** `B-2.1-g` repointed `keyForSite` onto the graph-global `bodyImplEnvRef` (its `KeyBuckets` parameter removed); `B-2.1-d` DELETED `universeKeyBucketsRef`, `shadowKeyTableRef` and the whole prefix-table READ side — `implExistsForHead(Go)`, `matchedEntry`, `matchingEntries(Go)`, `candidateBucket`, `bucketOfHead`, `headCollides`, `countHead(Go)` and `B-2.1-f`'s `routeWordHeadSkew`/`reportRouteWordSkew`/`routeWordAmbiguousMsg`. `S-keytable-payoff` then deleted the zero-terminal-read remainder — `buildKeyTable`, `bucketKeyEntries(From)`, `keyEntryOf`, `KeyBuckets` itself, and `headBucketRender` — across its 20 sites. **STILL LIVE:** `KeyEntry`, `mergeByDeclIdx`, `keyForSite*`, `headBucketKey`/`headlessBucketKey`, `implKeyTc`, `keyEntryIdx`, `keyEntryOfRow` |
| `buildImplTable` / `implEntryOf` / `findImplEntry` (`ImplBuckets`, 2 build sites: `:11369`, `:24576`) | per-run bucket table keyed by bare iface+tag, consumed by `entail`/`routeOf` | **DEFERRED → #1622 (OPEN).** §2 K's *"K's IE is the single environment both must read"* consolidation stays owed — verified still live: `buildImplTable`/`implEntryOf`/`findImplEntry` are unchanged in `compiler/types/typecheck.mdk` (`:20196-20215`, `:22050-22051`). B-2 (#1113) closed 2026-08-16 without moving this reader; #1622 documents the exact obstruction (`selectReqImpl`'s `iface == ""` arm reads `ImplBuckets` by first-match over a different population/rule/goal-vector than the `IE`-backed `iface != ""` arm, so collapsing them unguarded is a semantics change, not a refactor) |
| **`implKeyOf` and its per-impl dict-registry family** — `declImplEntries`/`declImplIfaceIdRow` (`eval.mdk:305`, `:2001`), `lowerDeclImpl` → `CImplEntry`'s `key` field (`compiler/ir/core_ir_lower.mdk:1293-1313`, `:1221`), `distinctImplKeys` (`compiler/backend/wasm_emit.mdk:4066-4070`) | the **engine-side** per-impl dict-cell registry: a **bare-iface-name** key rendered into a runtime cell/symbol name, consumed by all three engines | **NOT `IE` — consolidated within B-2's own phases, #1113 (CLOSED 2026-08-16) does not gate it further.** `implKeyOf` itself is **deleted** (`B-2.2-e`, `compiler/eval/eval.mdk:543-548`): its own doc-comment records the fold — the mint now lives once, in `compiler/types/route_key.mdk`'s `implRouteKeyWord`, which both `eval.mdk`'s callers (`declImplIfaceIdRow`, `implMethodEntry`) and typecheck's `implKeyTc` (`typecheck.mdk:20415-20416`, calling `implRouteKeyWord` directly) now share — that shared call site, not a separate `keyEntryOf`/`KeyBuckets` hop (both deleted, see the `KeyBuckets` row above — this row's prior citation of them was stale), is what keeps the two byte-identical. It remains a **route-word** registry, not a declaration environment, and identity-keying it re-runs #1317's measured T1 failure (`typecheck.mdk:21411-21432`, where re-keying the *counting* scans alone reproduced #1277's S0 — and the same block records why the question is *inherently* spelling-scoped: three engines re-derive the same uniqueness test from a bare `String` tag). `Route` is an orthogonal concept, not a routing destination. ⚠️ Do not confuse `implKeyOf`'s old home with wasm's *homonym* at `wasm_emit.mdk:4068` (`CImplEntry -> List (String, String)`, a different function that merely projects the key this one minted) |
| `cohCollectImpls` / `cohCollectModuleImpls` / `cohImplsOf` (`:12590-12591`) / `cohImplsOfMid` (`:12612-12616`) / `CohImpl` / `coherenceUserDecls` | user-decls-only list, class identity a bare `String` (`:12588`, compared at `:12909`) | ✅ **LANDED at A-3.7 (#1559)**, with one carve-out. `CohImpl`'s interface half is an `IfaceRef` compared by `cohSameIface` (`sameTyConHead`), and both sweeps now read `IE`: `checkCoherence` takes `cohRowsOwnedBy cur hasPrelude`, `globalCoherenceConflict` takes `cohRowsOf True`, both projected through `cohImplOfRow` — which is where `InstRef` gets its FIRST judgment reader (`instRefMid`). The four decl-walking adapters (`cohCollectImpls`/`cohCollectModuleImpls`/`cohImplsOf`/`cohImplsOfMid`) are **deleted**. ⚠️ **`coherenceUserDecls` does NOT retire** and A-3.7 shrinks `driver_allowed` by **zero** rows: on the Flat arm there is no ordinal-0 prelude row to filter (`flatImplEnvOf` seats its one user module at ordinal 0), so that field *is* the Flat arm's prelude carve-out. Retiring it needs the flat path to gain a prelude node (§7.1 U1 / E-4) |
| `implCompletenessMsgsOf` / `implCompletenessMsgsOfMap` | per-decl scans; the Flat arm scanned a decl list by BARE NAME (`ifaceRequiredMethods`), the Map arm read `universeIfaceRequiredRef` | ✅ **LANDED at A-3.5a (#1557).** The two checkers are now ONE (`checkImplCompletenessMap`, kept under its historical `Map` name to avoid stranding this citation and three others), reading `CE` at the reading module's ordinal via `ceRequiredAt` → `ceLookupAt`. Retires `universeIfaceRequiredRef` + its writer `insertIfaceRequired`; `cross_allowed` **24 → 23**, derived on this unit's own base — do not quote that pair elsewhere without re-deriving (`sh test/registry_keying_ratchet.sh` prints it). ⚠️ **NOT byte-identical, and the delta is confined to the FLAT arm**: the Module arm's key does not move (`regKeyOfTab (ifaceTabKey implOrigin iface)` on both sides, and `classEnvRowsOf` mints `CeRow`'s key from the same `ifaceTabKey ifaceOrigin name`), so that arm is a population/lifetime move; the Flat arm's bare first-match scan → identity lookup **is** the re-key, per the owner ruling on #1557 OWED 1 |
| `superImplMsgsOf` / `implMatchesSuper` (`:14193-14251`) | scan of `allDecls` for a super's impl | **DEFERRED → A-3.5** |
| `checkInterfaceCycles` / `ifaceDfsCycle*` · `checkPhantomMethods` · `checkGradedImplHeads` / `checkGradedImplTys` | bare-name decl scans (cycles) · per-decl scan (phantom) · `ifaceParamKindsRef` lookup (kinds) | ✅ **LANDED at A-3.5c (#1557).** All three read `CE` at the reading module's ordinal — `ceRowsVisibleAt` (cycles, with super edges now followed by IDENTITY), `ceRowsOwnedBy` (phantom), `ceSlotKindsAt` (kinds). Retires `universeIfaceParamKinds` + `ifaceParamKindsRef`; `cross_allowed` **27 → 26** — this row said `28 → 27`, which is the PRIOR unit's transition (#1588, A-3.2b residual 1); re-derived 2026-08-12 by counting the `cross_allowed` allowlist at each merge commit (#1588 `257d7e79` 28→27, #1592 `6775679a` 27→26, #1590 `dc3e8bd5` 26→24; live value 24). NOT byte-identical, by owner ruling — see §9.9 |
| `implTysIfMatch` · `implHeadTagForIface` · `implHeadGround` · `implHeadParametric` · `declMethodNamesOf` · `argImplRequiresRoutesRecD`'s decl walk | per-call decl-list scans, no ref — invisible to every prefix grep | **DEFERRED**: they become `IE` readers where the read is authoritative (A-3.5/3.6), not here |
| `superDeclsRef`, `argDispatchIdxRef`, `methodDispatchIdxRef` | `DriverState`, interface/method-side | **NOT `IE`** — CE-side or RLocal-site channels (#1351); A-3.3 excludes the latter two deliberately |
| `EmitInput.methodIfaces` / `methodIfaceIndex` / `methodIfaceIdIndex` (`compiler/backend/llvm_emit.mdk:781-783`), read via `methodIfaceOfInput`/`methodArityOfInput`/`methodArityOfIface` (`:480-513`) by both backends | emit-side method→(iface, arity) table | **NOT `IE`** — #1112 §1 row 7. B-2 (#1113) is CLOSED and is no longer this row's routing. ⚠️ This row named `methodIfaceTableRef`/`methodIfaceIndexRef` in `compiler/backend/emit_support.mdk:449-464` until 2026-08-26; **neither symbol has existed since the `EmitInput` boundary landed** (`grep -rn 'methodIfaceTableRef' compiler/` → no hits), and `emit_support.mdk:449-464` holds `lazyGlobalNames`/`isDictParamName`, unrelated. This row's question was resolved by the **`emit-dispatch-identity`** sprint (#1810 / #1852, both CLOSED) — verified: `EmitInput` now carries both `methodIfaceIndex` (bare-name) AND `methodIfaceIdIndex` (an `OrdMap Int`, identity-keyed by iface id — `llvm_emit.mdk:783`, `:513`), the identity-keyed table this row was asking for |
| `ifaceImplHeadsRef` / `ifaceIdsAtTag` / `defaultOwnedBy` / `narrowDefaults` / `CImplDefault` (`compiler/ir/core_ir_lower.mdk`, both emitters), `defaultCellName` cells (`compiler/eval/eval.mdk`) | the default-arm registry and its selector | **NOT `IE`, BY CONSTRAINT** (§9.3) — **#1265 (OPEN)**, not B-2/#1113 (CLOSED). Verified: #1265's own repro names exactly these symbols (`CImplDefault`, `ifaceIdsAtTag`, `defaultOwnedBy`) — two different interfaces sharing a method name at one receiver tag both pass `defaultOwnedBy`, and the `_ => Some fallback` arm first-matches, surviving on all three engines |

### 9.7 `IE` is a program-global table: naming its key's scope, and proving it

`AGENTS.md` names the program-global table as the most expensive shape in this
tree, and demands the key's scope be *proven*, not asserted. `IE` has **four**
scoping components; each is proven by an observation, not by a sentence:

1. **Interface half — `tabKeyOf NsIface origin name`.** Two same-spelled
   interfaces in two modules mint different keys. Already *asserted in-tree* by
   `compiler/types/registry.mdk`'s own doctests
   (`tabKeyOf NsIface (OriginModule "gmod") "Same"` vs `… "pmod" …`, `:1797-1802`),
   and `tabKeyEq` never equates `TkIdent` with `TkBare`. A-3.4 adds a doctest at
   the `IE` builder asserting the two impls land in **different buckets**.
2. **Head half — bare, deliberately.** Stated as a residual with its measured
   reason (§9.4), not papered over. Its scope comes from component 1 plus the
   ordinal, which is exactly why "identity-keyed" must not be claimed for the
   pair.
3. **Row identity — `InstRef`.** Minted from `(demId, demOrd, sequence)` in one
   place, so two impls can never share it — the property
   `bucketKeyEntriesFrom`'s restart-at-0 numbering lacks. Doctest: two
   same-spelled impls in two modules get distinct `InstRef`s.
4. **Table scope — the ordinal.** Every read filters through
   `declEnvVisibleAt`; the fail-closed miss arm (`declEnvsOrdOf` → `-1`, which
   rejects every entry) is inherited from A-3.1 and keeps an unknown module id
   loud rather than globally permissive.

**The fixtures.** F2/F3/F4 carry the required *"feature + UNRELATED code still
behaves"* shape, not *"feature works"*. ⚠️ **F1 is a different instrument and
must not be filed under that heading** — every program it runs *does* read `IE`,
because they all consume prelude impls, so it is a **whole-population regression
probe** (does the table still answer correctly for the entire prelude?) rather
than a bystander. Both are needed; conflating them would let the set look like it
has bystander coverage when F1 is the only member that ran.

- **F1 — the whole-population probe** (*not* a bystander; see above).
  `make check-self` plus `medaka check` of
  `stdlib/core.mdk`, `stdlib/list.mdk`, `stdlib/map.mdk` and
  `compiler/driver/medaka_cli.mdk`, each exit 0 with zero diagnostics. Not
  ceremony: this is the exact probe that caught **both** prior key regressions in
  this channel (9 / 7 / 8 / 7 / 37 spurious `No impl of …` rejects, RELAYED from
  the A-2.2b and #1112-P1 experiments). A program containing only
  `main = println 1` is the cheapest member and must be run.
- **F2 — the empty table.** A module graph in which **no** module declares an
  `impl`: `IE` is empty and `check`/`run`/`build`+execute must be unchanged. An
  empty program-global table must be observationally inert.
- **F3 — two colliders with no import edge BETWEEN THEM, plus a bystander, under
  one entry that reaches all three.** Both colliders declare a same-spelled
  interface *and* their own impls; the bystander uses neither; assert the
  bystander's value and diagnostics are unchanged from base. This is the
  cross-module-collision-without-an-import-edge hazard stated as a fixture.

  🚨 **The no-import-edge property must hold between the two COLLIDERS, and the
  entry must import all three — an earlier draft said "a third module that imports
  neither", which would have graded nothing.** The loader is **entry-rooted**:
  `loadProgramFilesE` is one DFS that recurses over `directImports` from the entry
  module and nothing else (`compiler/driver/loader.mdk:860-887`, with `:462-463`'s
  *"there is exactly ONE DFS"*; `analyzeProject` takes the same `entry` +`roots`
  pair, `compiler/driver/diagnostics.mdk:798-799` — DERIVED at `da16471c`; the
  only directory-walk enumeration in the tree is `compiler/tools/refindex.mdk`'s
  #254 whole-project index — `moduleIdOfPath` exists for it, `loader.mdk:112-118`
  — whose consumers are `tools/lsp.mdk` and `tools/mcp.mdk`, not `check`/`run`/
  `build`). So
  a module no import edge reaches is **never loaded, never parsed, never
  checked** — a fixture whose bystander is the entry would leave both colliders
  outside the graph and go green having exercised no collision at all. Shape it as
  `main.mdk` importing all three, with the edge omitted only between the two
  colliders.
- **F4 — a bystander inside the collision fixtures.** The #1438 and #1265
  fixture shapes each gain a sibling module that uses neither interface and
  asserts its own value, graded on the **built and executed** binary — the pins
  themselves only grade the colliding module.
- **F5 — a permutation differential.** Permute module declaration order and
  import-clause order across F3 and require identical output. Goldens cannot see
  an over-widening; a permutation can. Permute what the mechanism reads (module
  order, per #1381's lesson), not only what is convenient.
- **F6 — declared non-flips.** `1265-…`, `1438-…`, `1216-…` and `1383-…` must
  all stay RED, declared before the run so a flip reads as the break it is.
- **F7 — the E1 tripwire.** `test/diff_compiler_check_cli_modules.sh` carries
  A-3's unmarked #1277 acceptance legs (run + build) and is a landing gate for
  this unit.

`test/lint_fixtures/derivable_needs_datadecl.mdk` is load-bearing coverage
here — it is the only thing asserting that a user impl α-equal to a prelude impl
stays accepted, and A-3.7 (not A-3.4) is where it is at risk. Do not tidy it.

### 9.8 Exit criteria, and the bar

1. `IE` is built once, inside `buildDeclEnvs`, ordinal-tagged, every read through
   `declEnvVisibleAt`; the filter is ON. ⚠️ This item ended "and A-3.6 remains one
   predicate body" — see the retraction in §9.2: A-3.6 (#1558) SPLIT the predicate,
   so `IE`'s candidacy read is now `ieCandidacyVisibleAt` (graph-global) while its
   decl-time existence read stays on `declEnvVisibleAt`. A-3.4's own exit criterion
   is unaffected; only the sentence about A-3.6's future shape was wrong.
2. Ratchet check 4 live, with its **four** positive controls **G/H/I/J**
   (§9.3 leg 2) executed and their results reported in the PR body — not reasoned
   about. **J is the load-bearing one**: delete the banner, and check 4 must FAIL
   rather than pass on an empty block. If check 1's extraction is extended to
   `DeclEnvs` (§9.3's corollary), its rogue-field control is executed and reported
   too, bringing the reported count to **eleven** (six existing + G/H/I/J + that
   one). ⚠️ Report the controls you ran, not a count you copied from here.
3. 🚨 **`driver_allowed` must NOT gain an `IE` row — amend the existing
   `declEnvsRef` row instead.** DERIVED at `da16471c`, and this reverses what an
   earlier draft of this item directed: check 1 compares **exact sets** — it
   `sed`-extracts `driver_actual` from the `  | DriverState {` record and tests
   `[ "$driver_actual" /= "$driver_expected" ]`, where `driver_expected` is the
   first word of every `driver_allowed` row
   (`test/registry_keying_ratchet.sh:229`, `:236-239`, `:266-274`). §9.4 puts the
   new field **inside `DeclEnvs`**, not on `DriverState`. So an `IE` allowlist row
   with no matching `DriverState` field **fails check 1** — inside
   `typecheck_compiler_source.sh`, inside the required `soundness` job. The row to
   edit is `declEnvsRef` (`:209`), whose own text — *"ENVELOPE ONLY -- it carries
   no CE/IE/DataEnv contents"* — goes false the moment PR1 lands, and which
   already names this unit: *"A-3.2/A-3.3/A-3.4 add those fields and populate them
   inside `buildDeclEnvs`"*. On PR2 `cross_allowed` **loses** the three `obUniv*`
   rows as that row grows to own their contents. A row added with none removed has
   not moved the arc — and here the progress signal is a row *growing*, exactly as
   `declEnvsRef` predicts of itself. Plus §9.3's corollary: extend check 1 to
   `DeclEnvs`, so the bundle `IE` actually lives in is pinned at all.
4. Zero program-output golden movement. Two compiler-source goldens move: the
   `typecheck.md` snapshot (bless via
   `sh test/diff_compiler_snapshot_frontend.sh --bless compiler/types/typecheck.mdk`
   — the `_frontend` suite, not `_types`) and
   `test/selfproc_goldens/legA/types.typecheck.golden`, **additive-only**.
5. `test/selfcompile_fixpoint.sh` C3a+C3b, `test/typecheck_compiler_source.sh`
   (which runs the ratchet), `test/diff_compiler_selfproc.sh` grading for real
   (not exit 2), `test/diff_compiler_engines.sh` under
   `MEDAKA_REQUIRE_WASM=1` — an unlabelled engines number is a two-engine number.
6. F1–F7 above; zero must-fail flips, declared in advance.
7. `InstRef` exists and is read by no judgment, documented as A-3.7/B-2's input.
   ⚠️ **No longer true as of A-3.7 (#1559)** — `cohImplOfRow` reads `instRefMid`, so
   `InstRef` now has one judgment reader. Kept as the A-3.4 exit bar it was; do not
   re-derive today's state from it.
8. 🚨 **An INTERLEAVED wall-clock A/B on the self-compile is a LIVE REQUIREMENT,
   not a blocked bar.** This item read *"BLOCKED, not satisfied: its only
   instrument (`test/bench.sh`) does not run on this project's Linux box
   (#1187)"* — **that is stale and the citation has flipped.** MEASURED
   2026-08-10: **#1187 is CLOSED** (`2026-08-01T18:55:57Z`, via
   `gh issue view 1187 --json state,closedAt`), fixed by `8d358f00` *"bench.sh
   measures on Linux — portable timing arms, per-arm RSS units"*; `test/bench.sh`
   now probes three timing arms in preference order and takes the GNU
   `/usr/bin/time -v` arm on this box, converting **KB→MB** RSS
   (`test/bench.sh:78-96` the detection block, `:130-134` the GNU arm; MEASURED — `/usr/bin/time -v true` prints
   `Elapsed (wall clock) time` here, which is the exact predicate its detection
   block tests).

   **Why this is a requirement and not a nicety.** A-3.4 adds a **whole-graph
   table built on every compile** to a stage `AGENTS.md` calls **GC-bound**, and
   PR1's entire cost justification is *"byte-identical"* — which is a statement
   about output, not about time or allocation. Byte-identical output is fully
   consistent with a self-compile regression.

   **The bar:** `sh test/bench.sh` `selfcompile`, min-of-N, on a quiet box
   (`compiler/PERF-SCOPE.md` §2b), **arms ALTERNATED A,B,A,B… — not all of A then
   all of B.** Interleaving is not pedantry: a shared box drifts under other
   agents' load, and a blocked run is exactly how a drift gets attributed to the
   diff. State the minimum detectable effect and the invocation that produced the
   number. ⚠️ `bench.sh` times `./medaka` in **its own tree** and has no built-in
   A/B mode, so two arms means **two worktrees, alternated by hand** — and
   `.claude/workstreams/TYPECHECK.md` trap 14 applies: `MEDAKA_STRICT=1` makes a
   two-binary differential impossible from one tree, and an exported
   `MEDAKA_ROOT`/`MEDAKA_EMITTER` silently crosses the arms. Also budget the
   `benchmark-emitter` skill's two-rebuild rule if the emitter itself moves.

   Report allocation alongside time — allocation is deterministic and time is not
   (`.claude/workstreams/TYPECHECK.md` trap 9) — but **allocation alone does not
   discharge this item**: a whole-graph fold that allocates the same rows the
   accumulators already allocate can still cost time. If the A/B cannot be run,
   that is an **owed measurement stated as owed**, not a pass.
9. #829: `DeclEnvs`/`DeclEnvModule` keep at least one interior comment each, and
   any new commented field is diffed by eye after `fmt --write`.

### 9.9 What would falsify this design

- **A program-output golden moves on PR2.** Then §9.5's equality is false — the
  prefix build and the accumulator differ in population or in order. Land PR1
  alone; do not bless.
- **`IE` needs a method-name key component** to answer something A-3.4 promises.
  Then §9.3's split (`IE` = impls · `CE` = interface defaults · B-2 = emit words)
  is wrong, and it is an **owner-level re-adjudication**, not a local patch.
- **Any `IE` read needs an entry at ordinal > current.** Then the filter is not
  equality-preserving and A-3.6 is being done early, under #1482's open gate.
- **#1265's pin flips.** `IE` absorbed the default arm, or the emit words moved.
  Revert; that is B-2's.
- **#1438's pin flips.** The bare compatibility leg was dropped; that drain is
  #1482's and its own fixture set has to come with it.
- **`InstRef` turns out not to be unique** (two impls sharing one) — then the
  mint is not the single enumeration point it claims, and A-3.7's coherence
  tightening would inherit the very defect it is waiting on.
- **The interleaved A/B shows a self-compile regression beyond the stated minimum
  detectable effect.** Then the whole-graph build is not free and `IE` must be
  built incrementally, which changes §9.5's equality argument. ⚠️ **This
  falsifier is live and unconditional** — it used to open *"#1187 lands a harness
  and …"*, which parked it behind an issue that had already closed nine days
  earlier (§9.8 item 8). There is no conditional left: run it.
- **The PR1 shadow-compare panics** (§9.5). Then either the algebra or `DL` is
  false, and the instrument has told you which module and which bucket — that is
  the outcome it exists for, and it is cheaper than PR2 discovering it through a
  golden that cannot see order.

---

## 10. U1b — the vector-obligation predicate's interface half: the naming contract

Landed by the PR that implements **#1482**. This section exists so the contract is
defended by `make docs-links` / `make agent-doc-symbols` instead of by an issue comment.

### 10.1 Three meanings, one shape — and how the shape stopped being ambiguous

Before U1b, `compiler/types/typecheck.mdk` used `(String, List Int)` for **two unrelated
things**, 58 lines apart, with only a convention keeping them out of each other's readers:

| | table | payload before | the `String` meant |
|---|---|---|---|
| **M1** | `schemeObligationsRef` (+ `coreSchemeObligationsRef`, `crossModuleSchemeOblsQualRef`, `importedSchemeOblsRef`) | `List (String, List Int)` | **interface name** + scheme-var id vector |
| **M2** | `funConstraintsRef` (+ `methodConstraintsRef`, `scopeArities`, …) | `List (String, List Int)` | **function name** + its dict-slot ids |
| **M3** | `funConstraintIfacesRef` (+ its two mirrors) | `List (String, List String)` | **function name** + slot-parallel interface names |

U1b widens M1's and M3's **interface** half to the identity-carrying `IfaceRef` (#1446 P1):

- **M1 → `VecObl { voIface : IfaceRef, voIds : List Int }`**;
- **M3 payload → `List IfaceRef`** (no record: a bare list is already unambiguous);
- **M2 → UNCHANGED.** It is #1425's substrate (`checkModuleFullImpl`'s bare seed,
  `scopeArities`, `attributeModuleArities`); re-typing it under an open S1 mid-excavation
  buys nothing here.

**The widening IS the disambiguation.** With M1 out of `(String, List Int)`, the fn-name
meaning is that shape's only inhabitant, so passing one family's value to the other
family's reader is an ordinary type error in the compiler's own typechecker — defended by
`make check-self` and `test/typecheck_compiler_source.sh`, not by a naming convention. No
`type` alias was introduced: this file has none, and an alias carries no nominal identity
the compiler could check.

### 10.2 The pairing point — `CSlot` and `pairSlots`

`qualConstraintFor` used to return `(List Int, List String)` built from **two independent
table lookups, each defaulting to `[]`**, so a hit on one with a miss on the other produced
a slot-parallel length mismatch **by construction**. Three separate downstream zips then
truncated it away silently, each carrying a comment saying it did so — the comments were
there and the family grew anyway.

U1b makes the mismatch unrepresentable **downstream of one function**:

- `data CSlot = CSlot { csIface : IfaceRef, csId : Int }`;
- `pairSlots : List Int -> List IfaceRef -> List CSlot` is the ONLY place an id list meets
  an interface list, and the mismatch policy lives there, once;
- `qualConstraintFor : String -> Option (List CSlot)` and
  `declaredConstraintSlots : String -> List CSlot`;
- **`shatterVecObls` is deleted** (its zip is gone; `vecOblsOfSlots` lifts already-paired
  slots), and `recordCallObligations` / `expandSupersEntry` / `shadowStandaloneDictSlots`
  each lose one of their two parallel lists.

**Policy: truncation is preserved byte-for-byte.** Diagnosing a mismatch instead is only
safe once someone has MEASURED that no real program reaches one; that experiment is not
done, so the default stands.

### 10.3 What stays keyed by SPELLING, deliberately

Carrying identity is not the same as *asking* an identity question. These readers keep
comparing `irName`, and each would change behaviour if re-keyed:

- every **display** surface (`ppSchemeCon` / `renderConstraintCtx`) — otherwise every
  rendered `Num a =>` moves;
- the **dedup/coverage** currency (`vecOblKey`, `containsVecObl`, `pairsOfVecObls`,
  `cslotKey`, `censusSuperSlotsOf`) — `cslotKey` decides how many dict slots a constrained
  fn has, so an identity key would move emitted dict **arity**;
- the **routing** goal (`pushDictApp`'s iface component, `resolveDictApps`) — a route word
  against the spelling-keyed `KeyBuckets`, kept that way by #1317 T1 / the closed S0 #1277;
- `groupConstraintMonosRef`, whose only reader compares interface names.

### 10.4 The bare compatibility leg: CORRECTED drain condition (superseded by §10.7)

`insertUnivImplKeys`'s in-source comment said *"both `ifaceRefBare` call sites disappear …
delete it then, and #1438 drains with it."* **It counted two against a set of three**, and
keyed a destructive instruction on a condition no single unit would satisfy. U1b retires
the two it named; **the leg stays**, because `recordImplObligation`'s method-occurrence
goal still mints a bare `IfaceRef`. That producer is **#1507** — a decl-layer /
occurrence-layer reconciliation, not a table widening. Do not delete the leg on a count in
prose: `grep -n ifaceRefBare compiler/types/typecheck.mdk`, and delete it only when every
remaining hit is the definition itself.

⚠️ **U1c (#1507) closes that producer — and the drain condition is STILL not met.** See
§10.7: a census of `ifaceRefBare` call sites is not the same question as "does this leg
still catch a live bare goal", and a MEASURED experiment on U1c's own branch shows it does.

### 10.5 Measured: #1438's PINNED INSTANCE drained at U1b; the CLASS did not (until U1c)

The scope ruling on #1482 predicted #1438 would drain at #1507. **Half of that is false and
half is true, and conflating them is the trap.** Both halves are MEASURED on a cold-built
binary of the implementing branch.

- **The pinned instance drained at U1b.** #1438's repro uses a SIGNED forwarder
  (`useBulk : Sizer b => b -> Int`), so its goal comes from the signature `=>` slot —
  `qualConstraintFor` → `declaredCrossModuleObls` → `recordSchemeCallObligations`, U1b's
  channel. It now rejects (`No impl of Sizer for Int`, exit 1); its `must_fail` pin flipped
  green and was replaced by the positive rows
  `test/dict_fixtures/i4-xmod-sig-constraint-{foreign-iface-rejected,own-iface-control}`.
- **The class did not drain at U1b.** Delete one line — the forwarder's signature — and the
  same program was a silent accept again: `check` exit 0, `run` E-PANIC `unbound
  identifier: bulk`, `build` exit 0, and **the built binary segfaulted at 139**. The goal
  was posed by a bare METHOD OCCURRENCE, `recordImplObligation`'s producer, which still
  minted `ifaceRefBare` on the U1b branch. Pinned at
  `test/must_fail_fixtures/1507-xmod-iface-name-collision-method-occurrence/` — the minimal
  pair of the deleted fixture, and (until U1c) the only assertion of that S0 in the tree.
- **U1c (#1507) closes this remaining reach.** `recordImplObligation` now records `iface`
  (already identity-carrying, read straight off `methodIfaceParamsRef`) instead of
  `ifaceRefBare iface.irName`. MEASURED, on U1c's own cold-built binary: the pinned repro
  above now REJECTS (`No impl of Sizer for Int`, exit 1) on `check`/`run`/`build` alike; the
  `must_fail` pin is retired and replaced by the positive pair
  `test/dict_fixtures/i4-xmod-method-occurrence-{foreign-iface-rejected,own-iface-control}`.
  A THIRD instance of the same class — the method occurrence and the foreign impl's
  interface-name occurrence arriving from two DIFFERENT modules, neither the call site's own
  — was built fresh for this unit (not merely predicted) and MEASURED identically: silent
  accept + SIGSEGV(139) on `main` before U1c, `No impl of Same for P` after. See
  `test/dict_fixtures/i4-xmod-method-and-iface-different-modules-{rejected,control}`.

⇒ **#1438's obligation-channel reach is now fully guarded.** Whether the issue itself
closes is a separate call for its own thread (other reach through this same collision may
still exist outside the `ImplUniverse` obligation channel — e.g. coherence, §10.6's first
bullet, keys the interface half by spelling and was explicitly out of scope for both U1b and
U1c).

⚠️ This section originally read *"#1438 drained HERE, not at #1507"*. That came from a
fixture flipping green, which is evidence about an instance and never about a class — the
same distinction PR #1480's body drew for itself one unit earlier. It was caught in
adversarial review by someone building the variant the fixtures did not cover, which is the
cheapest check available and the one a green corpus cannot perform for you. The correction
made then (splitting §10.5 into "instance vs class") is why §10.7 below insists on the same
discipline for the compatibility leg's drain condition: a producer census answers a
different question than "is there still a live bare goal", and only the second one decides
whether the leg is dead weight.

### 10.6 Not settled here

- ~~**Coherence still keys the interface half by SPELLING**~~ — ✅ **SETTLED at A-3.7
  (#1559).** `CohImpl`'s first field is an `IfaceRef` and `cohScanInner` compares it with
  `cohSameIface` = `sameTyConHead`, so the two checkers now agree about whether two
  same-spelled interfaces are one class. ⚠️ **This drains coherence's REACH of #1438; it
  does NOT drain #1438**, whose obligation-channel bare-spelling leg is #1482/U1b's and
  stays (`insertUnivImplKeys`' DO-NOT-DELETE block). **#1438 remains OPEN** — its
  must-fail pin, authored inside A-3.7 and observed reproducing pre-fix, is drained by
  the coherence half alone. Note also which predicate: `sameTyConHead`, never
  `ifaceIdMatches` — coherence is an ACCEPTANCE question, so an absent origin must make
  no claim; the inverse would turn every unstamped-origin conflict into a silent accept.
- The `ifaceForInferredId` fallback that recovers a slot's interface from `pendingDictApps`
  is bare **by construction** — that channel stores route words (§10.3). ⚠️ It is NOT
  established that this fallback is goal-producer-free: TRACED (not instrumented) in
  §10.7's revised census note, its value is written into `funConstraintIfacesRef`, which
  `declaredConstraintSlots` reads and `recordCallObligations` turns into a `PCallSlot`
  `ImplUniverse` goal. A fourth reason the leg stays, not a closed question.

### 10.7 U1c — the method-occurrence goal, Step 0's ruling, and the drain condition's real state

Landed by the PR that implements **#1507**, sequenced after U1b (§10).

**Step 0 — the decl-layer / occurrence-layer ruling.** Ratified by the repo owner on
#1507: [issuecomment-5248859630](https://github.com/MedakaLang/medaka/issues/1507#issuecomment-5248859630)
— *the class a method-occurrence goal names is the
interface that DECLARES the method the occurrence resolved to, carrying that `interface`
declaration's I4 identity `(originModule, name)`.* There is no competing "occurrence
layer" — an interface-name occurrence is *resolved to* a declaration identity, so
`DImpl.implOrigin` and `DInterface.ifaceOrigin` are the SAME layer (one assigned at the
`interface` decl, one resolved-to at each occurrence), and comparing them is not the
category error the retired ban at `recordImplObligation` (`compiler/types/typecheck.mdk`,
in-source, from #1480 through U1b) asserted. That same ruling carries the re-export-merge
carve-out §10.7's own census note records below, and an explicit scope limit: the ruling
does not by itself license deleting the bare compatibility leg (§10.4/§10.5 remain the
authority on that). This section is the argument's home; `recordImplObligation`
(`compiler/types/typecheck.mdk`, `grep -n 'U1c (#1507)'`) keeps a pointer whose own sentence
states the live rule, so a reader at the code site learns the constraint without leaving it.

**The retired ban's premise, and why it was wrong.** From #1480 until U1c a DO-NOT-RESTORE
ban stood at `recordImplObligation`'s method-occurrence arm. Its premise: `stampDeclOrigin`
("which module DECLARES this interface") and `fillIfaceOccOrigin` ("what did this occurrence
RESOLVE to") are two stampers answering two INCOMPARABLE questions. That premise was wrong —
they answer the SAME question, "which interface declaration does this name denote", from two
vantage points that PRODUCE THE SAME VALUE wherever resolution has a unique answer, which
`fillIfaceOccOrigin` (via `mapOriginsInDecl`, run in the same scope as every other occurrence
stamp) guarantees for exactly the programs that reach that line. Do NOT reinstate the ban on a
bare assertion that the two layers are "different".

⚠️ **The carve-out: "resolve diagnoses every ambiguous case" is FALSE as a blanket claim**,
and an earlier revision of the in-source paragraph asserted it anyway — a refutation of that
sentence is exactly the shape that would license reinstating the ban, so the limit has to be
explicit. MEASURED, both arms, with two modules each declaring an interface with the same
method name (`p.IP.mth`, `g.IG.mth`) merged into a third via `export import p.{IP,mth}` +
`export import g.{IG,mth}`: a DIRECT double import of the same name is what resolve catches
(`Ambiguous occurrence: 'mth' is exported by both …`, per `importedMethodEntry`); a RE-EXPORT
MERGE of the same collision is **not caught by resolve at all** — `check` exits 0 or 1
depending on nothing but which `export import` line comes first, with no diagnostic either
way. In that shape `scopedMethodEntry` cannot decide it, so `overrideScopedMethods` keeps the
floor's arbitrary last-registered answer and `recordImplObligation` silently inherits it. So:
the two values disagree only in the ambiguous case, unambiguous cases genuinely agree, and a
DIRECT import ambiguity genuinely is rejected upstream — but a RE-EXPORT-MERGE ambiguity is
not. Do not cite "resolve already rejects the ambiguous case" as blanket cover. (Adjacent to
the open #1288 re-export-merge family; not this unit's to fix. Pinned by
`test/must_fail_fixtures/1530-xmod-method-name-collision-reexport-merge`.)

**The change is one token.** `recordImplObligation`'s `pushPendingObl (ifaceRefBare
iface.irName) …` becomes `pushPendingObl iface …` — `iface` is already the identity-carrying
`IfaceRef` `methodIfaceParamsRef` held; the retired code was discarding it. Operationally the
site now discriminates METHOD-OCCURRENCE goals the same way the other three call sites always
did, so the #1438 collision shape reached through a bare method call is REJECTED rather than
silently accepted.

**The other decl-layer goal sites, and the standing condition that guards them.** An earlier
revision of the in-source comment claimed `recordImplObligation` was the ONE decl-layer goal
producer and "the other three are all OCCURRENCE layer". That was true of the sites examined
and FALSE OF THE SET. Census (`grep -n builtinIfaceRef compiler/types/typecheck.mdk`):
`recordIfaceObligation`, `inferNumLitBare`, `numCallObls` and `numDictObls` all build their
goal from `builtinIfaceRef` → `builtinClassOrigin` → `builtinClassesRef`, and
`builtinClassesGo` populates that table by reading `DInterface { ifaceOrigin }`. Four more
decl-layer goals making the same cross-layer comparison U1c cured at this site.

They are unreachable TODAY, and the reason is NOT that they are occurrence-layer — it is that
no user declaration can reach that table's population. MEASURED on both arms: a module IN the
import graph redeclaring one of the four spellings is rejected `Duplicate interface:
Semigroup`, exit 1; a module NOT in the graph is never loaded at all (arbitrary garbage, and
`check` still exits 0), so it contributes no `DInterface` to `builtinClassesGo`'s walk; and a
user `core.mdk` cannot shadow the prelude — `import core.{n}` for a name only the user's file
declares is unresolvable, exit 1. 🚨 The resulting STANDING CONDITION — the defect returns at
those four sites if the duplicate-interface guard is relaxed, if §7.1 U1 makes the prelude a
node (at which point §8 I4 makes two same-spelled declarations legal, which is precisely what
removes the guard), or if a fifth `BuiltinClass` is added whose spelling the guard does not
cover — is kept **in-source at `builtinIfaceRef`'s own definition**, because it is a condition
those sites must maintain rather than a fact about U1c. The safety is a property of the
LANGUAGE's current namespace rules, not of this channel.

**What "third and last" means, and what it does not.** `recordImplObligation` is the THIRD and
last of the `ifaceRefBare` GOAL PRODUCERS — U1b retired the other two
(`schemeObligationsRef`, `funConstraintIfacesRef`). Two other goal producers
(`recordSigConstraintObls`, `recordMethodLevelSlotObls` via `constraintOrigin`,
`reqToObligation` via `requireOrigin`) already carried identity before U1c, filled by the SAME
walk in the SAME scope as `implOrigin`, so they agree with it by construction.
⚠️ **That is NOT a claim that the `ImplUniverse` channel has only three or four goal producers
total.** It does not: `recordCallObligations`' `PCallSlot` predicate, the
`builtinIfaceRef`-derived sites above, and others besides all push a `Predicate` into the same
channel — a derived count of the WHOLE set is at least six. "Last of the three" means only
"last of the sites that ever minted `ifaceRefBare`", the narrow claim the census supports; do
not read it as "last of N total producers" for any N not independently re-derived.

**Why identity at this site matters — #1288's own reproduction, verbatim and measured.** A
`mid.mdk` doing `export import p.*` + `export import g.*` merges two unrelated `Same`
interfaces; an importer's `impl Same P` gets `implOrigin = g` while the method `pmth` it
defines belongs to `p.Same`, and the goal `TkIdent p Same` misses the impl's `TkIdent g Same`
bucket. Result: `No impl of Same for P` on a program whose `impl Same P` is three lines up,
with no syntax available to say which `Same` was meant. The bare compatibility leg does NOT
cover this — it protects goal-WITHOUT-identity against impl-WITH-identity, and this is
goal-with-identity against impl-with-a-DIFFERENT-identity.

**Census check, done rather than assumed — and narrower than an earlier revision claimed.**
After this change exactly one `ifaceRefBare` call site remains besides its own definition —
`ifaceForInferredId`'s `pendingDictApps` fallback (§10.3). That site is bare BY
CONSTRUCTION (§10.3's route-word discipline), but **it is not established that it is
goal-producer-free**: TRACED, the value it mints is written by `registerInferredFor`
into `funConstraintIfacesRef`, which `declaredConstraintSlots`'s `None` arm reads,
which `inferDictAtFound` turns into a `recordCallObligations` call, which pushes a
`PCallSlot` `ImplUniverse` `Predicate` for any slot whose `csIface.irName /= ""` — the
same channel this whole unit is about. Not independently verified whether a live call
site can actually drive this exact path to a non-`""` bare iface (the two fallbacks tried
before it may already cover every reachable case) — recorded as open, not resolved either
way. §10.6's parallel note carries the same correction.

⚠️ **This census answers "which sites still mint `ifaceRefBare`", not "is the leg still
needed" — those are different questions, and §10.7's next paragraph exists because
conflating them is exactly the mistake this section corrects.**

**⚠️ The drain condition is NOT met, and a census of `ifaceRefBare` is the wrong instrument
to answer that question — MEASURED, not inferred.** §10.4's "delete the leg once every
remaining `ifaceRefBare` hit is the definition" was itself imprecise: it conflated "no
producer strips identity" with "no bare goal can arise", and those are different claims.
`methodIfaceParamsRef` can hold an `IfaceRef` whose `irOrigin` is `OriginUnresolved` because
nothing upstream ever stamped one — not because a producer discarded it — and
`recordImplObligation` forwarding that value faithfully (the entire point of this unit)
still mints a bare goal in that case. Two sources were checked, on this branch's cold-built
binary, by temporarily dropping the bare key from `oblIfaceKeys`'s identity-bearing arm
(`_ => [oblIfaceKey ir, TkBare NsIface ir.irName]` → `_ => [oblIfaceKey ir]`), rebuilding,
and reverting — not landed:

- **`main = println 1` and `compiler/driver/medaka_cli.mdk`** (a user program importing the
  prelude, in flat/no-module-graph mode) — CLEAN with the leg removed. #1227 already closed
  this shape: `stampFlatTyOrigins`'s occurrence layer stamps a prelude interface occurrence
  `core` even with no module graph, and `checkProgramSeededSplit` separately stamps the
  prelude's OWN declarations `core` too, so goal and impl already agree on identity without
  the leg.
- **`medaka check stdlib/core.mdk` directly** (the prelude checking ITSELF as the entry
  file) — REGRESSED from exit 0 to **exit 1 with 32 `No impl of <Iface> for <Ty>` false
  rejects** (re-derive with `grep -c 'No impl'` rather than trust this number;
  `Ord`, `Eq`, `Foldable`, `Mappable`, …) with the leg removed; clean again with
  it restored. Checking `core.mdk` as the entry reaches `checkProgramSeeded` with
  `coreProg0 = []` (the "prelude already flattened into `prog`" arm), so `core.mdk`'s own
  interfaces and impls are stamped against a scope that never includes `core.mdk`'s own
  declarations — no identity on either layer, for either side of the match.

⇒ **The bare compatibility leg stays.** U1c retires the third and last `ImplUniverse`
GOAL-PRODUCER, which is real progress and is what closes #1438's remaining reach (§10.5).
It does not retire every SOURCE of a bare goal — the flat prelude self-check is a fourth,
producer-independent source, has no owner, and is live today. Whoever attempts to delete
this leg next must re-run the `stdlib/core.mdk` experiment above (or a stronger one) and get
a clean result, not just grep for `ifaceRefBare`.

**Fixtures.** The retired pin
`test/must_fail_fixtures/1507-xmod-iface-name-collision-method-occurrence/` is replaced by
the positive pair `test/dict_fixtures/i4-xmod-method-occurrence-{foreign-iface-rejected,
own-iface-control}`. A second, freshly-built pair covers the class instance where the method
occurrence and the foreign impl's interface-name occurrence arrive from two different
modules, neither the call site's own module:
`test/dict_fixtures/i4-xmod-method-and-iface-different-modules-{rejected,control}`.

**The false-reject risk this unit specifically owed a check.** A collided method name whose
`scopedMethodEntry` (`compiler/types/typecheck.mdk`) returns `None` falls back to
`overrideScopedMethods`'s floor entry — an ARBITRARY winner among the colliding
declarations, picked before this unit existed. Restoring `iface`'s identity in
`recordImplObligation` means that arbitrary winner's identity now reaches the obligation
goal where it previously didn't. Built and MEASURED (two modules `p`/`g` each declaring an
interface with the SAME method name `mth`, imported into a third module transitively through
a re-export merge so `scopedMethodEntry` cannot decide it and the floor's answer governs): a
program shaped this way is REJECTED with the SAME message, at the SAME location, on BOTH the
pre-U1c and post-U1c binary (`No impl of IG for W`, `check`/`run` exit 1). This is a
PRE-EXISTING false reject, not one this unit introduces — the floor's arbitrary identity was
already reaching some OTHER dispatch-relevant consumer of `methodIfaceParamsRef` before this
change; `recordImplObligation` merely stopped being the one place that discarded it. Filed
nowhere yet; out of scope for #1507 (the collision is really `scopedMethodEntry`'s own class,
adjacent to the OPEN #1288 re-export-merge family), noted here so it is not rediscovered
as "caused by U1c".

---

## 11. A-2.0 registry substrate — the `RegKey` design record

Relocated verbatim (with the Medaka `-- ` comment prefix stripped) from
`compiler/types/registry.mdk`, which carried it as in-source header prose for the module
landing the `Registry`/`MultiRegistry`/`SetRegistry` combinators (A-2.0, #1111, §2 K / §6 A-2
above). A pointer sentence stands at the extraction site in source.

### 11.1 What the target tables need: COMPOSITE keys (`RegKey`)

An `Ident` names ONE declaration, and at least five tables A-2 must convert
are keyed by a TUPLE. Sizing the API to `Ident` alone would force each of
those conversions to re-invent a bare-string composite INSIDE the identity
(e.g. stuffing `"Foo@3"` into an `Ident`'s name field), which re-introduces
exactly the un-keyed string this arc exists to remove and forces a lie
about which `Ns` the thing is in. So `RegKey` is the key type and `Ident`
is its one-element case:

  ⚠️ #1112 A-3.4 PR2 renamed one row's ANCHOR, not its key: the concrete
  obligation bucket used to be cited as `obUnivConcreteRef`, a `CrossRun`
  accumulator that unit DELETED. The key is unchanged; it is minted by
  `insertUnivImplAt` into `ImplUniverse`, which the Module path now gets
  from `ieUniverseAt` and the Flat path from `buildImplUniverse`.

  | table                            | key                      | site          |
  |----------------------------------|--------------------------|---------------|
  | `universeIfaceParamKinds`        | TabKey × Int  ✅ A-2.4    | typecheck.mdk |
  | `ImplUniverse` concrete bucket   | Ident × Ident            | typecheck.mdk |
  | `checkCallObligationsU` dedup    | Ident × [Option Ident]   | typecheck.mdk |
  | `methodReqCountRef`              | Ident × Ident            | eval.mdk      |
  | `ifaceDispatchRef`               | Ident × Ident            | eval.mdk      |

Three of the five are pure identity tuples (`regKeyN`); one pairs an
identity with a parameter SLOT, which is an ordinal and not a declaration —
it has no namespace and no origin, so it is carried in `RegKey`'s second
component (`regKeyTabAt`) rather than faked as an `Ident`.

⚠️ ROW 1 SAID `Ident × Int` UNTIL A-2.4 CONVERTED IT, AND THE CORRECTION IS
NOT COSMETIC. `Ident` has no identity-less inhabitant by design, and this
table is read on the FLAT driver path as well as the module path
(`checkGradedImplTys` ← `checkBodyImpl`, shared by both arms), where every
user declaration is `OriginUnresolved` until #1115. An `Ident`-only key
would have silently stopped registering and looking up anything there — see
`RegKey`'s own doc-comment for the full derivation. The remaining four rows
are stated as A-2.0 sized them; the unit that converts each owes the same
question ("is this table read on the flat path?") rather than inheriting
this row's answer.

🚨 `ifaceDispatchRef` HAS NOW BEEN ASKED THAT QUESTION, AND THE ANSWER IS
YES — SO ITS ROW ABOVE IS MIS-SIZED. #1113 Phase 4 re-keyed that table and
measured the flat-path half: the flat/loader-less drivers (`medaka check`
on a no-import file, `lsp`, `repl`, `doc`, the playground) stamp nothing
(`stampFlatTyOrigins`), so on those paths EVERY row and EVERY query carries
the absent identity and an `ifaceIdMatches` tier answers None for all of
them. Its key is therefore NOT the `Ident × Ident` this row states: it is
TWO-TIERED — identity when one is present, bare SPELLING when it is not —
and `lookupPositions` (`eval.mdk`) is where both tiers live.

⚠️ A `regKeyN [ifaceIdent, methodIdent]` conversion DELETES THE SPELLING
TIER, and the loss is silent: `Ident` has no identity-less inhabitant, so
every flat-path lookup would miss and fall through `lookupPositions`' `[0]`
fail-open default, quietly changing arg-tag admissibility — and therefore
dispatch — on all five drivers above. That is ROW 1's hazard exactly, one
row down, which is why this is written here rather than left for the next
agent to re-derive. Until identity SUPPLY is total (#1115 E-1 gives the
flat path module ids) this row's honest sizing is `(Ident | String) ×
String`; at total supply the spelling tier becomes dead and the row becomes
true as written. `methodReqCountRef` — installed from the same decl list by
the same call — has NOT been asked this question and still owes it.

🚨 THE FIFTH ROW IS `[Option Ident]`, NOT `[Ident]`, AND THE DIFFERENCE
RE-OPENS #607. This row read `Ident × [Ident]` until round 2 of this PR's
review; that shape is not merely imprecise, it is a live conflation hazard,
so the derivation is spelled out here rather than left to the next unit.
The key today is (`types/typecheck.mdk:15171`):

    let key = joinWith "," (iface :: map (o2 => optionOr "" (headTyconMono o2)) occs)

`headTyconMono : Mono -> Option String`, so a POSITION CAN BE ABSENT and
the `""` is a POSITIONAL PLACEHOLDER, not a name. Absent positions really
do reach this key on the dedup channel: `checkOneCallObligation` has an
explicit `else if not (allConcreteHeads args)` arm (`:15214-15215`) which
on the CALL channel (`dedup=True`) runs `checkUndeterminedObligations`, so
a non-ground obligation is checked AND its key is added to `seen`.

Concrete failure the `[Ident]` shape invites. Take `interface Ix a b` and
two CALL-channel obligations `Ix Int b0` (argument 1 undetermined) and
`Ix a0 Int` (argument 0 undetermined). Today the keys are `"Ix,Int,"` and
`"Ix,,Int"` — DISTINCT, so both get an ambiguity diagnostic. Convert to
`regKeyN (ifaceIdent :: presentHeads)` — which is what `Ident × [Ident]`
implies, since an `Ident` cannot be absent — and both become the SAME
`RegKey`; the `dedup && contains key seen` guard skips the second and ONE
DIAGNOSTIC IS SILENTLY LOST. That is exactly the conflation the
whole-vector key was introduced to prevent (`typecheck.mdk:15161-15163`,
#607), re-introduced by a key shape that cannot express absence.

The chosen ENCODING, so the next unit does not have to re-derive one. Absence is
positional, so carry the positions in the ordinal block, which is what it
is for:

    regKeyNAt (ifaceIdent :: presentHeads) (arity :: presentIndices)

where `presentHeads` are the identities of the positions whose
`headTyconMono` was `Some`, in argument order, and `presentIndices` are
those positions' 0-based indices. Injective: `regKeyRender` already reads
the ident count, then exactly `4n` netstrings, then ordinals, so the two
blocks never interfere. On the example, `Ix Int b0` renders with ordinals
`[2, 0]` and `Ix a0 Int` with `[2, 1]` — different keys, both diagnostics
kept. The `arity` element is not decoration: WITHOUT it the encoding is
injective only if an interface's arity is fixed, which is true today but is
an unstated premise living in another file; with it, injectivity is a
property of the encoding alone.

⚠️ A SECOND ABSENCE, in the same row, from a different cause. Turning a
`headTyconMono` name into an `Ident` needs that head's `TyConOrigin` —
`Mono`'s `TCon String TyConOrigin` carries one — and on the FLAT
single-file path it is `OriginUnresolved`, so `mkIdent` returns `None`
there for a position whose head IS concrete. So `Option` in this row covers
two distinct facts: "this argument has no head type constructor" and "this
head has no module identity yet". The conversion must not collapse them
into one placeholder: the first is a property of the obligation and must
key differently per position (above); the second is the Module-path-only
residual `Ns`' doc-comment in `frontend/ast.mdk` states, and on the flat
path this table simply keeps its string key until #1115 (E-1).

`regKeyRender`'s injectivity, in one line: the leading netstring is the
IDENT COUNT `n`, so a decoder reads `n`, then exactly `4n` netstrings (the
identity block), and everything after is ordinals. No reading depends on
what any tag or name happens to look like.

⚠️ THE COUNT PREFIX IS DEFENSE IN DEPTH, AND IT HAS NO BEHAVIOURAL WITNESS
— verified by mutation, not asserted. Deleting it leaves the render
injective ANYWAY today, because the alternative reading (an ordinal
netstring mistaken for the start of an identity group) would need some
`nsTag` to be a decimal-digit string, and none is. MEASURED 2026-08-03:
deleting the prefix left every PROPERTY-level doctest in this file passing
(76/76 at the time), which is why the three `startsWith "1:…"` assertions
below were added — they are the only thing that reds it. RE-MEASURED on the
round-2 file (93 doctests): deleting the prefix gives 90/93, and the three
failures are exactly those three lines. So the
prefix buys exactly one thing: it makes injectivity independent of
`nsTag`'s alphabet, an invariant that otherwise lives silently in a
different function and that a seventh namespace could break without any
signal. It is kept for that reason, and those three doctests exist solely
because no property-level test can distinguish its presence.

⚠️ COUNTING THE BYTE-SHAPE ASSERTIONS: they fall in two groups with two
different jobs. `startsWith "1:…"` lines pin the ident-COUNT prefix,
described in this paragraph; `identKey … == "…"` and `tabKeyRender (TkBare
…)` lines pin the origin/bare TAG, described at their own sites further
down (A-2.4 added one of each: a count-prefix line on a `TabKey`-built key,
and `tabKeyRender (TkBare NsType "Foo") == "4:type4:bare0:3:Foo"`). All are
the documented exception to `registry.mdk`'s opacity contract. DERIVE the
count from the file, never re-encode it — and match `TkBare`, not the wider
`Tk`, which also catches the identity-arm PROPERTY line (`tabKeyRender
(TkIdent …) == identKey …`) that asserts no bytes at all:
`grep -c '^-- > \(startsWith "1:\|identKey ident.* == "\|tabKeyRender (TkBare\)' `
`compiler/types/registry.mdk`.

### 11.2 `regInsert` conflict handling (decided for the A-2.0 unit only)

Per `docs/spec/DICT-SEMANTICS.md` §8 I4, declarations are never rejected —
only USE sites are — so once every table is keyed by `Ident`, two
genuinely distinct declarations get genuinely distinct identities and
coexist; a `regInsert` collision after re-keying means the REGISTRY'S OWN
KEYING is broken (a compiler bug), not a user error to diagnose at the
declaration. `regInsert` is therefore LAST-WRITE-WINS, matching every
existing `universe*` table's current behavior, and `regInsertChecked`
returns a `Bool` alongside the new registry saying whether an existing
entry under that exact key was overwritten — the signal a later unit
(A-2.8) can turn into a diagnostic once the diagnostic-code family
question (`T-INTERNAL-REGISTRY-CONFLICT` vs. a resolve-phase
`R-AMBIGUOUS-*` code) is settled. Deliberately NOT decided here.
So `Registry` is a LAST-WRITE-WINS map, and it must not be described as
a "write-once-or-diagnose" one — that phrase belongs to this design doc's
own description of what A-2 will EVENTUALLY deliver, not to the substrate
module's own behavior today.

### 11.3 What a conversion still has to review, table by table (NOT "pure")

A re-keying is NOT automatically behavior-preserving. At least one named
target: `regEntries` enumerates in `regKeyRender` order (a
sorted `OrdMap`), while several targets are assoc `List`s enumerated in
DECLARATION order — `rejectCyclicAliases` (`types/typecheck.mdk`) walks
its alias table in that order and `emitCyclicAliasErrors` emits in the
order the DFS produced, so converting it moves DIAGNOSTIC ORDER and hence
goldens. Every conversion PR owes an explicit answer to "does any consumer
of this table depend on its enumeration order?", and where the answer is
yes it owes either an order-preserving side list or a reviewed golden
move. What IS preserved by construction is the last-write-wins RESOLUTION
of a duplicate key, not the ORDER a whole-table walk produces.

## References

- [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md) — the derived map this design targets
- `docs/spec/DICT-SEMANTICS.md`, `docs/spec/EFFECTS-SEMANTICS.md`,
  `docs/spec/SHADOW-SEMANTICS.md` — the governing semantics
- `compiler/ARCH-REVIEW.md` (PASS 2), `compiler/DRIVER-COLLAPSE-PLAN.md` — prior
  structural verdicts this design keeps or completes
- `.claude/workstreams/TYPECHECK.md` — the standing gate
- Issues: **#1122 (the epic / stage tracker)**; #991–#995 (adopted),
  #1070/#1084 (family audits), #1082 (locals), #616 (conformance gate, adopted
  into S-1), #820–#824 (graded arc, peer); filed by this arc: #1107–#1121, plus
  the 2026-08-05 audit's units — #1280/#1317 (type-side supply and demand),
  #1318, #1319 (constructors) and **#1337** (values, §6's A-values). ⚠️ The
  epic's own stage table and its amendment comments are authoritative over this
  list and over §6's spine line; do not sequence from either without reading
  them.
