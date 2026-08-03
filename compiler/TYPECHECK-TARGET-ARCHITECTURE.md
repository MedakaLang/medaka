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
does not. §6 is the migration DAG. §7 is verification doctrine. §8 is risks.

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
resolves every occurrence to it, for **all** namespaces: values (already done via
binder ids), types, aliases, interfaces, interface methods, records/fields,
constructors. Two modules may declare the same name; the collision surfaces at a
*use site* as an ambiguity diagnostic (`Ambiguous occurrence`), never at the
declaration, never silently (decided: Haskell/Rust model). The AST carries the
resolution — `DInterface`/`DImpl`/`TyCon` reference identities, not spellings.

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
The current architecture approximates them by marshalling 14-cell universe
snapshots per module (`loadDataUniverse`/`storeDataUniverse`/
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
    leniency at that argument. Write channels (`Ref`/`MutArray`/`HashMap`,
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
| L5 kind checks (`checkGradedImplHeads`) | K + G | Declared kinds (EFFECTS §6.1–§6.5, #822) checked at declaration — **coordinate: #822 owns this machinery; see §8** |
| L6 shadow machinery (both kinds) | R (detect) + S (route) | Surface-name detection at resolve, resolved pair recorded; routing per SHADOW S1–S9, single decision point |
| L7 `checkBodyImpl` spine, `CheckMode`, promotion fixpoint | E | One driver, one mode; fixpoint → scheduled marking (staged: consumers → collapse → schedule) |
| L7 universe marshalling (`load`/`store`/`appendUniverse*`) | K | Retired at E-4 (the marshalling serves the fallback path; a shim survives until then) |
| L7 import seeding/aliasing/ctor overlay | R + K | Visibility filtering at R; identity makes overlay collision-free (#733/#756) |
| L8 error-path machinery | D | Extracted |
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
| A. Bare-name cross-module collision | Identity never acquired at resolve; tables faithfully reflect a pre-collapsed namespace | L2/R: qualified identity substrate; K: identity-keyed environments; registry ratchet | #1047, #1069, #1070 (5 of 7 confirmed + method tables), #1092, #1090 (comment), #733, #756 |
| B. Dispatch key under-discriminates | Selection re-derived downstream from keys coarser than instance identity (bare head tycon; per-module `IE` slice; superset word-sets) | S: one `min⊑` selector at `inst`; evidence references stamped; frozen admissibility; K: global `IE`; emitter word-set retirement | #1072, #1071, #1062; #1046 ◇F-1, #1075 ◇F-1 (both reach dispatch through a local lambda — arg-tag survives at their sites until locals carry evidence); #1068 ◇B-2-wasm |
| C. Locals not dict-abstracted | `gen` applied at only two binder kinds; interim pin merges rigid vars | L4/E: uniform `gen` at every binder (#1082, gated on S-2(f)) | #1040, #1043, #1052 (and the #866-interim pin retires; #866/#1045 themselves are CLOSED) |
| D. Impl/default & Flat/Module forks | Two implementations of one judgment kept in sync by hand | L1/E: `MethodBodyKind` merge; one driver, one stamper order | #992, #873-class, #462 ◇E-2, map §7.6 (unfiled → task E-2) |
| E. Supers flattened & re-resolved | No `entailSuper`; evidence is a flat slot list; 4 duplicate closure walks | L4/S: tree evidence, projection rung, one closure combinator | #993, #679, #741; #323 ◇B-1-scope (drains only if the evidence tree extends to *recursive instance-context* capture and both engines consume it — #993 as filed is supers-scoped; B-1's design doc must decide this) |
| F. Effects rules with unreached arms | Row unifier's leniency is per-arm, position-blind; polarity not computed; coverage counts promises as charges | I/G: per-parameter polarity + index invariance; eliminator obligation; collection-domain fix | #1094-class (spec'd), #1098, #1100, #1103, #797 ◇D-1; #1095 ◇graded-arc (if #823 resolves to the uncharged-signature option, the launder stays representable and only the arc closes it) |
| G. Laundering via method schemes | W3 checked with flexible vars in places; carve-out for Async | G: W3 rigid everywhere; #803 bound keeps pre-unify placement | #830 (gen-sig authority), #819 (adjacent); #817 ◇graded-arc, #825 ◇graded-arc (the arc is a peer, not a subtask — these drain there, not here) |
| H. Obligation storage & deferral drift | 2 storage shapes, dead provenance arms, bespoke numlit channel; deferral policy per-channel by accident | I/S: #991 completion; ONE written deferral policy (B-3's scope); defaulting as specified quiescence step | #991, #563, #564; #845 ◇B-3 (selective-import spelling reaches the declared-obligation channel), #792 ◇B-3 (check-vs-build deferral policy) |
| I. Order-dependent results the spec forbids | Per-module env slices; promotion discard-and-redo; two stamper orders | L3/K/E: whole-graph env, scheduled marking, one order table — ◇S-2(b) (the commitment-timing rule is what makes the schedule order-free for non-generalized bindings) | #1072 (also B), letrec order (owed spec) |
| J. Coherence condition mismatch | Enforced (a) global comparability vs spec'd (c) per-goal minimum | G: per-goal unique-minimum check at `inst` | #311, #614 |
| K. Registry recurrence risk | Nothing prevents the next bare-name table | Registry ratchet (structural check, all bundles + engine frames) | #1070's "owed gate" |

Hygiene items (#176 ref-growth probe, #480 duplicate loc-helpers) ride along
with the stages that touch their code and are listed in §6 rather than here.

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
  a new `test/*.sh` matching no shard pattern silently never runs, and shard
  placement is by cost — `gates (types)` is the measured pole, so placement is
  chosen from a fresh run-cost read, not by theme.
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
  standing five questions in `.claude/workstreams/TYPECHECK.md` as part of
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
  - `universeIfaceParamKinds` is not read off a head tycon at all: its key
    is built by `ifaceSlotKey` from an interface name and a slot index
    (`typecheck.mdk:8504-8505`), and its one read site, `checkGradedImplTys`,
    is called as `checkGradedImplTys iface 0 tys` from
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
- **A-3. Whole-graph declaration analysis (K) — honest scope.** Build
  CE/IE/DataEnv once; the **Module path** reads K; the Flat fallback keeps a
  marshalling **shim** (the 14-cell retirement completes at E-4, whose path is
  the marshalling's only remaining consumer — teaching the fallback to read K
  would mean editing the 20 mode branches E-2 deletes anyway). Impl
  completeness + kind checks move to declaration time (**coordinate with #822**,
  which owns the kind machinery — one of the two arcs rewrites it, not both).
  Error-*ordering* golden drift is enumerated per family (this stage is
  explicitly not byte-identical). Carries the global-candidacy
  could-not-pass-before fixture (R2). *Depends on A-1/A-2; serialize against
  every other typecheck PR.*

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
- **B-3 ⊕ (#991, #994) + the deferral policy.** Obligation storage completion
  and lockstep-pair fusion — mechanical, byte-identical bars, independent of
  Stage A. **Scope extension:** one *written* obligation-deferral policy
  (which channels defer non-ground obligations, and why check and build must
  agree), because #845 (selective-import spelling never reaches the
  declared-obligation channel) and #792 (accepted at check, rejected at build)
  are deferral-*policy* defects that storage unification alone does not drain.

**Stage C — One method-body judgment**

- **C-1 ⊕ (#992). `MethodBodyKind` merge** — as filed, two-unify retained as a
  kind parameter, module-placement probes both ways.
- **C-2 ⊕ (#830). Signature authority** — more-general-than-body ⇒ def-site
  reject (never silent narrowing); vector-valued entailment side condition per
  DICT §9.

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
  this stage — closes it.
- **D-4 ⊕ (#995). Effect-walk convergence** — post-unify checks only; the #803
  pre-unification bound explicitly stays where it is (its exactness is its
  timing); rigid-skolem idealization stays blocked on #817/#820 as filed.

**Stage E — One driver (family D/I) — after A-3; the riskiest stage, now four moves**

- **E-1. Flat-consumer migration.** One PR per consumer, each with its own
  golden accounting: repl, LSP single-file env + hover fallback, playground,
  single-file doctest path, `snapshot`/`check_policy`/`doc`, and the
  `elaborateDict` gate entries (`llvm_emit_typed_main`, `core_ir_dict_pp_main`)
  — each moved onto the 1-module Module path. The Flat-vs-Module divergences
  are enumerated **as a set from the 20 `match mode` branches** (not sampled),
  each getting a fixture before its consumer moves; a numlit-representation
  flip on the single-file path is S0-shaped if unenumerated.
- **E-2. `CheckMode` collapse.** With no Flat consumers left except the
  promotion fallback, collapse the mode branches and the second stamper order;
  the fallback is re-expressed against the Module path (this is where its
  behavior is pinned, not changed). Byte-identical on the Module path;
  enumerated sign-off per divergence fixture for the rest. #462's comment-truth
  item dies here with the single order table.
- **E-3. Defaulting placement** per S-2(c) — **lands before E-4**, so the
  scheduling change happens under an enforced representation rule rather than
  silently moving Int/Float choices (#563/#564 close against the rule).
- **E-4. Scheduled marking.** Replace the promotion fixpoint + harvest-discard
  with per-binding marking on the (existing) SCC schedule per S-2(b)'s
  commitment rule; retire the joint flatten, `dropShadowedCore`, the
  sticky-snapshot hack, and A-3's marshalling shim. Explicit sub-bars:
  reset-lifecycle re-derivation, LSP seam contract test, per-module diagnostic
  attribution unchanged, marked-node universe = all body kinds. *This is R1;
  it does not start until E-2 is green and soaked.*

**Stage F — Locals + extraction + residuals**

- **F-1 ⊕ (#1082). Dict-abstracted locals** — the deferred (C) remedy, on the
  uniform-`gen` substrate, gated on S-2(f); retires the interim pin and #1052
  with it, and completes #1046/#1075's drain (their sites route through
  evidence instead of arg-tag). Calling-convention change across
  typecheck/dict_pass/core_ir_lower/both backends: benchmark-emitter + seed
  re-mint discipline.
- **F-2. Extract D (error-path machinery)** — pure extraction, byte-identical;
  #480's loc-helper dedupe rides in this diff.
- **F-3 ⊕ (#311/#614). Coherence (a)→(c). ✅ COMPLETE 2026-08-01** — landed as four
  ordered PRs, not one: **F-3a** (thread the full goal vector, #1154/#1161),
  **F-3b** (union headless impls into every bucket, #1128), **F-3c** (the
  no-unique-minimum arm becomes a hard `T-AMBIGUOUS-INSTANCE`, #1155 — a
  NARROWING), **F-3d** (`cohClassify` demotes the `⊑`-incomparable half of the
  declaration-time sweep to `W-INCOMPARABLE-IMPLS` — a WIDENING). ⚠️ The "single-PR
  sized" claim below is the sizing error this stage is the record of: c and d move
  acceptance in **opposite** directions, so bundling them makes CI unable to say
  which half moved a golden. Residue: **#1183**.
- **F-4. Hygiene residuals**: #176 (ref-growth probe, after A-3 changes the ref
  population).

**Dependency spine:** S ⟶ A-1 ⟶ A-2 ⟶ A-3 ⟶ {B-2, E-1} ; (A-1a withdrawn —
its decision is made in writing inside A-1, not as a separate node) ;
B-1 ∥ C ∥ D (dependency-independent of A after S; landing interleaved) ;
E-1 ⟶ E-2 ⟶ E-3 ⟶ E-4 ; B-3 anytime after S ; F-1 after C-1, E-2, and
S-2(f) ; F-2/F-3 anytime after S. The graded arc (#822→#823→#824) runs as a
peer, coordinating at A-3 (kind machinery) and D-3 (coverage rules).

**Sizing honesty.** A is weeks of serialized work (every golden family moves at
least once; "fleet-parallel" applies to development, not landing); B-1, B-2 and
E-4 are the three design-first items; B-3/C-2/D-1/F-2/F-3 are single-PR sized.
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
  Flat divergences), F-2 carry byte-identical bars; A and B-2 explicitly do
  not (identity and selection *are* semantics) and say so per golden family.
- **Seed and emitter discipline.** Any stage that perturbs the compiler's own
  emitted IR (A at scale, B-2, F-1) runs the benchmark-emitter two-rebuild
  rule and the twice-run seed re-mint; a stale seed SEGFAULTing the fixpoint
  is a known failure mode, not a signal about the change.
- **The standing five questions** (`.claude/workstreams/TYPECHECK.md`) apply to
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
- **Graded-arc coordination.** A-3 and #822 both rewrite the kind-check
  machinery; D-3 and #823 both touch coverage rules. Whichever lands second
  rebases on the first — named up front so neither arc discovers the other in
  a merge queue.
- **Serialized landing.** Stages A and E occupy the whole `ws:typecheck` lane;
  B-3/C/D provide *development* parallelism, with landing interleaved through
  the one-PR-in-flight rule. The plan claims no more than that.
- **Not in scope:** engine-realization bugs (#1034/#826/#1101/#1020, the
  emitter E-PANIC halves, wasm parity beyond B-2's word-set leg), the graded
  arc's own design forks (#823's eager-arm decision), the `do`/`defer` routing
  implementation (#824), and any change to surface syntax. The `medaka check`
  CLI surface is unchanged throughout.

---

## References

- [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md) — the derived map this design targets
- `docs/spec/DICT-SEMANTICS.md`, `docs/spec/EFFECTS-SEMANTICS.md`,
  `docs/spec/SHADOW-SEMANTICS.md` — the governing semantics
- `compiler/ARCH-REVIEW.md` (PASS 2), `compiler/DRIVER-COLLAPSE-PLAN.md` — prior
  structural verdicts this design keeps or completes
- `.claude/workstreams/TYPECHECK.md` — the standing five-question gate
- Issues: **#1122 (the epic / stage tracker)**; #991–#995 (adopted),
  #1070/#1084 (family audits), #1082 (locals), #616 (conformance gate, adopted
  into S-1), #820–#824 (graded arc, peer); filed by this arc: #1107–#1121
