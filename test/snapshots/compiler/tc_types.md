# META
source_lines=3644
stages=DESUGAR,MARK
# SOURCE
-- Typechecker data declarations and state records: every `data` and `type`
-- the checker shares across its stages, with the key format of its grant records.  No
-- cells, no inference.
--
-- Closure rule: this module may not import `types.typecheck`, nor any later
-- `tc_infer_*`, `tc_solve` or `tc_driver` module.  Everything here sits below them.

import frontend.ast.{
  BinderId(..),
  Ty(..),
  TyConOrigin(..),
  Ident(..),
  Route(..),
  EvId(..),
  EvVal(..),
  EvTable,
  Arm(..),
  Expr(..),
  Loc(..),
  Field(..),
  Variant(..),
  Require(..),
  Super(..),
  ImplMethod(..),
  DataVis(..),
  Decl(..),
  TabKey(..),
  EffParamTy(..),
}
import types.repr.{
  AuthResidual(..),
  IfaceRef(..),
  Mono(..),
  Scheme(..),
  VecObl(..),
}
import support.ordmap.{
  OrdMap,
  omDelete,
  omEmpty,
  omInsert,
}
import map.{
  Map(..),
}
import types.effect_rows.{
  EffLabel(..),
  Atom(..),
  EffRow(..),
  Effvar(..),
}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
}
import types.effect_domain.{
  Param(..),
}
import types.effect_infer.{
  AlphaBinder(..),
}
import types.effect_solver.{
  SummarySolver,
}
import types.effect_bindings.{
  BindingSummary(..),
}
import types.evidence.{
  EvidenceBinderId(..),
  ScopeId(..),
  SolverEvidence(..),
}
import types.evidence_complete.{
  Inner(..),
}
import types.solver_contract.{
  ClassPredicate(..),
  SolverOutcome(..),
  Wanted(..),
}
import types.registry.{
  RegKey,
  Registry,
  HeadKey(..),
  MultiRegistry,
  SpellingPop,
}
import types.scopes.{
  ScopeCursor(..),
  ScopeStore,
}
import types.publish.{
  TcDiag(..),
  ModDiags,
  PubScheme(..),
  TcReport,
  EntryOutcome,
  noEntryOutcome,
}
import types.disposition.{
  DispositionTable,
}
import types.runtime_types.{
  BinderTypeTable,
}
import frontend.exhaust.{
  Oracle,
}
import types.capability_manifest.{
  EntryKey(..), ManifestSelector, ManifestRequest, CapabilityManifest
}
import types.route_key.{EvIndex}

-- Where an obligation the scoped solver holds was recorded, for its report:
-- the location, the binding, and whether an authority obligation is an index
-- row's coverage of an atom rather than one half of an index equality.
public export data ObligationSite = ObligationSite {
  osLoc : Option Loc,
  osFn : String,
  osCovering : Bool,
}

-- record metadata: name → (quantified param ids, result mono, field types).  A
-- global Ref (like the reference's record table) so field access / create /
-- update / patterns can look records up without threading an env field.
-- `RecordInfo params result fields fieldIndex`.  `fields` keeps DECLARATION ORDER
-- (record construction / exhaustiveness / owner rendering read it); `fieldIndex`
-- is a name→raw-Mono OrdMap built ONCE at registration so the hot per-access read
-- paths (field access + record update) do an O(log N) lookup instead of an O(N)
-- `lookupAssoc` scan, and instantiate ONLY the accessed field rather than rebuilding
-- all N fields per access (issue #980 — the typecheck sibling of resolve's ownersOf
-- record quadratic).  The two views are kept in lockstep by the sole constructor
-- site (`registerRecordInfoKeyed`); on a duplicate field name the OrdMap is built
-- from the REVERSED list so the FIRST declared entry wins, matching `lookupAssoc`.
-- param tyvar ids, quantified authority ids (the head's `Authority` params
-- and the constructor's existentials), result, fields, field index
public export data RecordInfo =
  RecordInfo (List Int) (List Int) Mono (List (String, Mono)) (OrdMap Mono)

-- Kind of a data-type parameter, inferred from usage: KRow iff the param name
-- appears in a field's effect-tail position (`<e>`), else KType.  Drives
-- kind-aware type-app elaboration (a KRow arg becomes a TEff row, not a TApp
-- tyvar) and ctor-result-type construction.  Per-type, positional.
-- A `KAuth` slot's flag is the `*` of `Authority L*`: the slot takes only a
-- pattern of the label's domain (EFFECTS-SEMANTICS §4.1).
public export data Kind = KType | KRow | KAuth EffLabel Bool

-- ── #1119 D-2 (#1098 / #1121): per-parameter VARIANCE ─────────────────────
-- Variance of a data-type parameter, inferred from how it OCCURS in the
-- declaration's constructor field types, exactly as `Kind` above is inferred
-- from usage rather than written.  `PCo` = every occurrence is covariant
-- (or the parameter is phantom), `PContra` = every occurrence is
-- contravariant, `PInv` = mixed, or reached through a slot that is itself
-- invariant.  Per-type, positional, keyed the same way `dataParamKindsRef`
-- is (`tyTabKey`) — see `dataParamPolarityRef`.
--
-- the only consumer is `unifyN`'s `TApp`/`TApp` ARM, and the ONLY thing a
-- non-`PCo` verdict buys is that an effect row sitting inside that argument
-- must be EQUAL rather than merely compatible.  It is deliberately NOT a
-- general subtyping engine: Medaka has no variance annotations
-- (`decided_medaka_does_not_need_variance_annotations`), so this table
-- exists to CLOSE a laundering hole, not to open a subtyping one.
-- `PPhantom` is "no occurrence yet", the bottom the variance fixpoint starts
-- from (`declEnvPolarityEntriesFix`); it never leaves the fixpoint, which
-- publishes a parameter with no occurrence as `PCo`.
public export data Polarity = PCo | PContra | PInv | PPhantom

-- #156 S3a: ONE record for every pending dispatch-site shape.  The four historical
-- tuple/record shapes (return-position sites, arg-position stamps, operator sites,
-- standalone-shadow RLocal sites) collapse into `PendingEntry`; `kind` (a
-- payload-carrying `SiteKind`) records which recorder built it and carries the
-- fields unique to that shape.  The common fields are: the method/name, the route
-- ref the resolver stamps, the primary discriminating mono, and the enclosing-fn
-- name (`currentFn` at record time, including RLocal sites).  The
-- five pending lists stay SEPARATE (the drain schedule is unchanged — this is a
-- pure data-representation change): each recorder builds a `PendingEntry` with its
-- own `kind`, and each resolver reads the fields instead of destructuring a tuple.
public export data SiteKind =
  -- return-position site: the EMethodAt impl-dicts ref to fill + the method's full
  -- (un-stripped) type.  The primary mono is the result mono.
  | SKReturn (Ref (List Route)) Mono
  -- an occurrence of a spelling with two or more admitted declarations (S2-DECL
  -- (d)), whose obligation is the admitted set's (`pushAdmittedOccObl`): the
  -- EMethodAt interface-word cell, which the commit writes, then SKReturn's fields.
  | SKAdmittedReturn (Ref String) (Ref (List Route)) Mono
  -- declaration-owned ordinary return: the same immutable request is carried by
  -- the checker obligation and this stamping goal.  The PendingEntry's EvId is the
  -- request's mrrGoalEv; the EMethodAt node's aggregate EvId remains separate.
  | SKExactReturn (Ref (List Route)) MethodReturnRequest
  -- numeric-literal return site: the fixed Num predicate and the full fromInt
  -- occurrence mono.  The ENumLit's one route cell carries the selected word and
  -- its prerequisite routes together until rewriting splits them.
  | SKNumReturn ClassPredicate Mono
  -- arg-position stamp: the EMethodAt impl-dicts ref + the method's full
  -- (un-stripped) occurrence mono.  Primary mono = arg mono.  #609: the full mono is
  -- what lets resolveArgStamp recover the interface's WHOLE param vector
  -- (ifaceParamMonos) — the arg mono alone is only the receiver, and selecting on it
  -- made a multi-param dispatch order-dependent.  Mirrors SKReturn, which has
  -- carried the method's full type for the same reason since #156 S3a.  The last
  -- field is the occurrence's goal variable for each typaram its type never
  -- mentions (`methodOmittedVars`), which the full mono cannot recover.
  | SKArg (Ref (List Route)) Mono (List (String, Mono))
  -- operator (EBinOp/EUnOp) site: the inImpl-body flag.  Primary mono = operand mono.
  -- (binop vs unop is carried by WHICH list holds it / the resolveOpSites flag, not here.)
  | SKOp Bool
  -- arithmetic operator site whose fixed prelude Num predicate is known at the
  -- producer.  The Bool retains SKOp's producer provenance for the shared carrier;
  -- exact-predicate routing does not consult it.  The predicate supplies the
  -- declaration identity and complete dispatch vector.
  | SKPredicateOp Bool ClassPredicate
  -- standalone-shadow RLocal site: mangled standalone symbol, forceLocal (P0-20),
  -- and the shadowing standalone's own `=>`-constraint dict monos + iface names
  -- (S-1).  Primary mono = receiver mono; encl owns deferred dictionary routing.
  -- FIX-shadow-arity-skew: the 5th field is the slot-parallel predicate ARGUMENT VECTOR
  -- list, so `resolveRLocalSites` can select each slot with `routesOfMonosTopV`'s vector
  -- goal instead of the scalar `Ix Int _`.  It is `ShadowDicts`' third projection and
  -- must stay aligned with the other two — see that record.  Empty ⇒ the scalar router,
  -- term for term.  #1909 falsified this comment's second half, which used to add
  -- "which is every 1-ary `=>` constraint in compiler + stdlib + sqlite": a 1-ary vector
  -- is no longer pinned to the scalar router, it routes on its own recorded argument.
  -- That is still byte-identical for a bare-tyvar constraint (the compiler's own), and
  -- deliberately not for a structured one — see `routesOfMonosTopV`'s header.
  | SKRLocal String Bool (List Mono) (List IfaceRef) (List (List Mono))

public export data PendingEntry =
  -- fields: name/method, route ref to stamp, primary mono, enclosing-fn name, kind,
  -- and the site's own source span.
  -- #1155 (F-3c): the 6th field is the enclosing construct's span (`mcLoc`)
  -- snapshotted at the RECORD site — during inference, while the construct is live —
  -- exactly as `implObls`' 5th element is (see `pushPendingObl`).  The resolvers run
  -- POST-HM, outside every construct, so only the snapshot can name this expression.
  -- Each resolver loop hands this span down as the walk's `sxSite` so the min⊑ selector's
  -- ambiguity reject can point at the goal it was actually posed by.
  -- #2549 M2: the 7th field is this site's EVIDENCE ID — the value-level name of
  -- the association the 2nd field (the route cell) carries by pointer identity.
  -- Minted where the carrier is built, which is the one point at which the marked
  -- node and its cell are both in hand; the reader flip sources it from the node
  -- itself instead, leaving everything downstream of here unchanged.
  | PendingEntry String (Ref Route) Mono String SiteKind (Option Loc) ScopeId EvId

-- ── #2547 unit 2 (ARCH M1): one deferred-goal channel ─────────────────────────
-- The route-stamped site goals used to live on five per-kind lists (`pendingSites`,
-- `pendingArgStamps`, `pendingRLocalSites`, `pendingBinopSites`/`pendingUnopSites`,
-- `pendingArithSites`), each drained by its own stamper at module end.  They are
-- ONE list of `Obligation` now, tagged by `GoalKind`; each stamper still receives
-- exactly its kind's entries, in the order the per-kind list held them (newest
-- first — the cons order is preserved by filtering), so no route moves.
--
-- `oDest` is ABSTRACT on purpose: today every goal's evidence destination is the
-- `Ref Route` cell the stampers write (`EvRoute`); #2548 drains this channel once at
-- quiescence into the same cells, and #2549 adds an evidence-id destination in its
-- place.  With the abstraction here, that drain is written once.
--
-- The dictionary-application, method-dict and record-dict channels are on it too
-- (`EvRoutes` destinations; the `let`/SCC brackets that windowed `dictApps` now mark
-- this channel).  Not on it: the numeric-literal channel (#991 ask 3: defaulting
-- machinery, stays bespoke) and the two obligation-CHECK channels `obls`/`implObls`
-- (`UObligation`, windowed per group).  `PendingEntry` and the three dictionary
-- carriers survive as the stampers' parameter shapes, projected back out of the bag.
public export data GoalKind =
  | GKReturnSite
  | GKArgStamp
  | GKRLocalSite
  | GKBinopSite
  | GKUnopSite
  | GKArithSite
  | GKDictApp
  | GKMethodDict
  | GKRecDictApp

-- Where a goal's evidence lands once solved: today the `Ref Route` cell a site
-- stamper writes, or the `Ref (List Route)` cell a dictionary-application carrier
-- owns.  #2549 adds the evidence-id arm.
-- lint-disable-next-line rule-clone-type
public export data EvDest = EvRoute (Ref Route) | EvRoutes (Ref (List Route))

-- What the kind's stamper needs beyond the destination.  The three dictionary
-- carriers keep their shape (their stampers are unchanged); a site carries what
-- `PendingEntry` carried minus the cell and the enclosing fn, which are on the
-- obligation itself.
public export data GoalPayload =
  | GPSite String Mono SiteKind
  | GPArith Mono
  | GPDictApp PendingDictApp
  | GPMethodDict PendingMethodDict
  | GPRecDictApp RecDictApp

public export data Obligation = Obligation {
  oKind : GoalKind,
  oDest : EvDest,
  -- #2549 M2: the identity this goal's solution is PUBLISHED under, alongside the
  -- cell it is written through.  Carried in from the goal's carrier rather than
  -- minted here, so the id names the site and not the moment the goal was queued.
  oEv : EvId,
  oEncl : String,
  oLoc : Option Loc,
  oScope : ScopeId,
  oPayload : GoalPayload,
  -- What the stamper built below the destination's top level
  -- (`types/evidence_complete.mdk`'s `Inner`).  A method-cell goal shares its cell's
  -- `ecInner`, as `oDest` shares the cell's route, so a cell several goals write ORs
  -- their notes.
  oInner : Ref Inner,
}

-- ── A-3.1 (#1112): the whole-graph declaration ENVELOPE ──────────────────────
-- Stage A-3's `K` is ONE declaration analysis over the whole loaded module graph,
-- assembled once in the driver preamble instead of marshalled per module
-- (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §2 K).  This unit lands the
-- ENVELOPE ONLY — the ordinal-tagged carrier, its whole-graph builder, and the one
-- ordinal filter.  It carries NO `CE`, `IE` or `DataEnv` contents: those are
-- A-3.2 / A-3.3 / A-3.4, which add fields to `DeclEnvs` and populate them inside
-- `buildDeclEnvs`.  Nothing here retires a `universe*`/`obUniv*` marshalling cell,
-- and nothing here re-keys one.
--
-- why an ordinal.  §2 K's whole-graph environments are language-VISIBLE: an impl
-- declared in a topo-LATER module becomes usable by an earlier one (an
-- orphan-instance-style acceptance widening, which §5 R2 owns).  The #1112
-- decomposition (2026-08-08) therefore stages that: every entry carries the
-- ordinal of the module that declared it, and every read filters
-- `entryOrd <= currentOrd`, which reproduces today's prior-modules-plus-me
-- universe.  This paragraph then predicted the semantics change would be "THE
-- deletion of one filter — `declEnvVisibleAt`, and nothing else", AND THAT
-- prediction was wrong.  A-3.6 (#1558) found the one predicate had grown readers on
-- structurally different subjects — instance candidacy, but also the alias table,
-- the ctor overlay pool, the field-owner multimap, the data param-kind table and
-- `CE` — so one deletion would have widened five things where the spec licenses
-- one.  By owner ruling the predicate SPLIT: `ieCandidacyVisibleAt` carries the
-- instance axis (graph-global, C4/I2), this one keeps the ordinal body for the name
-- axis.  What survives of the design is the ROUTING rule, which is what made the
-- split cheap: route every ordinal test through the predicate matching its SUBJECT,
-- and never open-code `<=` at a read site.
--
-- what is live today, and what is not — this unit's bar is BYTE-IDENTICAL, so
-- it may not move a judgment.  LIVE: `buildDeclEnvs` runs at the ONE Module-mode
-- driver entry, `graphPreamble` (under `driveGraphK`, with `checkModulesPreambleK`
-- its two-component projection), and `deAllDecls` supplies the whole-graph decl list
-- that entry previously concatenated inline, so a mis-built envelope is LOUD
-- (`populateEffectDomains` would miss a module's `effect` decls) rather than
-- silent.  Not live in this unit: the filter.  The row accessor this paragraph
-- used to track is gone — `declEnvsVisible`/`declEnvsUpTo`/`declEnvsUpToGo` were
-- RETIRED 2026-08-12 (bite C-0, see their tombstone further down) with zero callers,
-- ever: A-3.2a read `deAllDecls` unfiltered, and A-3.2b/A-3.4/A-3.5c each built their
-- own read-side path (`declEnvRowVisible`, `ieSnapAt`, `ceLookupAt`) instead.  The
-- filter itself IS live now, through those readers — but never through a pre-filtered
-- row list.  (This paragraph originally named "A-3.2/A-3.3/A-3.4's table reads" as the
-- accessor's future callers.  Every one of them declined it; the prediction was wrong
-- four times running, which is why the accessor is a tombstone rather than a TODO.)
--
-- ORDINALS.  The prelude is 0; then each module of the loader's dependency-first
-- list, in that order.  The prelude is indexed under BOTH `"core"` — the spelling
-- the export indexes (`meExports`, `deCtorExports`) key it under — and `""`, which
-- is the `mid` both drivers actually pass for the core pass (`checkModuleFull` →
-- `checkModuleFullImpl ""`; `elabModuleStamp ""`), so `declEnvsOrdOf` cannot miss on
-- either spelling.
--
-- A-3.2+ will add fields to `DeclEnvs`, so read this before you do.  The one
-- interior comment on each record below is LOAD-BEARING against #829 (REOPENED),
-- and MEASURED on this binary rather than relayed: `medaka fmt --write` renders a
-- multi-line record with NO interior comment as `data X =` / `| X { … }`, and that
-- two-line header is exactly #829's trigger shape — adding one interior comment to
-- a record already in it moved that comment onto the NEXT field (probed on a
-- 5-field synthetic record: the comment written beside field 3 came back beside
-- field 4), and `fmt --check` then reports the damage as clean.  A record that
-- already carries an interior
-- comment formats to the one-line `data X = X {` header instead, which is the safe
-- shape.  Keep at least one interior comment here; do not "tidy" them away.
public export data DeclEnvModule = DeclEnvModule {
  demOrd : Int,  -- 0 = the prelude; then the loader's dependency-first order
  demId : String,
  demDecls : List Decl,
  demPubDecls : List Decl,  -- A-3.2b (#1512): `publicDataDecls demDecls`, MEMOIZED — see `declEnvRowVisible`
  demKindEntries : List (TabKey, List Kind),  -- A-3.2b slice 2 (#1512): the KIND-public projection's entries, MEMOIZED — see `declEnvRowKindEntries`
  demSiblingOrd : Int,  -- the ordinal of this row's test sibling, which sees every decl of it; `0 - 1` for none
}

public export data DeclEnvs = DeclEnvs {
  deModules : List DeclEnvModule,  -- ordinal order, prelude first
  deOrdIndex : OrdMap Int,
  deDefiners : OrdMap (List (String, (String, String))),  -- RUN-XMOD-066: `graphPubDefiners`' answer, per module id — see `declEnvDefinerIndex`
  deAmbigValues : OrdMap (List (String, List String)),  -- #1675: value names a module exports under ≥2 DISTINCT definitions, with those definers — see `ambiguousExportRows`
  deAllDecls : List Decl,
  deData : DataEnv,  -- A-3.2a (#1112) built it; A-3.2b residual 1 (#1512) made it LIVE — `aliasUniverseAt` reads `deAliases`
  deImpls : ImplEnv,
  deIfaces : ClassEnv,  -- A-3.3 (#1519) built it; A-3.5c (#1557) made it LIVE — three readers, see the `CE` block
  deMethods : MethodEnv,  -- #2563: the method namespace by declaration identity, read at the reader's ordinal — see `MethodEnv`
  deKindsBefore : OrdMap (List (TabKey, List Kind)),
  deNameIndexBefore : OrdMap (OrdMap Unit),  -- #2158: `deKindsBefore`'s BARE-NAME twin, the SAME rows' `tabKeyName`s as a membership set — see `declEnvSeedChain`
  dePolaritiesBefore : OrdMap (List (TabKey, List Polarity)),  -- #1119 D-2: `deKindsBefore`'s VARIANCE twin — see `declEnvPolarityChain`
  deAtomsBefore : OrdMap (List (TabKey, List (List Atom))),  -- #2110 S2-1: `deKindsBefore`'s ATOM-GUARANTEE twin — see `declEnvRowAtomsChain`
  deOwnersBefore : OrdMap (OrdMap (List String)),
  deOwnerModules : OrdMap (List String),  -- #1597: field-owner KEY → the module ids that declare it — see `declEnvOwnerModules`
  deReach : OrdMap (OrdMap Unit),  -- #1597: module id → its transitive `DUse` closure (itself + the prelude included) — see `declEnvReachIndex`
}

-- ── the envelope fold's state ────────────────────────────────────────────────
-- One accumulator per table.  The point of the record is that the fold can be
-- RESUMED: the prelude row is the same rows on every analyze of the same prelude,
-- so a driver that has a prelude key folds it once per process
-- (`preludePreambleFor`) and resumes here with the user modules.
--
-- what may be a field here: a table whose prelude contribution is a pure function
-- of `coreDecls` -- of the DECLS, and of nothing else a process carries.  Two
-- disqualifications, and the second is the one that is easy to miss:
--   * it may not hold a `Decl`.  `Decl` carries mutable `Ref`s, and the tree is
--     re-stamped (`stampGraphTyOrigins`) into FRESH decls on every analyze, so a
--     shared decl would be a live cell from an older tree.  `DeclEnvs`' two
--     decl-carrying fields (`deModules`, `deAllDecls`) are rebuilt from the
--     caller's decls every call and are NOT in this record.
--   * it may not READ process-global state.  A read is as disqualifying as a
--     `Ref` field: the value is then a function of WHEN it was first derived, and
--     a resumed prefix pins that first reading for the life of the process.  This
--     is why the ATOM-GUARANTEE seed is not here -- `declEnvRowAtomEntries`
--     bottoms out in `dtopFor`, which reads `GraphCtx.effectDomains`, a table
--     the graph's own `effect` decls fill.  `buildDeclEnvs` derives it over
--     every row on every call, the way `deReach` is derived.
public export data DeclEnvAcc = DeclEnvAcc {
  daOrdIndex : OrdMap Int,
  daDefiners : OrdMap (List (String, (String, String))),
  daAmbig : OrdMap (List (String, List String)),
  daData : DataEnv,
  daImpls : ImplAcc,
  daIfaces : ClassEnv,
  daMethods : MethodEnv,
  daSeeds : DeclEnvSeedAcc,
  daPolarity : (List (TabKey, List Polarity), OrdMap (List (TabKey, List Polarity))),
  daOwnerModules : OrdMap (List String),
}

-- `dataParamKindsRef`'s cross-module seed.  `deModules` is ASCENDING, and each
-- row's entries go on the LEFT of the accumulator, so the highest visible ordinal
-- ends up FIRST — which is what `recordParamKinds`' prepend / `lookupTab`'s
-- first-match ordering means (the reader's own registrations are then prepended
-- ON TOP of this by `registerAllData … prog0`, so the live list still reads
-- [prog0, overlay, universe]).
--
-- that ordering is currently unobservable, and is reproduced anyway.  Since
-- A-2.3 a `TabKey` is identity-bearing and `tabKeyEq` never equates `TkIdent` with
-- `TkBare`, so two modules' same-named types cannot share a key: the only
-- duplicate key is ONE declaration seen twice, whose two values are equal because
-- `inferParamKinds` is pure over the same inputs.  It goes live the moment a BARE
-- key can enter the same list — the flat-path population, drained by #1115 (E-1) —
-- at which point first-match means "last registered wins" again and the
-- #1069/#1070/#1090 family returns.  It costs a fold direction.  (INFERRED, argued
-- from the keying and the purity, not from a differential run.)
-- The chain itself, walked ONCE over the ordinal-ascending rows.  Before folding
-- row [m] in, both accumulators hold exactly "every row strictly earlier than
-- [m]", which IS [m]'s own seed — so it is stamped under [m]'s module id here and
-- read back by one `omLookup` per module.
--
-- the projection is read at `m.demOrd + 1`, the ordinal of the next reader, and
-- that is not a trick: `declEnvVisibleTo`'s publicity conjunct is CONSTANT over
-- every `cur > m.demOrd` (all of them take the non-own arm), so one evaluation at
-- the smallest such reader is the projection every later reader sees.  Doing it
-- this way keeps the projection defined in exactly one place —
-- `declEnvRowKindEntries` / `declEnvRowVisible` — instead of open-coding
-- `m.demKindEntries` / `m.demPubDecls` here, which is drift a later re-scoping of
-- the name axis would then have to find twice.
--
-- The field-owner population is `declEnvRowVisible` walked through the SAME
-- `Variant`/`ConNamed` filter `registerVariants` → `registerNamedFieldVariants` →
-- `registerRecordInfoKeyed` applies, so the owner string is the same `Variant`
-- constructor name off the same `Decl` node.  `DNewtype` contributes nothing (its
-- payload is always a synthesised `ConPos`), which is why there is no arm for it,
-- and `DAttrib` unwraps and recurses, mirroring `registerData` (#1228/#1586 — see
-- the note on `declEnvKindEntries`, including which reader actually reaches it).
-- ── #2158: The bare-name accumulator, a third one in *THIS* FOLD ─────────
-- `nacc`/`nm` is `kacc`/`km`'s membership-set shadow: the `tabKeyName` of every
-- key `kacc` holds, as an `OrdMap Unit`, stamped under the same module id at the
-- same point in the walk.  `noImplHintFor` asks a bare-name MEMBERSHIP question
-- of `dataParamKindsRef` and nothing else does, so answering it needs a set, not
-- the list.
--
-- it is folded in here rather than given its own walk, and the difference is
-- measured, not stylistic.  #2158 first shipped as a per-module REBUILD in
-- `declEnvSeedDataUniverse` (`omFromNames (map … dataParamKindsRef.value)`), and
-- that list is `deKindsBefore[mid]`, whose length grows with the module ordinal —
-- an O(M² log M) term paid unconditionally on every compile.  `stage_ir_scaling`'s
-- `modules:typecheck` row went 2.219 → 2.500 (ceiling 2.45) on that one line.  The
-- accumulator below pays O(entries log entries) for the WHOLE graph instead, and
-- the read is one `omLookup`.
--
-- NOT `declEnvPolarityChain`'s SEPARATE-WALK SHAPE, and that is the
-- discriminator to check before adding a fourth: the polarity chain needs its own
-- walk because `declEnvRowPolarityEntries` READS `pacc` while building it.  This
-- accumulator is WRITE-ONLY — insert and forget, exactly like `oacc` — so it
-- composes into the existing fold with no new read edge.  It also shares `kents`
-- with the kind half rather than re-deriving the projection, which is what keeps
-- the two provably the same rows: the name set is `kacc`'s key set by
-- construction, not by a parallel definition that could drift.
-- The chain's state: the three write-only accumulators (`ds*Acc` -- "everything
-- strictly before the next row") and the three per-module seed tables stamped from
-- them.  A record rather than six positional arguments so the fold is resumable
-- from a prefix -- see `DeclEnvAcc`.
public export data DeclEnvSeedAcc = DeclEnvSeedAcc {
  dsKAcc : List (TabKey, List Kind),
  dsOAcc : OrdMap (List String),
  dsNAcc : OrdMap Unit,
  dsKinds : OrdMap (List (TabKey, List Kind)),
  dsOwners : OrdMap (OrdMap (List String)),
  dsNames : OrdMap (OrdMap Unit),
}

public export data DataTypeDecl = DataTypeDecl {
  dtKey : TabKey,
  dtName : String,  -- identity key, `tyTabKey dtOrigin dtName` — same family as `universeDataParamKinds`
  dtOrigin : TyConOrigin,
  dtParams : List String,
  dtVariants : List Variant,
}

-- A-3.2b residual (#1512): `adOrd`/`adPub` are the two INPUTS `declEnvVisibleTo`
-- takes, carried on the row rather than re-derived at the read.  They are here —
-- and not on `DataTypeDecl` — because THIS is the row that has a production
-- reader: `aliasUniverseAt` is the whole-graph replacement for the retired
-- `CrossRun.universeAliasTable`, and it must answer "which aliases can a reader
-- at ordinal k see" without walking every module's decls again (the per-module ×
-- per-decl shape `importedCtorTypeDecls` already pays once).
--
-- they are the predicate's arguments, not a second copy of its body.  Both
-- are consumed by `aliasUniverseAt` through `declEnvVisibleTo` itself; nothing
-- here open-codes `<=` or a `pub` test, which `compiler/types/typecheck.mdk` prohibits in four places
-- (`grep -n 'open-cod' compiler/types/typecheck.mdk`) — see `declEnvRowVisible`,
-- whose own comment is *"Both arms go through the predicate; neither open-codes
-- `<=` or a `pub` test."*
--
-- `adPub` is a call, not a copied field.  It is `publicDataDecl` applied to
-- the alias's own `Decl` — the SAME predicate `demPubDecls`
-- (`publicDataDecls decls`) routes through, and deliberately not a verbatim
-- `tyAliasPub` read.  `declEnvModule`'s note says a second construction site
-- *"is exactly how the two would come to disagree"*; storing the field would
-- make `deAliases` the one publicity decision in `DeclEnvs` that a future edit
-- to `publicDataDecl`'s `DTypeAlias` arm silently leaves behind.
--
-- `adAttrib` records that this alias was reached THROUGH a `DAttrib` wrapper.
-- It is POPULATION-NEUTRAL on purpose — see `aliasUniverseAt`, which applies it
-- at the READ, and the note on `dataEnvAddDecl`.
public export data AliasDecl = AliasDecl {
  adKey : TabKey,
  adName : String,  -- identity key, `tyTabKey o adName` — same family as the retired `universeAliasTable`
  adParams : List String,
  adRhs : Ty,
  adOrd : Int,
  adPub : Bool,
  adAttrib : Bool,
}

-- `deFieldOwnerIdents` is the NEW identity-keyed table: `universeFieldOwners`
-- (`GraphCtx.crossRun`) is bare-String-keyed only and has no identity companion today
-- (unlike the ctor/record tables, which A-2.11/A-2.12 (#1319 units 1/2)
-- already gave one).  Mirrors `deCtorIdents`/`deRecordIdents`'s shape: field
-- name -> every (owning ctor Ident, owning ctor name) that declares it, in
-- declaration order.
--
-- `universeFieldOwners`'s `addFieldOwners` is ALREADY a multimap, so two
-- DIFFERENT ctor names sharing a field are NOT the case this table adds
-- anything for — the bare table shows both rows already.  What only THIS
-- table can state is the case where the owning ctor name repeats: two
-- records both named "Pt" (in different modules) sharing a field "x" append
-- the SAME bare string "Pt" twice to the bare table's owner list, which a
-- reader cannot tell apart from one declaration counted twice.
-- `deFieldOwnerIdents` keeps the two as distinct `Ident`s (different
-- `TyConOrigin`) — see `distinctIdentsIn2` and the doctests below.
public export data DataEnv = DataEnv {
  deTypes : List (TabKey, DataTypeDecl),
  deCtorIdents : OrdMap (List (Ident, String, Variant)),
  deRecordIdents : OrdMap (List (Ident, String, List Field)),
  deFieldOwnerIdents : OrdMap (List (Ident, String)),
  deAliases : List (TabKey, AliasDecl),  -- A-3.2b residual (#1512): LIVE — the sole cross-module alias source, read by `aliasUniverseAt`
  deCtorExports : OrdMap (List (String, String, Ident)),  -- module id → the constructor rows that module's row CARRIES; the constructor peer of `meExports`, see `ctorExportsInto`
}

-- The INSTANCE IDENTITY this tree does not otherwise have.  `cohClassify`'s ledger
-- records the gap verbatim — `bucketKeyEntriesFrom` restarts its numbering at 0 per
-- module, so two distinct impls in different modules share an index.  Minted in
-- exactly ONE place (`implRowsOf`, from the declaring module's id + ordinal + a
-- sequence number within the whole-graph build), so two impls can never share one.
-- Read by no judgment in this unit: it is A-3.7's (coherence) and B-2's (`InstId`)
-- declared input, and it is a deliverable, not a behaviour change.
-- Positional, not a named record, and the reason is a measured emitter trap —
-- see `ImplRow` below, which carries the full derivation.  Fields, in order:
-- the declaring module's loader id (the SCOPE), its ordinal, and the sequence
-- number within the whole-graph build.
--
-- unique within one compile — AND **not stable across compiles**.  State both
-- halves or the next author will read the first as the second, because this thing
-- is advertised as "the instance identity this tree does not otherwise have" and
-- is named as B-2's `InstId` input.
--   * `seq` is a WHOLE-GRAPH running counter, so adding one `impl` to ANY earlier
--     module renumbers every later impl in the program.
--   * `ord` is the loader's dependency-first position, so reordering imports moves
--     both components.
-- Uniqueness within a compile is all that is claimed, and it is all A-3.7's
-- coherence needs (it compares two rows of ONE graph).  B-2 is a different
-- matter: it owns the emit-side WORD namespace, where an ordinal-derived serial is
-- a poor name source — a symbol named from `seq` changes when an unrelated earlier
-- module gains an impl, which is a reproducible-build and incremental-rebuild
-- hazard, not a correctness one.  If B-2 wants a NAME, derive it from
-- `(module id, interface identity, head)` — content, not position — and use
-- `InstRef` only as the within-compile discriminator it is.
public export data InstRef = InstRef String Int Int

-- One impl, with what §2 K specifies — full head, context, method table — plus its
-- identity and the scope its visibility is filtered on.
-- Positional, not a named record — and this is a measured emitter constraint,
-- not a style choice.  §9.4 spells the row with named fields; this is the one place
-- that spelling cannot be honoured, so the reason is written here rather than left
-- for the next reader to rediscover.
--
-- The LLVM emitter resolves a record field label to a positional index from a table
-- it builds by scanning the lowered program for construction sites —
-- `scanExprRecords` collects `(name, labels)` from `CRecord` nodes only, never from
-- the `DData` declaration (`compiler/backend/llvm_emit.mdk:10178-10193`,
-- `findFieldIdx`/`findRecordByLabel` at `:10148-10163`).  So a record whose
-- CONSTRUCTION is dead-code-eliminated from an entry's closure while a FIELD ACCESS
-- on it survives panics: `llvm: CFieldAccess: unknown field '<label>'`.
--
-- MEASURED on this branch, with the named-record spelling:
--   ./medaka build compiler/entries/wasm_emit_typed_main.mdk   -> exit 1,
--   runtime error [E-PANIC]: llvm: CFieldAccess: unknown field 'ieOrd'
-- reproduced in CI on the `wasm` job, which cascaded `gates (backend)` into a
-- phantom-skipped `diff_compiler_tmc_parity`. Before driver collapse that entry
-- reached the retired single-program elaborator and therefore `checkBodyImpl`,
-- (`ieShadowCompare` at the time this was measured, `ieUniverseAt` since A-3.4 PR2;
-- either way `checkBodyImpl` mentions `ImplRow`'s fields and the entry's closure
-- therefore contains the field ACCESS) — but it never reaches `buildDeclEnvs`, hence never
-- `implRowsOf`, the only `ImplRow` construction site.  A positional constructor is
-- destructured by pattern match and consults no label table, so it cannot hit this.
--
-- `ImplEnv` below KEEPS its named fields, and that is not an inconsistency: its
-- construction site `emptyImplEnv` is reachable from `emptyDeclEnvs` ←
-- `initialGraphCtx`, which the `interners` initializer builds — which is why the panic
-- named `ieOrd` and not `ieRows`.  A later editor who makes `emptyImplEnv`
-- unreachable re-arms the same trap on `ImplEnv`.
--
-- Fields, in order: the declaring module's ordinal (A-3.1's `demOrd` — the scope);
-- the instance identity; the interface identity; the full head, in alias normal
-- form (`stampGraphDecls` rewrote the `DImpl` before any row was built, so no
-- reader of it expands an alias); the context; and the explicit/synthesized impl
-- method table.  The table is not a selection key;
-- after exact row selection it also supplies the method route-word collision set.
-- The last field is the declaration's `implIfaceLoc`: coherence runs over rows
-- with no construct around it, so a conflict is located at the impl's interface
-- name.  A synthesized impl (a derived one) has none.
public export data ImplRow =
  ImplRow Int InstRef IfaceRef (List Ty) (List Require) (List String) (Option Loc)

-- The registry.  `ieRows` is the POPULATION in build order (ordinal order across
-- modules, `implDeclsWithReqs` order within one); the rest are INDEXES over it.
-- `ieConcrete`/`ieHeadless` are the obligation channel's own two,
-- with the SAME keys, minted through the SAME `oblIfaceKeys`/`dispHeadTab` calls
-- (see `ieInsertRow`), so `IE` mints no parallel keying scheme; `ieByHead` is
-- `KeyBuckets`' partition, minted through the SAME `headBucketKey` (see
-- `ieFileRowByHead`).  Derive the set rather than trusting a count here — this
-- sentence said "the three buckets" while there were four, which is how
-- `stampKeyTable`'s "five stampers" comment came to be wrong about seven.
public export data ImplEnv = ImplEnv {
  ieRows : List ImplRow,  -- whole-graph, build order; the snapshot fold reads this
  ieConcrete : MultiRegistry ImplRow,
  ieHeadless : MultiRegistry ImplRow,
  ieByHead : MultiRegistry ImplRow,
  -- A-3.4 PR2, and it is a performance invariant, not a cache.  One entry per
  -- distinct module ordinal, in ordinal order: `(o, universe of every row with
  -- ordinal <= o)`.  `ieUniverseAt` SELECTS from this; it does not rebuild.
  --
  -- why it exists — MEASURED, and it is the tree's signature mistake caught in its
  -- own gate.  The first cut of this unit had `ieUniverseAt` fold the whole visible
  -- prefix on EVERY read, i.e. once per module: O(modules x impls) where the
  -- accumulator it replaced was O(impls) TOTAL.  That is exactly the
  -- "rescan the accumulated universe once per module" quadratic #154 PR-C removed
  -- and `diff_compiler_perf_scaling.sh` promoted the `modules` shape OUT of its
  -- ledger for — and it put it straight back: net alloc 730 MB -> 2191 MB -> 7345 MB,
  -- r1=3.00 r2=3.35, ** SUPERLINEAR (ALLOC) ** against a 3.0 ceiling and a
  -- documented FLAT ~2.0 expectation.
  --
  -- The fix costs nothing because the registries are PERSISTENT: a snapshot retains
  -- structure that is already shared, so this is M pointers, not M copies.  Built by
  -- ONE left fold over `ieRows` (already in ordinal order), so the whole table is
  -- O(impls) to construct and a read is a walk of visible ordinals with no
  -- allocation at all.
  --
  -- The values are IDENTICAL to the per-read rebuild, by construction rather than
  -- by assertion: `ieRows` is in ordinal order, so "every row with ordinal <= cur" is
  -- a PREFIX of `ieRows`, and inserting a prefix in order through the same
  -- `growImplUniverse` writer is the same value the filtered rebuild produced.
  ieUnivSnaps : List (Int, ImplUniverse),
}

-- Fold the envelope's modules, in ordinal order, into one whole-graph registry.
-- The sequence number runs across the WHOLE build (not per module), which is what
-- makes `InstRef` unique without relying on `(mid, ord)` being injective.
-- The impl fold's whole state: the registry, the build-wide sequence number, and
-- the `ieUnivSnaps` accumulator.  One record so the fold can be RESUMED from a
-- prefix rather than restarted -- see `DeclEnvAcc`.
public export data ImplAcc = ImplAcc {
  iaEnv : ImplEnv,
  iaSeq : Int,
  iaSnaps : (List (Int, ImplUniverse), ImplUniverse),
}

-- ═══ #1519 A-3.3: THE `CE` REGISTRY ═══════════════════════════
-- §2 K: *"CE (class environment): interfaces with declared parameter kinds …,
-- method schemes, superclass predicates …"*  Built once, whole-graph, inside
-- `buildDeclEnvs`; every read filters through `declEnvVisibleAt`.  This used to
-- add "(A-3.6 deletes its body)".  It does not: A-3.6 (#1558) split the predicate
-- and flipped the INSTANCE axis only.  `CE` is interface IDENTITY, not instance
-- candidacy, so every `CE` read keeps its ordinal filter — permanently, unless some
-- later unit argues the name/identity axis on its own merits.
--
-- syntactic, not elaborated — the Step 0 ruling this unit inherits rather
-- than re-derives: *"CE's declaration environments hold the DECLARATION as
-- declared, not as elaborated.  CE stores raw Ty/Variant/Field keyed by
-- identity.  Elaboration to Scheme/Mono/RecordInfo stays where it is today."*
-- Re-confirmed against this tree before writing a line of this block: every
-- LIVE CE-side table already stores raw `Ty` —  the list below is a dated
-- snapshot, not a live inventory: `universeIfaceParamKinds` was retired by A-3.5c
-- and `universeIfaceRequiredRef` by A-3.5a (both #1557).  It is kept unedited
-- because the CLAIM it supports — no CE-side table stores an elaborated
-- `Scheme`/`Mono`/`RecordInfo` — is what mattered and is still true of the
-- survivors; derive the live set from `CrossRun` rather than reading it here.
-- The snapshot: `universeIfaceRequiredRef : Ref (Registry (List String))`, `universeIfaceParamKinds : Ref (List
-- (RegKey, List Kind))`, `universeRegisteredIfacesRef : Ref (OrdMap Unit)`,
-- `superDeclsRef : Ref (List Decl)` — zero `Scheme`, zero `Mono`, zero
-- `RecordInfo`.  `ceMethodTyAt` (in `compiler/types/typecheck.mdk`) returns raw `Ty`
-- and every use site elaborates on demand via `fromAstTypeE`.  This
-- construction mirrors that exactly, and hits the identical wall A-3.2a's
-- `DataEnv` construction hit: elaborating a method signature would call
-- `fromAstTypeE`/`registerRecordInfoKeyed`-shaped machinery, which MUTATES
-- `ModuleCtx` refs and EMITS diagnostics through a `ModuleCtx`-scoped dedupe —
-- machinery that does not exist yet in the driver PREAMBLE.  This sentence
-- used to say that machinery "mints fresh tyvar ids off the global counter";
-- that is FALSE (`tyvarCounter` is a `GraphRun` field, not a global) and it
-- was corrected 2026-08-12 — see the "why not just call registerAllData/…"
-- block above `DataEnv` for the corrected walls.
-- So this index is deliberately SYNTACTIC: raw `Ty`/
-- `Super`/`Kind` values, keyed by identity, no elaboration performed — see the
-- "why not just call registerAllData/…" block above `DataEnv` for the full
-- derivation, which applies here unchanged.
--
-- EXCLUDES `universeMethodDispatchIdxByIdRef` —
-- lifted bare and unchanged, NEVER keyed here (#1112's decomposition row,
-- re-grounded in #1519's own bookkeeping comment 2026-08-11 after #1353
-- closed).  The method-name membership S1's shadow builders take is not built
-- here either: it is `methodNameDeclaredAt`, a read of `deMethods` at the
-- reader's ordinal, and S1-NS (#1353) is a
-- filter at the read (`nameableIfaceShadows`), so a copy here would be a
-- second, differently-shaped answer to a question that already has one live
-- decision point.  `universeMethodDispatchIdxByIdRef` is #1351's (OPEN S0; its
-- bare-name predecessor `universeMethodDispatchIdxRef` was retired at L5), and
-- `TYPECHECK-TARGET-ARCHITECTURE.md` §9 independently routes it to `IE`/
-- RLocal-site channels, not `CE`.
--
-- ✅ `universeIfaceParamKinds` COORDINATION — DISCHARGED by #1557 A-3.5c, which is
-- the PR this paragraph was addressed to.  A-3.3 wrote: *"its eventual retirement is
-- this unit's (`CE`'s) to route, on whatever PR first gives `ceParamKinds` a live
-- reader, not A-3.2b's to fold in by accident of which function happens to marshal it
-- today."*  A-3.5c is that PR.  `ceParamKinds` has a production reader
-- (`ceSlotKindsAt` ← `checkGradedImplTys`), and BOTH the `universeIfaceParamKinds`
-- CrossRun cell and the `ifaceParamKindsRef` ModuleCtx ref it marshalled are DELETED,
-- along with their writer — so `loadDataUniverse`/`storeDataUniverse` marshal one
-- fewer table than before this unit.  Do not write the count here: this line said
-- *"THREE tables (recordByName, fieldOwners, dataParamKinds)"* and #1512 slices 2+3
-- retired two of those three the same day.  DERIVE the survivors from the two bodies,
-- whose own header (`loadDataUniverse`) states the same rule.  A-3.2b's residual slice 1
-- took `aliasTable` out just before this unit took `ifaceParamKinds`, and
-- the `DataEnv`-by-CO-LOCATION confusion the original note was guarding against no
-- longer has a table to attach to.  A-3.2b's slices retire the remaining rows under
-- `DataEnv`'s own name.
--
-- zero readers no longer holds, and that is the whole point of A-3.5c under
-- RULING 1 (*"A-3a is complete when `CE` and `DataEnv` each have at least one
-- PRODUCTION reader AND the corresponding `universe*` rows are retired"*).  #1519
-- landed this block construction-only and therefore INERT; the three readers are now
-- `ceSlotKindsAt` (graded impl-head kinds), `ceRowsOwnedBy` (phantom methods) and
-- `ceRowsVisibleAt` + `ceLookupAt` (W1 acyclicity, following superinterface edges by
-- identity).  What follows was written when nothing read `deIfaces`; the caveat it
-- states is now historical, kept because the doctests it justifies are still the
-- sharpest evidence this block has:
--
-- AT LANDING, `deIfaces` had ZERO READERS (construction only, per #1519's
-- bar), so "Byte-identical" was WEAK evidence at the time, exactly as
-- A-3.2a's own header says of `deData`: an unread field means the
-- construction could have been wrong without moving any judgment.  The
-- load-bearing checks were the doctests below, which exercise the fold's
-- output directly against a discriminating two-module same-spelled-interface
-- corpus (mirroring `IE`'s `ieProbeEnv`), not the differential gates.
--
-- THE `DL` MEASUREMENT §9.5 OWES — DISCHARGED, not cited-and-skipped.  A-3.4's
-- own block above says A-3.2/A-3.3 "must measure their own projections; they
-- may not cite 'DL is discharged'".  This unit's projection over `demDecls` is
-- prePass-INVARIANT, so there is nothing for the schedule's mark of the tail
-- declarations (`markTailDecls`) to disagree with: `prePassDeclScoped`'s
-- `DInterface` arm rewrites only `methods`, via `prePassIfaceMethodScoped`,
-- which itself rewrites only a method's `MethodDefault` BODY (the `Some (…, e)`
-- arm's `e`) — never `n`/`ty`, and the `None` (no default) arm is untouched
-- outright.  `ceMethodOf`'s `(IfaceMethod n ty _)` pattern discards exactly
-- that third position.  `name`/`typarams`/`supers`/`ifaceOrigin` are untouched
-- by the same arm (only `methods` is record-updated).  So CE's projection over
-- the raw `demDecls` and over the prePass-rewritten `modules2a`/`modules2`
-- agree by construction — the rewrite touches nothing CE reads.
--
-- positional, not a named record — the SAME measured emitter constraint
-- `ImplRow` documents above, not a style echo of it.  `CeRow`'s construction
-- site (`buildDeclEnvs` → `buildClassEnv`) is reachable from every driver
-- entry exactly as `implRowsOf`'s is, while a named-record spelling's field
-- ACCESS can still be linked into an entry whose construction was DCE'd (the
-- `ieOrd`/`wasm_emit_typed_main.mdk` panic `ImplRow`'s comment reproduces).  A
-- positional constructor is destructured by pattern match and consults no
-- label table, so it cannot hit this.  `ClassEnv` below KEEPS named fields,
-- for the identical reason `ImplEnv` does: its construction site
-- (`emptyClassEnv`) is reachable from `emptyDeclEnvs` ← `initialGraphCtx`,
-- which the `interners` initializer builds.
--
-- Fields, in order: this interface's identity key (`ifaceTabKey` lifted
-- through `regKeyOfTab`, the same mint `oblIfaceKeys`/`ifaceSlotKey` use);
-- the declaring module's ordinal (A-3.1's `demOrd`, the scope); the interface
-- reference (spelling + identity); its declared type parameters, by name and
-- position; its methods as `(name, raw Ty, graded scope)` triples — the scope
-- is `declGradedScope typarams methods`, computed ONCE per interface exactly
-- as `methodRowsInto` already does, not re-derived
-- per method; its raw `Super` list, unelaborated; its per-typaram kind
-- signature, POSITIONAL with `ceTyparams` — `ifaceParamKindsOf p methods` for
-- each `p`, the SAME pure computation `registerIfaceParamKindsGo` performs
-- per slot, so a graded interface's `KRow` inference cannot drift between the
-- live universe and this table; and, since #1557 A-3.5a, its REQUIRED-method
-- names — `requiredMethodNames methods`, the SAME pure computation the retired
-- `universeIfaceRequiredRef` writer (`insertIfaceRequired`) stored under the
-- SAME `regKeyOfTab (ifaceTabKey ifaceOrigin name)` key, so relocating
-- impl-completeness onto this row is a population/lifetime move on the Module
-- arm and not a re-key (the historical single-program arm was on a
-- bare first-match scan).
--
-- The last field is the declaration's `ifaceNameLoc`: a whole-program check over
-- the rows (an interface cycle, a phantom method) has no construct around it, so
-- it is located at the interface's name.
--
-- The SCOPE component of each `ceMethods` triple is `declGradedScope typarams
-- methods`, shared across every method of one interface. `ceMethodTyAt` consumes it
-- beside the raw Ty when checking an impl body; separating those lookups would let
-- same-named interfaces disagree on which graded scope elaborates the method.
public export data CeRow =
  CeRow RegKey Int IfaceRef (List String) (List (String, Ty, List (String, List Kind))) (List Super) (List (List Kind)) (List String) (Option Loc)

-- The registry.  `ceRows` is the population in build order (ordinal order
-- across modules, declaration order within one); `ceByKey` is the single
-- identity-keyed index — CE's read shape is "what does interface I mean
-- here", a single-row lookup, not IE's "every impl matching a goal"
-- candidate-set collection, so ONE `Registry` (not a `MultiRegistry`)
-- suffices: an interface identity resolves to exactly one declaration.
public export data ClassEnv = ClassEnv {
  ceRows : List CeRow,
  ceByKey : Registry CeRow,
}

-- ── #2563: the METHOD namespace, keyed by declaration identity (stage K) ──────
-- Which interface declaration does the method spelling `n` mean in module M?  One
-- table answers it for every driver: `deMethods`, folded with the rest of `DeclEnvs`
-- from the stamped graph (so the emitter child, which never runs resolve, builds the
-- same one), and read at M's ordinal through `declEnvVisibleAt`.
--
-- The answer is per (module, spelling) and is computed on first read and memoized in
-- `ModuleCtx` (`methodScopeHere`).  Never rebuild a per-module projection of the whole
-- table: that is O(modules × methods), the shape `compiler/AGENTS.md` keeps finding.
--
-- The payload every reader consumes: the declaring interface, its typarams, the
-- method's declared `Ty`, and the interface's graded scope (#822 — stored with the
-- `Ty` it elaborates so the two are never resolved apart).
export type MethodEntry = (IfaceRef, List String, Ty, List (String, List Kind))

public export data MethodRow = MethodRow {
  mrIdent : Ident,  -- `mkIdent NsMethod ifaceOrigin mname`: the declaration itself
  mrOrd : Int,  -- the declaring module's ordinal (prelude = 0)
  mrIface : RegKey,  -- the declaring interface's `CE` key
  mrEntry : MethodEntry,
}

-- `meExports` / `meIfaceExports` are module id → what that module's row CARRIES,
-- folded dependency-first so an `export import` chain of any depth resolves.  Neither
-- has a `pub` filter (a private interface contributes, see `declMethodIdentsOf`), and
-- the prelude is keyed under `"core"`.  `meIfaceExports` keeps each row's method LIST
-- rather than a `CE` key because `selectIfaceRows` narrows a row to the methods a
-- member list names (S1-NS, per method), which a key cannot express.
public export data MethodEnv = MethodEnv {
  meByName : OrdMap (List MethodRow),  -- spelling → its declarations, in ordinal order
  meExports : OrdMap (List (String, Ident)),
  meIfaceExports : OrdMap (List (String, List String)),
}

-- What one spelling means in one module:
--   * `MsAbsent` — no visible declaration;
--   * `MsOne r`  — the scope decides `r` (or only `r` is visible);
--   * `MsMany ifs` — two or more declarations are admitted (`ifs`, sorted, the set
--     S2-DECL (d) decides by cardinality) and none is the answer, so every
--     single-winner reader sees no declaration.
public export data MethodScope =
  | MsAbsent
  | MsOne MethodRow
  | MsMany (List IfaceRef)

-- One graph drive's state: the cross-module accumulators (`crossRun`), the graph
-- lineage (`graphRun`), the drive's configuration and trace sink, the graph-derived
-- tables, and the sticky type-error pair.  `graphPreamble` mints it (`mintGraphCtx`)
-- from the drive's inputs, the admitted map its driver computed, and the process's
-- `Interners`: every field is the drive's own, except the lineage objects of
-- `graphRun` and the extern catalog `builtinExternNamesRef`, which are the
-- interners' (those of the record most recently minted or restored).
--
-- NO TRAILING `--` comment on any field below (#829/[T-PERRUN-COMMENTS] corrupts
-- this header shape) — field prose lives on the reader, e.g. `dispatchIdxScoped`.
public export data GraphCtx = GraphCtx {
  crossRun : CrossRun,
  graphRun : GraphRun,
  effectDomains : Ref (List (String, Param)),
  -- The drive's configuration, built once per drive by `graphPreamble` (`tcConfigOf`)
  -- after the effect domains its IO join reads.
  config : Ref TcConfig,
  -- The drive's trace sink, `diTrace` of its inputs (`None`: every trace off).
  trace : Option TraceSink,
  -- Per module: the (dependency id, method name) pairs `deAliasMethodImports`
  -- admitted for dispatch without the program binding that bare name, so the
  -- import seed can tell an admission from a written binding.
  graphAdmittedMethodsRef : Ref (OrdMap (List (String, String))),
  declEnvsRef : Ref DeclEnvs,
  abstractRecordTypesRef : Ref (OrdMap Unit),
  argDispatchIdxByIdRef : Ref (List ((IfaceRef, String), Int)),
  dictEligibleRef : Ref (List String),
  dictEligibleSetRef : Ref (OrdMap Unit),
  mangledShadowMapRef : Ref (List (String, String)),
  mangledFunDefsPresentRef : Ref Bool,
  builtinExternNamesRef : Ref (OrdMap (Ty, List (String, Int))),
  promotionHarvestRef : Ref (List String),
  mainSchemeRef : Ref (Option Scheme),
  -- The graph's mark sets (`markSetsOf`), written by the Module-arm driver
  -- preambles and read by `checkBodyImpl` to mark each module's groups on the
  -- schedule.  `None` until a preamble has run; a Module arm reading `None` is a
  -- driver that skipped its preamble, and fails loud.
  markSetsRef : Ref (Option MarkSets),
  -- Armed by every recorded type error (`recordTypeError`), read by
  -- `typeErrorsArmed` and `driveOutputsNow`; the diagnostics behind it, newest first, each with its module.
  typeErrorsSticky : Ref Bool,
  typeErrorsStickyDiags : Ref (List (String, TcDiag)),
}

-- The typechecker's configuration for one drive: immutable, built once by
-- `graphPreamble` from the selected profile and the driver inputs.  `tcIoJoin` is
-- what `IO` joins (`ioJoinAtoms`) and `tcIoJoinProfile` the name of the profile it
-- was taken from (`""` for none).  The next two are the stdlib ownership of
-- `DriveInputs`, copied at the same point.  `tcKey` digests the profile name and
-- both ownership fields once, at construction (profile, flat flag, then the
-- sorted owned module ids joined by `,`, separated by newlines); the chain
-- memo keys on it, so a hit is only served to the configuration it was
-- computed under.  `tcSibling` is `DriveInputs.diSibling`; `tcKey` leaves it out,
-- because what a module's interface records does not depend on who imports it.
public export data TcConfig = TcConfig {
  tcIoJoin : List Atom,
  tcIoJoinProfile : String,
  tcStdlibOwned : OrdMap Unit,
  tcFlatEntryIsStdlib : Bool,
  tcKey : String,
  tcSibling : Option (String, String),
}

-- The trace gates and buffers a test builds before a drive and reads after it.
-- A gate is a plain `Bool` fixed when the sink is built; each buffer is a `Ref` so a
-- `note*` call appends in place.
public export data TraceSink = TraceSink {
  tsAssumptionEnabled : Bool,
  tsAssumptionEntries : Ref (List AssumptionTraceEntry),
  tsNumericPredicateEnabled : Bool,
  tsNumericPredicateEntries : Ref (List NumericPredicateTraceEntry),
  tsMethodReturnEnabled : Bool,
  tsMethodReturnEntries : Ref (List MethodReturnTraceEntry),
  tsEvidenceObservationEnabled : Bool,
  tsEvidenceObservationEntries : Ref (List EvidenceObservationEntry),
}

-- What a driver hands a drive as its first argument: the stdlib ownership of the
-- loader's module list, the trace sink (`None`: every trace off), the selected
-- target profile's `IO` grants and name (`""` for none), carried as data so this
-- module need not import `types.target_profile`.  [diPreludeKey] is the desugar-cache
-- generation pair of the two prelude trees the drive is handed, when its driver
-- knows it: the tree arm continues from the prelude's shipped trees only under it.
-- [diSibling] is the (test sibling, subject) module-id pair when the driver's
-- loader classified the entry as its subject's sibling: that one importer sees
-- the subject's full view (`frontend.visibility.viewOf`).
public export data DriveInputs = DriveInputs {
  diExecutedMainDriver : Option EntryKey,
  diManifestRequests : List ManifestSelector,
  diStdlibOwned : OrdMap Unit,
  diFlatEntryIsStdlib : Bool,
  diTrace : Option TraceSink,
  diIoJoinGrants : List (String, EffParamTy),
  diProfileName : String,
  diPreludeKey : Option (Int, Int),
  diSibling : Option (String, String),
}

-- What one graph drive is handed besides its output selection: [daValueMain] is the
-- caller's value-main candidate (`autoPrintWanted`), [daExecutes] names the `async`
-- driver of a caller that runs or emits the trees, [daPreludeKey] is the
-- desugar-cache generation pair of the prelude interface (`checkCoreMemoized`), and
-- [daKeyed] is the full chain key with one source key per module before the entry,
-- for a drive that serves and records module interfaces.
public export data DriveArgs = DriveArgs {
  daInputs : DriveInputs,
  daValueMain : Bool,
  daExecutes : Option String,
  daPreludeKey : Option (Int, Int),
  daKeyed : Option (String, List (Option String)),
  daRuntime : List Decl,
  daCore : List Decl,
  daModules : List (String, List Decl),
}

-- What a drive hands back to its caller, as plain data frozen at the drive's end
-- (after the drain and the sticky rollback): the answers a driver asks of the
-- drive it ran.  No `Decl`, no closure and no live cell: `doInvocationView`'s
-- schemes are re-minted copies, and the rest is booleans and immutable tables.  It is not a `TcReport` field because
-- `types.publish` cannot import this module.
--
-- `doStickyDiags` is the sticky list as the drive left it, newest first, not yet
-- deduplicated (`stickyTypeErrorDiags` reads it); `doFfiAliases` and `doOrdIndex`
-- are the two tables of the declaration envelope that `checkedFfiExternTypeNamesModules`
-- reads.  `doEffvarNext` is the drive's effect-variable counter at its end: a
-- consumer that mints effect variables over `doInvocationView`'s schemes
-- (`lastInvocationOps`) starts its own counter there, so its ids cannot collide with
-- an id the drive's schemes hold.  `doServedModules` counts the modules the
-- drive served from recorded interfaces instead of checking.
public export data DriveOutputs = DriveOutputs {
  doManifestRequests : List ManifestRequest,
  doManifests : List CapabilityManifest,
  doEntryOutcome : EntryOutcome,
  doHadTypeErrors : Bool,
  doHadMatchWarnings : Bool,
  doInvocationView : InvocationView,
  doGrantsEnabled : Bool,
  doEffectDomains : List (String, Param),
  doStickyDiags : List (String, TcDiag),
  doIfaceExports : OrdMap (List (String, List String)),
  doFfiAliases : List (TabKey, AliasDecl),
  doOrdIndex : OrdMap Int,
  doEffvarNext : Int,
  doServedModules : Int,
}

-- The outputs of a program no drive checked.
export
emptyDriveOutputs : Unit -> DriveOutputs
emptyDriveOutputs _ = DriveOutputs {
  doManifestRequests = [],
  doManifests = [],
  doEntryOutcome = noEntryOutcome,
  doHadTypeErrors = False,
  doHadMatchWarnings = False,
  doInvocationView = InvocationView [] [] [],
  doGrantsEnabled = False,
  doEffectDomains = [],
  doStickyDiags = [],
  doIfaceExports = omEmpty,
  doFfiAliases = [],
  doOrdIndex = omEmpty,
  doEffvarNext = 0,
  doServedModules = 0,
}

export
withPublishedManifests : List ManifestRequest ->
  List CapabilityManifest ->
  DriveOutputs ->
  DriveOutputs
withPublishedManifests requests manifests outputs = { outputs |
  doManifestRequests = requests,
  doManifests = manifests,
}

export
manifestDriverFor : DriveInputs -> Option String -> Option EntryKey
manifestDriverFor _ (Some name) =
  Some EntryKey { moduleId = "async", binding = name }
manifestDriverFor inputs None = inputs.diExecutedMainDriver

-- #841/#838 I1: `Windowed a` — a list+counter pair (formerly kept in step "by
-- convention" across module reset/push/error-rollback, per-channel) as ONE value whose
-- ONLY mutators are its own five ops.  wPush/wRestore are the sole writers, so
-- the invariant cannot drift; wMark/wWindow replace the `N0 = …N.value` snapshot +
-- prefix-take bracket over the first `…N.value - N0` items that every channel repeats.  #838 I1
-- ports `pendingCallObligations`/`pendingCallObligationsN` onto this — see
-- `compiler/types/typecheck.mdk`'s `obls` field below.  #841 ported
-- `pendingImplObligations` onto it too (the `implObls` field); the dictionary
-- application channel lives on `GraphRun.goals` since #2547 unit 2.
public export data Windowed a = Windowed { items : Ref (List a), n : Ref Int }

-- U1b (#1482): ONE dict slot of a constrained callee — the interface the slot
-- discharges, paired with the scheme-var id it is keyed on.
--
-- This exists so that NO consumer of a callee's constraint slots ever holds two
-- parallel lists again.  `qualConstraintFor` used to return `(List Int, List String)`
-- built from two INDEPENDENT table lookups each defaulting to `[]` — a hit on the ids
-- table with a miss on the ifaces table produced a length mismatch BY CONSTRUCTION, not
-- by corruption, which the downstream zips then silently truncated away.  `pairSlots`
-- is now the single place an id list meets an iface list, and the mismatch policy lives
-- there, once.
public export data CSlot = CSlot { csIface : IfaceRef, csId : Int }

-- B-4 (#1318): a non-authoritative view of ONE predicate-owned dictionary slot.
-- `PSArgsUnknown` is not `PSArgsKnown []`: the former means the legacy argument-vector
-- row was absent or its prefix ended before this slot, while the latter is a known
-- nullary predicate.  [psBoundIds] is likewise the whole ordered id projection for the
-- predicate.  Function slots currently contribute one lead id; impl-`requires` slots
-- contribute every id in their argument vector.
public export data PredicateSlotArgs = PSArgsUnknown | PSArgsKnown (List Mono)

public export data PredicateRequest = PredicateRequest {
  prIface : IfaceRef,
  prArgs : PredicateSlotArgs,
}

public export data PredicateSlot = PredicateSlot {
  psIface : IfaceRef,
  psArgs : PredicateSlotArgs,
  psBoundIds : List Int,
}

-- One method-level predicate and the stable positions of every quantified variable
-- it mentions.  The positions, unlike allocation-local tyvar ids, survive the
-- separate scheme builds used by module discovery and final elaboration.
public export data MethodPredicateSlot = MethodPredicateSlot {
  mpsPredicate : PredicateSlot,
  mpsPositions : List Int,
}

-- The interface predicate attached to an ordinary return method before call-site
-- instantiation.  Every interface formal occupies one ordered position.  An absent
-- formal stays absent: no fresh inference variable is manufactured for a name the
-- method scheme does not quantify.  The occurrence's own variable for it is the
-- request's `mrrOmitted`.
public export data MethodPredicateTemplate = MethodPredicateTemplate {
  mptInterface : IfaceRef,
  mptArguments : List (Option Mono),
}

-- One interface-method declaration, its scheme, and the method-level predicate slots
-- built from that scheme's own type-variable allocation.  Rows stay local to environment
-- setup: they carry live cells and are not a cache or published solver artifact.
public export data MethodSchemeRow = MethodSchemeRow {
  msrIface : IfaceRef,
  msrName : String,
  msrTyparams : List String,
  msrType : Ty,
  msrScheme : Scheme,
  msrPredicateTemplate : MethodPredicateTemplate,
  msrMethodSlots : List MethodPredicateSlot,
}

public export data MethodInstantiationSubst = MethodInstantiationSubst {
  misTypeSubst : List (Int, Mono),
  misEffectSubst : List (Int, Ref Effvar),
  misAuthSubst : List (Int, Authority),
}

public export data MethodTrackedInstantiation = MethodTrackedInstantiation {
  mtiBody : Mono,
  mtiForce : EffRow,
  -- the scheme's residual obligations under this occurrence's substitution
  mtiResidual : List AuthResidual,
  mtiSubstitution : MethodInstantiationSubst,
}

-- One complete ordinary-return judgment, owned by the occurrence request.  The
-- selected row is retained only as projection data for route lowering: every match
-- decision is represented by [mrrOutcome], and no consumer may select again.
public export data MethodReturnResolution = MethodReturnResolution {
  mrrWanted : Wanted,
  mrrOutcome : SolverOutcome,
  mrrSelectedRow : Option ImplRow,
}

-- One ordinary method occurrence, tied to the declaration row that supplied its
-- scheme.  The producer instantiates method-level slots immediately from that row and
-- its tracked substitution, then retains only the declaration descriptor and live
-- occurrence.  A marked return site adds the goal id minted at recordSite; the
-- unmarked checker keeps None rather than minting an unconsumed evidence id.
public export data MethodReturnRequest = MethodReturnRequest {
  mrrIface : IfaceRef,
  mrrName : String,
  mrrTyparams : List String,
  mrrType : Ty,
  mrrOccurrence : Mono,
  mrrEnclosing : String,
  mrrLoc : Option Loc,
  mrrScope : ScopeId,
  mrrGoalEv : Option EvId,
  mrrQualifiedBody : Mono,
  mrrPredicateTemplate : MethodPredicateTemplate,
  -- the occurrence's variable for each typaram the declared type never mentions
  -- (`omittedParamVars`); it fills an absent template position only when no given
  -- answers the template (`methodReturnPredicateFromTemplate`)
  mrrOmitted : List (String, Mono),
  mrrResolution : Ref (Option MethodReturnResolution),
}

public export data NumAnchorTestObservation = NumAnchorTestObservation {
  natoCase : String,
  natoHasRow : Bool,
  natoIface : String,
  natoSchemeBody : String,
  natoDeclaredType : String,
} deriving (Eq, Debug)

public export data MethodRowTestObservation = MethodRowTestObservation {
  mrtoSchemeIds : List Int,
  mrtoSlotBoundIds : List (List Int),
  mrtoSlotPositions : List (List Int),
  mrtoSlotIdsAtPositions : List (List Int),
  mrtoSlotArgumentIds : List (List Int),
  mrtoCounterBefore : Int,
  mrtoCounterAfterFirst : Int,
  mrtoCounterAfterSecond : Int,
  mrtoFirstSchemeIds : List Int,
  mrtoSecondSchemeIds : List Int,
  mrtoFirstRowSlotIds : List (List Int),
  mrtoSecondRowSlotIds : List (List Int),
  mrtoRegistryAfterSecondSlotIds : List (List Int),
  mrtoSameNameForward : List (String, String, Int, Int),
  mrtoSameNameReverse : List (String, String, Int, Int),
  mrtoConstantRowCount : Int,
  mrtoConstantSchemeIdCount : Int,
  mrtoConstantBodyIsFunction : Bool,
  mrtoConstantSlotCount : Int,
  mrtoAttributedRowCount : Int,
  mrtoAttributedParamIface : String,
  mrtoAttributedParamTyparams : List String,
  mrtoNumAnchors : List NumAnchorTestObservation,
} deriving (Eq, Debug)

-- B-2.2-f (#1113): how many of a constrained callee's slots were PRESENT BEFORE
-- `expandSupersPairs`' transitive super expansion APPENDED any.
-- That wording is the correction, and the direction of the old one matters.  This
-- comment used to say "DECLARED by its own `=>` context", which is FALSE on a live
-- path: `setFunConstraintEntry`'s second caller mints slots from INFERRED constraint
-- ids, with no `=>` context anywhere, and those are recorded as `CDPLen` too.  The
-- BEHAVIOUR is right — the operative property is "not appended by
-- `expandSupersPairs`", and an inferred slot is not appended — but a reader taking the
-- old definition literally would conclude the inferred path OVER-records and "fix" it
-- by lowering the count, withholding identity from real slots.  Do not.
-- Carried per ENTRY, beside the ids table (never inside `CSlot`) — the
-- recursive-call arm (`realizeRecDictApps` -> `recRoutes` -> `resolveRecMono`) reads
-- `funConstraintsRef` as a bare `List Int` and constructs no `CSlot` at all, so a
-- per-slot field could not serve it.
--
-- two-valued on purpose.  Absence is NOT `0` and NOT `Option Int`:
--   * `0` is a genuinely RECORDED state (`registerMember` guards on the constraint
--     list, not on the surviving slots, so an entry with zero declared slots is real),
--     so spelling absence `0` makes the two indistinguishable;
--   * `Option Int` collapses at the read site through one invisible `optionOr 0`
--     (99 uses of `optionOr` in `compiler/`), which is exactly the erasure this
--     distinction exists to survive.
-- `CDPUnknown` has no prelude eliminator and the token exists nowhere else in the
-- tree, so "is any site collapsing absence into a length?" is one grep.
--
-- FAIL-CLOSED: `CDPUnknown` means WITHHOLD identity (behaves as prefix 0).  The
-- opposite default stamps identity onto APPENDED super slots, which is the defect this
-- sidecar exists to prevent.
public export data CDeclaredPrefix = CDPUnknown | CDPLen Int

-- B-2.2-f (#1113): the result of the ONE declared-slot resolution.  The slots and the
-- declared prefix must come from the SAME entry decision (qual hit / known-import miss
-- / bare fallback) — a second accessor re-deriving that choice is the drift
-- `qualConstraintKey` was factored out to remove.  See `declaredConstraintFor`.
--
-- S-xmod-vector-supply (#1868/#1867): [cdArgs] joins the SAME entry decision for the
-- same reason.  It is the callee's slot-parallel predicate ARGUMENT VECTORS — a
-- legitimate PREFIX of [cdSlots], never a parallel list a reader must re-align (a slot
-- past its end reads `[]`, i.e. "no vector recoverable", via `zipSlotVecs`).  Resolving
-- it through a SECOND `qualConstraintKey` call was the available alternative and is
-- exactly the drift this record exists to prevent: the vectors and the slots they
-- describe would then be free to come from different modules' entries.
public export data CDeclared = CDeclared {
  cdSlots : List CSlot,
  cdPrefix : CDeclaredPrefix,
  cdArgs : List (List Mono),
}

-- FIX-shadow-arity-skew: the shadow route's expanded dict slots, the SAME three
-- slot-parallel projections `inferDictAtFound` hands `pushDictApp` — monos, route WORDS
-- (iface spellings), and each slot's call-instantiated predicate ARGUMENT VECTOR.  The
-- vectors are the shape `declaredConstraintFor` fills its `cdArgs` from
-- (`predicateSlotArgs`): `SKRLocal` carried only the first two, so `resolveRLocalSites` selected every
-- shadow-route slot with the SCALAR `routesOfMonosTop` goal and a multi-argument
-- predicate shattered into `Ix Int _`, first-declared-wins.  They travel as ONE record
-- for the reason `CDeclared` does: three parallel lists a reader must re-align is the
-- hazard `CSlot` was introduced to remove, and `callArgVecsV` only guarantees
-- slot-parallelism with the `constraintMonosOf` output computed from the same expansion.
-- [sdArgVecs] empty ⇒ `routesOfMonosTopV` IS `routesOfMonosTop`, term for term.
public export data ShadowDicts = ShadowDicts {
  sdMonos : List Mono,
  sdIfaces : List IfaceRef,
  sdArgVecs : List (List Mono),
}

public export data Predicate = Predicate { iface : IfaceRef, args : List Mono }

-- The impl-`requires` adapter keeps the dict parameter name beside the carrier rather
-- than pretending it is part of predicate identity.  Unlike a function CSlot, this
-- producer already owns the predicate's complete ordered bound-id vector.
-- #991: every arm below is now LIVE — stamped by the producer that records the
-- obligation, on the ONE storage shape (`UObligation`).  The three arms that read
-- "impl channel, not yet ported" until #991 were dead because that channel stored a
-- bare 5-tuple with no provenance slot at all; it does not any more (see
-- `OblProjection`).  `prov` is still documentary — no checker branches on it (§2.3(a));
-- it is stamped so the I2 uniform-deferral work does not need a second migration.
public export data Provenance =
  -- +,-,*,/,%, ==,/=,<,>,<=,>=, ++, unary -  (recordIfaceObligation)
  | POperator
  -- a numeric literal's Num obligation  (inferNumLitBare)
  | PNumLit
  -- a registered interface-method occurrence  (recordImplObligation)
  | PMethodOcc
  -- a constrained-fn call's shattered dict slot / signature constraint occurrence
  | PCallSlot
  -- re-instantiation of a binding's deferred predicate (schemeObligationsRef)
  | PSchemeReinst
  -- a method-level `=>` constraint slot  (#818, I3)
  | PMethodLevel

-- ── #991: HOW an obligation's DISPATCH VECTOR is obtained ────────────────────────
-- The call channel projects its vector at RECORD time (the producer already has the
-- instantiated monos).  The impl channel CANNOT: `recordImplObligation` records a
-- method OCCURRENCE mono against the method's DECLARED type, and the projection
-- `dispatchMonosOf typarams mty occ` is only meaningful once inference has grounded
-- the shared cells — improvement, determination and defaulting at each group's close
-- unify through them after the occurrence is recorded.  Projecting at record time
-- would therefore read a vector that is empty or under-determined.
--
-- this is the fact #991's body did not have.  It predicted "byte-identical target:
-- checker semantics are already unified, this changes only the record shape" and
-- proposed dropping the tuple onto `UObligation` outright.  A straight port would have
-- moved a CHECK-time projection to RECORD time — a semantics change, not a shape
-- change.  Carrying the deferral as an explicit arm keeps the projection where it was
-- (`uOblArgs`, called by the checker) while still giving both channels ONE record.
--
-- `pred.args` IS EMPTY on an `OpMethodOcc` obligation, and reading it directly is
-- the one way to get a wrong answer here.  `uOblArgs` is the ONLY legal reader of an
-- obligation's dispatch vector; it is total over all arms.  (An empty vector is inert
-- at the gate — `checkOneCallObligation` returns on `isEmptyL args` — so a stray direct
-- read would be SILENT, which is why there is a single accessor rather than a rule.)
public export data OblProjection =
  | OpProjected
  -- typarams, declared method type, occurrence, and the occurrence's variable for
  -- each typaram the declared type never mentions (`methodOmittedVars`)
  | OpMethodOcc (List String) Ty Mono (List (String, Mono))
  | OpExactReturn MethodReturnRequest
  | OpNumLit Mono

public export data UObligation = UObligation {
  pred : Predicate,
  originId : Int,
  prov : Provenance,
  loc : Option Loc,
  uoScope : ScopeId,
  oblProj : OblProjection,
}

-- The legacy absorption trail records concrete bounds introduced into a tail.
-- Store the cell, not only its stable identity: later links can move the live
-- representative, and the boundary checks need its current residual leaves.
-- Windows isolate bodies, matching the obligation channel's scope.
public export data AbsorptionEvent = AbsorptionEvent {
  atom : Atom,  -- the concrete atom absorbed into a shared tail
  cell : Ref Effvar,  -- resolve the absorbing tail live at query time
  loc : Option Loc,  -- the enclosing construct's span at the unify, for the diagnostic seam (None-safe)
}

-- #1155 (F-3c): [pdaLoc] is the enclosing construct's span snapshotted at the RECORD
-- site, the same reason and the same shape as `PendingEntry`'s 6th field and
-- `implObls`' 5th element — `resolveDictApps` runs post-HM, outside every
-- construct.  `resolveDictApps` hands it down as the walk's `sxSite`.
public export data PendingDictApp = PendingDictApp {
  -- #2549 M2: the goal's OWN cell, minted with the goal.  It used to be the
  -- `EDictAt` node's cell, which is how a reader reached the answer; the node now
  -- carries `pdaEv` instead and the reader looks that up in the published table, so
  -- this cell is private to the solver — the stampers' write target, read back once
  -- by `recordEvidence` and by nothing outside `compiler/types/typecheck.mdk`.
  pdaRoutesRef : Ref (List Route),
  -- #2549 M2: this application's evidence id, the same field `PendingEntry` carries
  -- as its 7th and for the same reason.  Taken from the node (`inferDictAt`), not
  -- minted here, so the id names the occurrence rather than the moment the goal was
  -- queued — that is what makes the node's lookup find this goal's answer.
  pdaEv : EvId,
  pdaMonos : List Mono,
  pdaIfaces : List IfaceRef,
  pdaArgVecs : List (List Mono),
  pdaEncl : String,
  pdaLoc : Option Loc,
  pdaScope : ScopeId,
  -- the callee as written, which the completeness judgment's diagnostic names
  pdaCallee : String,
}

-- Method-level-constraint dict-passing.  `methodPredicateSlotsRef` is the sole
-- per-run authority: each method constraint owns one complete PredicateSlot and the
-- stable quantifier positions needed to instantiate it at an occurrence.  Positions
-- survive the separate fresh-id scheme builds used by discovery and elaboration;
-- dictionary cardinality is the number of MethodPredicateSlot records, never the
-- number of bound ids inside a predicate.  `pendingMethodDicts` carries the resulting
-- instantiated PredicateSlots until `resolveMethodDicts` routes them after inference.
--
-- Every row is keyed by `methodSlotKey`: the declaring interface's identity plus the
-- method's declared name, never the bare spelling.  An occurrence reads the row of
-- the declaration its module admits for the spelling (`methodIfaceHere`), so a
-- same-spelled method of another interface, in this module or any other, cannot
-- lend it predicate slots or an arity.  Cross-run snapshots retain the same payload.
public export data PendingMethodDict = PendingMethodDict {
  pmdRoutesRef : Ref (List Route),
  -- #2549 M2: this application's evidence id — see `pdaEv`.
  pmdEv : EvId,
  pmdSlots : List PredicateSlot,
  pmdEncl : String,
  pmdScope : ScopeId,
  -- the method cell's `ecInner`
  pmdInner : Ref Inner,
}

-- #158 PR2: the per-run cross-module accumulators declared above (the six
-- crossModule* dict-arity mirrors of #143/#144, plus the #154 universe*/obUniv* universe
-- accumulators) are bundled into ONE typed record so their survive/clear lifecycle is a
-- TYPE FACT, not prose.  `freshCrossRun` constructs exactly the field-Refs that
-- `mintGraphCtx` installs, so "what survives a module" == "what CrossRun holds"
-- == "what a per-run reset clears" — enforced by the constructor: a new accumulator cannot
-- be added to the survive-set without appearing in freshCrossRun (and thus the reset).
-- This is a record OF Refs (fields stay `Ref …`), NOT a record of values: the grow helpers
-- (appendUniverseAccums / appendDataUniverse / growImplUniverse) and the Module-arm copies
-- mutate the field-Refs in place, so no whole-record copy is allocated per grow/push.
public export data CrossRun = CrossRun {
  universeFunNamesRef : Ref (OrdMap Unit),
  universeMethodDispatchIdxByIdRef : Ref (List ((IfaceRef, String), Int)),  -- #1351: the interface dispatch-index universe, keyed ((IfaceRef, method name), Int).  Its bare-name-keyed predecessor `universeMethodDispatchIdxRef` was RETIRED by L5 (CONTRACT) once `dispatchIdxScoped` stopped falling back to it — read via `methodDispatchIdxByIdRef`.
  -- Every registered head's parameters and constructors, from every module
  -- the universe has registered (the prelude's included), keyed by identity
  -- and read by `tyCarries`; a head absent here is abstract.
  universeDataCtors : Ref (List (TabKey, (DataVis, List String, List Variant))),
  -- Every public constructor's elaborated scheme and every public record's
  -- `RecordInfo`, one population per table, keyed by declaration identity and
  -- indexed by spelling (`SpellingPop`).  Grown only by `appendDataUniverse`, at
  -- the end of each module's arm in ordinal order, so module k reads exactly the
  -- public rows of the modules before it.  The floor (`spFloor`) is the bare-keyed
  -- last-write view: the ctor floor is the base of every Module-arm `dataEnv`
  -- (`withCtors`), the record floor seeds `recordByNameRef` (`loadDataUniverse`).
  universeCtorPop : Ref (SpellingPop Scheme),
  universeRecordPop : Ref (SpellingPop RecordInfo),
  -- TOMBSTONES.  Ten cross-run field-Refs were RETIRED from this record — seven
  -- `universe*` cells plus the three `obUniv*` — and each is now answered by a stage-K
  -- structure, projected at the READING module's own ordinal.
  -- Do not re-add a cross-run copy beside stage k (design law L1): that is two
  -- answers to one question, and the copy is always the one whose population depends on
  -- marshalling order.  Retired cell -> what answers it now:
  --   `universeRegisteredIfacesRef` (#1569) -- NOTHING.  Its only reader
  --      `ifaceRegistered` was deleted by #1539, leaving it and its `ModuleCtx` sibling
  --      write-only.  It was deliberately bare-name while it lived (#1111 A-2.4; the
  --      reasoning is kept in `builtinClassPresent`'s header).  Do not re-add either
  --      half without a reader.
  --   `universeFieldOwners` (A-3.2b slice 3, #1512) -- `declEnvsRef.deOwnersBefore`,
  --      one `omLookup` by loader module id over `declEnvSeedChain`'s prefix chain.
  --   `universeDataParamKinds` (A-3.2b slice 2, #1512) -- `declEnvsRef.deKindsBefore`,
  --      filled by `kindPublicDataDecl`, a PEER of `publicDataDecl` that also admits
  --      `VisAbstract` and public `DNewtype` because those are the decls
  --      `registerOpaqueParamKinds` used to publish separately (#804/#1028).  That pass
  --      is gone with this cell; re-add neither.
  --   `universeIfaceRequiredRef` (A-3.5a, #1557) -- stage K's `CE` already holds that
  --      value under that key (`ceRowRequired`); its one reader
  --      `implCompletenessMsgsOfMap` now calls `ceRequiredAt`, and the retired arm's
  --      separate bare-name scan `ifaceRequiredMethods` went with it, so there is now
  --      ONE impl-completeness checker for both modes.  It was never in the
  --      `loadDataUniverse`/`storeDataUniverse` ladder, so unlike A-3.5c its retirement
  --      cannot desynchronize that marshalling pair.
  --   `universeIfaceParamKinds` (A-3.5c, #1557) -- `declEnvsRef.deIfaces`, projected at
  --      the reader's ordinal by `ceSlotKindsAt`.  #822's iface half of the kind
  --      universe; its `ModuleCtx` half `ifaceParamKindsRef` and its writer went too.
  --   `universeAliasTable` (A-3.2b residual, #1512) -- `declEnvsRef.deData.deAliases`,
  --      projected by `aliasUniverseAt`.  A copy would silently carry
  --      `rejectCyclicAliases`' per-module deletions.
  --   `universeDataDecls` (A-3.2b, #1512 / #1319 unit 4) -- #674's positional overlay
  --      pool; both consumers now read `DeclEnvs.deModules` at the reader's own ordinal,
  --      the envelope already holding the whole graph keyed by loader module id.
  --   `obUnivConcreteRef`/`obUnivHeadlessRef`/`obUnivIfaceTagsRef` (A-3.4 PR2, #1112) --
  --      stage K's `IE` (`declEnvsRef.deImpls`, projected by `ieUniverseAt`) is the
  --      single answer to "what impls exist" on the Module path.  Not merely unread.
  -- Six more cells were FOLDED rather than projected, because their payload is
  -- elaborated and stage K is syntactic.  Each namespace had a bare-keyed floor
  -- plus an identity companion plus a collided list; each is now one population.
  --   `universeDataEnv`, `universeCtorIdentsRef`, `universeCtorCollidedRef` --
  --      `universeCtorPop`'s `spFloor` (read through `withCtors`), `spRows`,
  --      `spCollided`.
  --   `universeRecordByName`, `universeRecordIdentsRef`, `universeRecordCollidedRef`
  --      -- `universeRecordPop`'s same three projections.
  builtinClassesRef : Ref BuiltinClasses,  -- #1446 P1 + #1539 / DICT §8 I7: the four operator/literal classes' identities AND presence, read off the PRELUDE's own DInterface decls — see seedBuiltinClasses
  -- B-4 (#1318): one cross-run row per function, one carrier element per dictionary
  -- slot.  The bare table deliberately stores `PSArgsUnknown`; only the source-exact
  -- qualified table may transport signature-instantiation vectors across modules.
  crossModuleFunPredicateSlotsRef : Ref (List (String, List PredicateSlot)),
  crossModuleFunPredicateSlotsQualRef : Ref (List ((String, String), List PredicateSlot)),
  crossModuleFunConstraintDeclaredRef : Ref (List (String, CDeclaredPrefix)),
  crossModuleFunConstraintDeclaredQualRef : Ref (List ((String, String), CDeclaredPrefix)),
  crossModuleMethodPredicateSlotsRef : Ref (List (String, List MethodPredicateSlot)),
  crossModuleMethodPredicateSlotsQualRef : Ref (List ((String, String), List MethodPredicateSlot)),
  coreSchemeObligationsRef : Ref (OrdMap (List VecObl)),  -- #673: core's OWN schemeObligationsRef, snapshotted after the core pass (see declaredCrossModuleObls)
  crossModuleSchemeOblsQualRef : Ref (List ((String, String), List VecObl)),  -- #1114/#845: every USER module's schemeObligationsRef, (mid, name)-attributed (see attributeModuleSchemeObls)
}

-- self/mutually-recursive constrained-fn call sites.  At such a site the callee's
-- own constraints are not yet registered (its letrec group is still inferring),
-- so funConstraintsRef can't map its routes inline.  Defer them: RecDictApp holds
-- (routes ref to fill, callee name, the ENCLOSING fn's name, the live occurrence
-- mono).  realizeRecDictApps fills the routes after inference, forwarding the
-- enclosing fn's OWN dict parameter (RDict) for each constraint — the dict already
-- in scope in its body — rather than rebuilding one (which it cannot, the type is
-- still the constraint variable).  Mirrors the reference's recursive_promoted_usages
-- / realize_recursive_dict_apps (Phase 115/136).
-- #2549 M2: the 5th field is this application's evidence id — see `pdaEv`.
public export data RecDictApp =
  RecDictApp (Ref (List Route)) String String Mono ScopeId EvId

-- The construct that demands a value join's alternatives agree.
public export data JoinContext =
  | JoinIf
  | JoinElselessIf
  | JoinList
  | JoinCons
  | JoinArray
  | JoinMatch
  | JoinArgument
  | JoinClause

-- ── graph-lifetime state (#2547 unit 1, ARCH M1) ─────────────────────────────
-- What a module's `ModuleCtx` mint does NOT clear: the cells that must outlive a module so a
-- whole-graph resolve pass (#2548) can read them at quiescence, and the two counters
-- that keep every tyvar/effvar id unique across the graph so an entry recorded in one
-- module can never alias one recorded in another.  Minted once per graph by
-- `graphLineageRun` — from `mintGraphCtx` (every Module driver's preamble)
-- and from every graph preamble, including the one-module projection.
--
-- The channels are still drained per module today, by the stamper sequence in
-- `elabModuleStamp`, and that drain must see exactly this module's
-- entries: `recordModuleStart` notes each channel's length as the module begins and
-- `moduleRanges` keeps the (module id, marks) pairs — every entry a module records is
-- consed after its mark, contiguously, because modules are processed one at a time.
-- `moduleWindow` cuts the slice.  A graph-end drain takes the same slices from
-- `moduleRanges` instead of from its head.
--
-- Deliberately still per-module: `funPredicateSlotsRef` (keyed by bare binding NAME —
-- graph-global it would collide across modules; it is seeded from and written back to
-- CrossRun's tables per module already).  It is NOT a given table: its readers are the
-- DECLARED-slot consumers (`declaredConstraintFor`, `declaredConstraintIds`,
-- `inferDictAtFound`, `goalIdsClaimed`) plus `enclDictVarOf`, which derives a dict-param
-- name POSITIONALLY (`dictParamName encl <slot index>`) rather than reading a stored one.
-- `activeDictVars` IS here: keyed by tyvar id, which the graph counter keeps unique, so
-- an entry can only ever match its own module's sites.
public export data GraphMarks = GraphMarks { mGoals : Int, mNumlit : Int }

public export data AssumptionTraceKind =
  | ATDirectPredicate
  | ATLegacyScalar
  | ATSuperclassProjection
  | ATLegacyPredicate
  deriving (Eq, Debug)

public export data AssumptionTraceEntry = AssumptionTraceEntry {
  atGoalScope : ScopeId,
  atBinder : EvidenceBinderId,
  atKind : AssumptionTraceKind,
}

public export data NumericPredicateTraceStage =
  | NPTProduced
  | NPTChecked
  | NPTReturn
  | NPTArithmetic
  deriving (Eq, Debug)

public export data NumericPredicateTraceEntry = NumericPredicateTraceEntry {
  nptStage : NumericPredicateTraceStage,
  nptPredicate : ClassPredicate,
  nptScope : ScopeId,
  nptOrigin : Option Loc,
  nptSelectedInterface : Option IfaceRef,
  nptRoute : Option Route,
  nptPrerequisites : List Route,
}

public export data MethodReturnTraceStage =
  | MRTProduced
  | MRTChecked
  | MRTStamped
  deriving (Eq, Debug)

public export data MethodReturnTraceEntry = MethodReturnTraceEntry {
  mrtStage : MethodReturnTraceStage,
  mrtInterface : IfaceRef,
  mrtMethod : String,
  mrtArguments : Option (List Mono),
  mrtScope : ScopeId,
  mrtOrigin : Option Loc,
  mrtGoal : Option EvId,
  mrtPublished : Option EvVal,
  mrtQualifiedBody : Option Mono,
  mrtWanted : Option Wanted,
  mrtOutcome : Option SolverOutcome,
  mrtRoute : Option Route,
  mrtPrerequisites : List Route,
}

-- A drained ordinary-return observation safe to retain in a memo.  It deliberately
-- excludes Monos, ScopeIds, evidence binders, ImplRows, and the request's resolution
-- Ref; those values belong to the request that produced the closed route.
public export data MethodReturnMemoView = MethodReturnMemoView {
  mrmvInterface : String,
  mrmvMethod : String,
  mrmvArguments : Option (List String),
  mrmvOutcome : String,
  mrmvPrerequisites : List (String, List String),
  mrmvEvidence : String,
} deriving (Eq, Debug)

-- #2095: the classification of one solved route, over every family `entail` and the
-- return family answer — not a solver concept, a reading of the `Route` shape the
-- goal already carries.
-- `EOKGiven`/`EOKInstance` are `RDict`/`RDictFwd` and `RKey` respectively;
-- `EOKLocal` is `RLocal` (a definer-shadow seed; a dictionary-abstracted local's
-- own parameter is an `RDict`, so `EOKGiven`); `EOKScalar` is the
-- arithmetic/comparison builtin bypass (`RScalar`); `EOKNone` is `RNone`,
-- including a default body's sibling/super call and an entailment that found
-- nothing.
public export data EvidenceOutcomeKind =
  | EOKGiven
  | EOKInstance
  | EOKLocal
  | EOKScalar
  | EOKNone
  deriving (Eq, Debug)

-- One observation per solved route a published `EvId` carries: a method
-- occurrence (`GKReturnSite`/`GKArgStamp`/`GKRLocalSite`/`GKBinopSite`/
-- `GKUnopSite`/`GKArithSite`) publishes exactly one, a dictionary application
-- (`GKDictApp`/`GKMethodDict`/`GKRecDictApp`) publishes one per slot, `eoeSlot`-
-- indexed, all sharing `eoeArity` (the goal's total slot count). `eoePredicate`
-- is the slot's own constraint, rendered (`ppMono`) rather than carried as a raw
-- `Mono`, because a solved `Mono`'s tyvars are not meaningfully comparable across
-- two typecheck runs. `eoeGivenBinder`/`eoeInstanceKey` name the binder or the
-- instance's route key when the outcome is `EOKGiven`/`EOKInstance`;
-- `eoePrerequisites` is the nested-route list `RKey`/`RLocal` pack at this slot,
-- rendered the same way: the family's packed-requires or element-dict list.  A
-- superclass projection of a given is visible here only as the flat slot's binder
-- it lowers to (`givenEvidenceBinder`).
public export data EvidenceObservationEntry = EvidenceObservationEntry {
  eoeEv : EvId,
  eoeGoalKind : String,
  eoeSlot : Int,
  eoeArity : Int,
  eoePredicate : Option String,
  eoeOutcome : EvidenceOutcomeKind,
  eoeGivenBinder : Option String,
  eoeInstanceKey : Option String,
  eoePrerequisites : List String,
  eoeScope : ScopeId,
}

public export data AssumAnswer =
  | SemanticGiven SolverEvidence
  | LegacyScalar EvidenceBinderId
  | LegacyPredicate EvidenceBinderId
  -- a projection of the given at the binder along a direct-super path, reached
  -- through a rung that does not qualify as semantic evidence
  | LegacyProjected EvidenceBinderId (List Int)

-- #2547 unit 3: ONE stored given — the predicate a dict parameter discharges, and the
-- parameter's name.  The two per-module tables this replaces (`activeDictPreds`, keyed
-- `(slot, dname)`, and `implReqPredicateSlots`, keyed `(dname, slot)`) held the same pair
-- in opposite orders and were scanned by two helpers whose match tests were identical
-- term for term (`implReqPick` vs `firstPredForEnclAt`).
--
-- The predicate identity is `PredicateSlot` — `psIface : IfaceRef` already carries
-- `irOrigin` beside `irName`, and `predicateRequestMatchesSlot` already discriminates on
-- it through `sameIfaceDecl`.  No identity type is introduced here: one that re-stated
-- `IfaceRef`'s (name, origin) pair would be a second spelling of the same fact, and the
-- vector half (`psArgs`) and the bound-id half (`psBoundIds`) are already on the slot.
--
-- Ownership is nominal: `geBinder` carries the binding scope and slot ordinal.
-- Readers prove that binder scope is the goal scope or one of its lexical ancestors;
-- rendering to the existing `$dict_<owner>_<slot>` ABI spelling happens only after a
-- final assumption answer has been chosen.
--
-- [geMatch] is what makes ONE environment sound, and it is a property of the given,
-- not a record of which table it came from.  MEASURED: merging the two tables with no
-- such field loses `test/eval_typed_modules_fixtures/impl_requires_nonfunctor_sibling`
-- to `runtime error [E-PANIC]: no matching impl for dispatch` — every other route
-- golden in the dict-semantics conformance gates stays green, so an
-- undifferentiated merge is a SILENT re-widening on every path that fixture does not
-- cover.  See `GivenMatch`.
public export data GivenEntry = GivenEntry {
  geSlot : PredicateSlot,
  geBinder : EvidenceBinderId,
  geMatch : GivenMatch,
  geProvenance : GivenProvenance,
}

-- A given is either declared (a signature slot, an impl `requires` slot) or the
-- projection of a declared given onto one of its interface's transitive supers.
public export data GivenProvenance =
  | DirectGiven
  | ProjectedGiven EvidenceBinderId (List Int)
  deriving (Eq)

-- May this given answer a goal on predicate identity alone, or only when the asker also
-- witnesses that the goal's dispatch variable is one the slot binds?
--
-- The distinction is the ARGUMENT VECTOR's precision.  `monoVecSameGiven` is an identity
-- test on a vector with a structured position, but on an ALL-BARE vector it degenerates
-- to raw tyvar-id equality at every position — so two `requires` slots of the same
-- interface over different parameters (`requires Debug e, Debug a`) are indistinguishable
-- to a predicate-only reader, and one answers for the other.  `containsI target
-- psBoundIds` is the missing discriminator, which is why the id-witnessed rung may read
-- these and the predicate-only rungs may not.
public export data GivenMatch =
  -- The vector carries a structured position (`registerPredGiven`'s all-bare guard) or
  -- the given is a declared signature slot / one of its transitive supers
  -- (`registerFunPredGiven`).  Matchable by predicate alone.
  | GMPredicate
  -- Every position is a bare tyvar: an impl `requires` slot, which `registerPredGiven`
  -- deliberately refuses to register at all.  Readable only through a scan that supplies
  -- a tyvar-id witness.
  | GMIdWitnessed

-- #2705 (M2 phase 2): the solver's working cells for ONE `EMethodAt` node, keyed by
-- the node's `EvId`.  The node itself carries no cell any more — a reader outside
-- `compiler/types/typecheck.mdk` gets the answer from the published table (`evMethodRoutesIn`) — but the
-- stampers still write through `Ref`s (every goal destination is an `EvDest` over
-- one), so the cells live here, minted with the node (`mintMethodCell`) and read
-- back by `cellEntriesFrom` when the table is published.  It owns five cells:
-- the interface identity the occurrence resolved to, the selected denotation's
-- pre-use arrow arity, the dispatch route, the selected impl's `requires` dicts,
-- and the method's own `=>` dicts.
-- Two channels carry one fact: inside `compiler/types/typecheck.mdk` a reader dereferences the live
-- cell, outside it reads the published snapshot, and "no cell is written after the
-- last publish" is a discipline of the drain's schedule, not a type.  The mutable
-- half is what the target's evidence-bindings step retires; until then it is the
-- solver's working store and nothing else may write it.
public export data EvCell = EvCell {
  ecId : EvId,
  -- the `ifaceWordOf` word of the interface whose method this occurrence denotes;
  -- `""` while undecided and for an occurrence that denotes a standalone
  ecIface : Ref String,
  ecArity : Ref (Option Int),
  ecTag : Ref Route,
  ecImpl : Ref (List Route),
  ecMeth : Ref (List Route),
  -- the occurrence's span and spelling, written when it is inferred, for the
  -- completeness judgment's diagnostic (`judgeEvidence`); `None` and `""` for a
  -- node no inference reached
  ecLoc : Ref (Option Loc),
  ecName : Ref String,
  -- what the stampers built below the top level of the three routes, noted by every
  -- goal that writes them (`Obligation.oInner`)
  ecInner : Ref Inner,
}

-- The solver's working cell for one site node, keyed by the `EvId` the mark pass
-- minted into it (`mintOpSite`).  The writers obtain the same `Ref` the node
-- carried before it carried an id; `cellEntriesFrom` reads each back into the
-- published table, under the node's id, for the readers in `types/route_key.mdk`.
public export data SiteCell =
  -- an operator or wide literal: its dispatch route
  | OpSite (Ref Route)
  -- a numeric literal: its defaulted float and its `fromInt` route
  | LitSite (Ref (Option Float)) (Ref Route)
  -- a field access or record update: its resolved record head
  | HeadSite (Ref String)

public export data GraphRun = GraphRun {
  tyvarCounter : Ref Int,
  effvarCounter : Ref Int,
  -- The quantified authority ids of every constructor scheme that are
  -- EXISTENTIAL (a binder written on the constructor, not the head); keyed by
  -- the id itself, so a same-named constructor in another module cannot
  -- answer.  It lives with the id counter: a record or scheme the universe
  -- seeds into a later module carries cells minted here, and their ids must
  -- still answer there.
  ctorExistentialsRef : Ref (Map Int Unit),
  -- The ids of every authority variable minted pattern-ranging, kept beside
  -- the counter for the same reason: an instantiation checks that such an id
  -- still has its cell (`freshInferenceAuthvar`).
  patternAuthIdsRef : Ref (Map Int Unit),
  -- set once any constructor with an existential binder is registered, so a
  -- program without one pays nothing per pattern
  anyExistentialsRef : Ref Bool,
  -- #2547 unit 2: the ONE channel for the route-stamped site goals (return sites,
  -- arg stamps, RLocal sites, binop/unop sites, arithmetic sites) — see `Obligation`.
  goals : Ref (List Obligation),
  -- #991 ask 3, RULED: the numeric-literal channel STAYS BESPOKE — it is
  -- Float-DEFAULTING machinery (`setNumlitFloats`), not obligation checking, so it is
  -- deliberately NOT ported onto `UObligation` like `implObls` was.
  numlitRefs : Ref (List (Mono, Ref (Option Float), Int, Ref Route)),
  -- the numlit channel's length, maintained by `pushNumlit` beside every write, so a
  -- mark is O(1) — the goals channel's `goalsN`, for the one other windowed channel
  numlitN : Ref Int,
  activeDictVars : Ref (List (Int, EvidenceBinderId)),
  -- #2547 unit 3: the given environment, keyed by MODULE.  Graph lifetime, but NOT
  -- graph-global visibility: every read derives a module bucket from the captured
  -- goal scope, then applies lexical ancestor visibility to each binder.  A given from
  -- module A therefore cannot answer a goal in module B, and sibling binding scopes
  -- cannot answer one another even when their rendered names share a prefix.
  gGiven : Ref (OrdMap (List GivenEntry)),
  moduleRanges : Ref (List (String, GraphMarks)),
  -- #2548: one `StampCtx` per module that finished elaborating, NEWEST FIRST, cut at
  -- the point that module's stampers used to run.  `drainStampQueue` replays them in
  -- module order at graph end.  See `StampCtx`.
  stampCtxs : Ref (List StampCtx),
  -- the channel's length, maintained by `pushGoal` / `dropGoalsSince`, so a mark is
  -- O(1) — `goalsMark` is taken at every `let` and SCC bracket
  goalsN : Ref Int,
  -- #2549 M2: the ordinal source for this run's evidence ids.  Graph-global and
  -- monotone, so `EvId <module> <ordinal>` is unique across the whole run without a
  -- per-module reset — see `freshEvId`.
  evCounter : Ref Int,
  -- The counter's value when this graph lineage began (`graphLineageRun`).  Every
  -- array indexed by ordinal holds only ordinals from here up, so an id below it is
  -- from an earlier graph.
  evBase : Int,
  -- The ordinal below which every method cell has been judged complete
  -- (`judgeEvidence`).  Each drain judges the cells minted since the last one and
  -- raises it to `evCounter`, so a module drained at its own end has its holes
  -- reported once.
  evJudged : Ref Int,
  -- The ordinal ranges [lo, hi) a recording module's own drain judged ahead of the
  -- watermark above; the drain that reaches them skips them (`unjudgedRanges`).
  evScopedJudged : Ref (List (Int, Int)),
  -- #2549 M2: the solved evidence, one entry per goal, appended by the graph-end
  -- drain as each module's stampers finish.  It is a SECOND RENDERING of the routes
  -- the stampers wrote into their cells, read back from those same cells, never an
  -- independently-derived answer.
  evTable : Ref EvTable,
  -- #2705: the method-occurrence cells, indexed by the node's evidence ORDINAL less
  -- `evBase`, so a stamper's lookup is O(1) and the array spans one lineage, not the
  -- process.  Sized by doubling as ids are minted.  `graphLineageRun` starts it empty.
  evCells : Ref (Array (Option EvCell)),
  -- The operator, literal and record-head site cells with the id each was minted
  -- under, indexed exactly as `evCells` is (ordinal less `evBase`, doubled as ids
  -- are minted, empty after a reset).
  siteCells : Ref (Array (Option (EvId, SiteCell))),
  scopeStore : ScopeStore,
  -- Dictionary-abstracted local bindings (`registerLocalAbs`).  Graph-owned so a
  -- renamed binder's spelling depends only on this elaboration; `graphLineageRun`
  -- carries it, clearing only its quantified ids.
  localAbs : LocalAbsState,
  -- The authorities each occurrence of an authority-quantified binding was
  -- granted, and each binder's own authority parameters (`GrantState`).
  grants : GrantState,
  -- Each binder inference has typed since the last drain, newest first, with the
  -- type cell still live; `materializeBinderTypes` reads them into `binderRows`.
  binderPending : Ref (List PendingBinder),
  -- The runtime-type table this graph publishes (`types/runtime_types.mdk`),
  -- holding only materialized rows, so a memo snapshot of it shares no cell.
  binderRows : Ref BinderTypeTable,
  -- The variables non-generalized top-level members left open at their module's
  -- end (DICT-SEMANTICS §6.2 T2), which a later module can still ground; those of
  -- them a `Num` goal constrains; and the goals on the latter, which D3 clause 3
  -- tests when the graph-end drain defaults them (`defaultLiveNumRoots`).  Every
  -- drain empties them.
  liveRoots : Ref (List Mono),
  liveNumRoots : Ref (List Mono),
  liveNumGoals : Ref (List UObligation),
  -- The goals boundaries held on those variables without judging them, for the
  -- drain's verdict (`judgeLiveGoals`).  Every drain empties it.
  liveGoals : Ref (List LiveGoal),
}

-- What one graph run hands the next: the evidence-ordinal counter, the binder-name
-- state and the grant state, as the objects of the run most recently minted (not copies),
-- so the next lineage continues from the counter's value at the next mint.
-- `lnTyvarHigh` and `lnEffvarHigh` are the highest type- and effect-variable
-- counters any drive that serves module interfaces ended at.  Such a drive starts
-- its counters there, so no variable it mints shares an id with a variable an
-- interface it serves was recorded with.
public export data Lineage = Lineage {
  lnEvCounter : Ref Int,
  lnLocalAbs : LocalAbsState,
  lnGrants : GrantState,
  lnTyvarHigh : Ref Int,
  lnEffvarHigh : Ref Int,
}

-- The process's interners: what outlives a drive on purpose.  The evidence lineage
-- keeps ids and local binder names unique across the drives of a long-lived
-- process; the builtin extern catalog is the union of every catalog a drive built,
-- because a later drive with a shorter runtime list must not exempt the FFI guards.
-- Both are the objects of the graph record most recently minted or restored.
public export data Interners = Interners {
  lineage : Lineage,
  externCatalog : Ref (OrdMap (Ty, List (String, Int))),
}

-- One binder awaiting the drain: its id, source name, type cell, for a
-- function binder the declared parameter count its return type is read after,
-- and whether the binder's function has a declared type signature.
public export data PendingBinder =
  PendingBinder BinderId String Mono (Option Int) Bool

-- What a rung declares it can soundly read out of the one environment.  This is the
-- eligibility half of `GivenMatch`, and the only place the two interact.
public export data GivenScope =
  -- The rung matches on predicate identity alone, so an all-bare `requires` vector would
  -- answer for a sibling slot of the same interface.  Skip those.
  | GSPredicateOnly
  -- The rung is the impl-`requires` rung: it is keyed on the `requires` slots and
  -- supplies `containsI target psBoundIds` as the discriminator the bare vector lacks.
  --
  -- It reads GMIdWitnessed givens ONLY.  Widening it to the signature-channel givens
  -- as well — which looks free, because `enclDictVarOf` runs ahead of it in
  -- `activeDictVarOfEncl` applying a term-for-term identical test — loses
  -- `impl_requires_nonfunctor_sibling` the same way an undifferentiated merge does:
  -- `registerFunPredGiven` also registers each slot's TRANSITIVE SUPERS, which
  -- `enclDictVarOf` never sees, so this rung would answer a super where today the answer
  -- comes from `activeDictPredOf` one rung later, off a different first match.
  | GSImplRequires

-- A produced-value join recorded before any alternative had a shape: the
-- variable standing for its result, the alternatives, the inference level it
-- was recorded at, and the construct and row collector its services are built
-- from.  The services themselves are not stored: the call that settles the join
-- rebuilds them with its own `DynCtx`, so a join settled inside a non-covariant
-- slot reads that slot, while its construct is the one it was recorded under.
public export data PendingJoin = PendingJoin {
  pjResult : Mono,
  pjValues : List (Option Loc, Mono),
  pjLevel : Int,
  pjContext : JoinContext,
  pjCollector : DynCtx -> List EffRow -> EffRow,
}

-- The match oracle and the warnings list a module's check starts from
-- (`seedCheckRun`): the oracle built from the module's decls and an empty list.
public export data CheckRunSeed = CheckRunSeed {
  crsOracle : Oracle,
  crsWarnings : List TcDiag,
}

-- One module's state: its cells, the graph record it is checked in, and the span of
-- the construct around the check.  `checkBodyImpl` mints it once per module
-- (`freshModuleCtx`) and returns it, so the constructor is the reset: a new per-module
-- field cannot be added without appearing in `freshModuleCtx`, nor without a class in
-- the module-field partition (`moduleCtxFrom`, `moduleCellsFrom`).  The drivers hand
-- the record to every reader after the module (the graph-level diagnostics, and
-- `driveOutputsNow`, which freezes `lastInvocationOps`' view); every reader receives
-- it as a parameter, or through `DynCtx.dcModule` / `SiteCtx.sxModule`.  The span
-- changes at every construct, so the record a construct copies holds three fields and
-- the cells are one value every copy shares.
public export data ModuleCtx = ModuleCtx {
  -- The module's cells, shared by every copy of the record: a construct's copy
  -- (`mctxAt`) replaces the span and keeps this one value.
  mcCells : ModuleCells,
  -- The graph record of the drive the module is checked in: the record the driver
  -- passes to the module's mint, never read from a cell.  A memo stores a record whose
  -- graph is the memo's own detached snapshot, and a hit re-points it at the hitting
  -- drive's record, so no stored record keeps a drive's graph alive.
  mcGraph : GraphCtx,
  -- The span of the innermost construct around the check: the `ELoc` the walk is
  -- inside, or the span a construct without one names for its own checks (`mctxAt`).
  -- A construct hands its sub-walk an updated copy, so the span is gone when the
  -- sub-walk returns.  `None` outside every construct: a mint starts with none, a
  -- whole-record copy takes its run record's (none), and a post-inference pass
  -- runs in a module-level record.
  mcLoc : Option Loc,
}

-- The cells of one module's state (`ModuleCtx.mcCells`).  This is a record OF Refs
-- (fields stay `Ref …`), NOT a record of values: the hot accumulators (typeErrors,
-- poisonedVars, localBindRefs, …) are pushed with `setRef x (v :: x.value)`, so the
-- field must be a Ref for that to stay one Ref-write — a record of values would rebuild
-- the whole record on every push.  (`obls`, `implObls` — #838 I1 / #841 — are the
-- exceptions: each a small `Windowed a` VALUE whose own two fields are Refs — see
-- `wPush` — so pushing through one is still one Ref-write, not a whole-record rebuild.)
--
-- The fields after `markingRef` are the module's inputs and tables.  `checkBodyImpl`
-- writes each before any read, except `currentModuleRef`, `matchOracle` and
-- `matchWarnings`, which the mint sets: the module id, and the `CheckRunSeed` (or, on a
-- path that does not seed, the previous record's oracle and warnings).
public export data ModuleCells = ModuleCells {
  currentScope : Ref ScopeCursor,
  -- #2705 / S2-DECL (d): method occurrences whose bare spelling has two or more
  -- admitted declarations in this module's scope — (name, the occurrence's
  -- instantiated method type, its location), checked by `checkAdmittedOccObls`
  -- once the receiver has grounded.  See `recordImplObligation`.
  admittedOccObls : Ref (List (String, Mono, Option Loc)),
  curEffect : Ref (List EffRow),
  effectSummaries : SummarySolver ObligationSite,
  -- joins of alternatives that had no shape yet, newest first, decided when
  -- the binding scope they were recorded in closes (`resolvePendingJoins`)
  pendingJoinsRef : Ref (List PendingJoin),
  fileValueFlows : Windowed (Option Loc, Mono, Mono),
  fileValueScopes : Ref (List (List (Option Loc, Mono, Mono), Int)),
  rigidEffvarsRef : Ref (Map Int Unit),
  rigidAuthvarsRef : Ref (Map Int Unit),
  -- Effect provenance: for each (binding, label key), the first site in that
  -- binding that performed the label, so a failure about the label's
  -- authority or its presence points at the call rather than at the body or
  -- its last arm.  Keyed `fn\tlabelKey`; first site wins.
  effectSitesRef : Ref (OrdMap (List (Authority, Option Loc))),
  -- Binding names for which the scoped solver already reported a row
  -- failure, so the retained post-hoc escape walk does not report the same
  -- leak a second time.
  rowFailureReportedRef : Ref (OrdMap Unit),
  -- Every recorded (code, location, message) triple: the same diagnostic at
  -- the same span is one diagnostic, however many checks derive it.
  typeErrorKeySetRef : Ref (OrdMap Unit),
  -- Existential cells reported as escaping their scope: an obligation over
  -- one is a consequence of the escape, not a second defect.
  escapedExistentialsRef : Ref (Map Int Unit),
  -- Every cell a pattern opened for an existential binder: a report naming
  -- one says what it is (the authority of the value the arm opened), not
  -- what a signature binder is (an authority the caller chooses).
  openedAuthvarsRef : Ref (Map Int Unit),
  -- Index variables an index equality substituted a determined term for
  -- (`unifyIndex`): a report reads such a variable as the written bound it
  -- stands for, not as a bound the scope solved.
  indexSubstitutedRef : Ref (Map Int Unit),
  -- Authority variables an argument extended on the right (`base ++ suffix`),
  -- and those an interpolation hid behind a `display` that is not the
  -- prelude's (`noteArgumentShape`): what a report of a failed bound over
  -- one says the fix is, which the two terms alone do not show.
  extendedBindersRef : Ref (Map Int Unit),
  displayHiddenBindersRef : Ref (Map Int Unit),
  -- The existential cells the pattern site currently being inferred opened,
  -- parked per pattern site exactly as `patLitPending` is (`takePatLits`).
  openedExistentialsRef : Ref (List (Ref Authvar)),
  openedExistentialsStackRef : Ref (List (List (Ref Authvar))),
  recordByNameRef : Ref (OrdMap RecordInfo),
  fieldOwnersRef : Ref (OrdMap (List String)),
  dataParamKindsRef : Ref (List (TabKey, List Kind)),
  dataParamNameIndexRef : Ref (OrdMap Unit),  -- #2158: `tabKeyName`-only index over dataParamKindsRef's keys, kept in lockstep at every write site (freshModuleCtx / declEnvSeedDataUniverse / recordParamKinds) so `noImplHintFor`'s bare-name membership test is O(1)-ish instead of an O(n) `tabHasName` scan. Same bare-name semantics as `tabHasName` — collapses TkIdent/TkBare and module identity by design (#1111 A-2.3), not a stricter key.
  dataParamPolarityRef : Ref (List (TabKey, List Polarity)),  -- #1119 D-2: `dataParamKindsRef`'s VARIANCE twin — same key, same prepend/first-match discipline.  Read ONLY through `paramPolaritiesOf` (which seeds the two write channels).
  dataParamRowAtomsRef : Ref (List (TabKey, List (List Atom))),  -- #2110: the ATOM-GUARANTEE twin of the two above — per KRow parameter, the atoms this declaration charges at EVERY occurrence of that parameter.  Read ONLY through `paramRowAtomsOf`.
  aliasTableRef : Ref (List (TabKey, (List String, Ty))),
  numLitFromIntAnchorRef : Ref (Option MethodSchemeRow),  -- Identity-selected PRELUDE `Num.fromInt` descriptor.  Scheme, predicate identity/vector source, and method slots come from this one row.
  definerShadowNamesRef : Ref (OrdMap Unit),
  definerShadowSigsRef : Ref (OrdMap Ty),
  bodyImplEnvRef : Ref ImplEnv,
  methodAliasEntriesRef : Ref (OrdMap MethodEntry),  -- #1386: the alias method spellings (`A.mth`, a member alias's local) this module's imports supply, each to its declaration's entry — see `aliasQualifiedMethodEntries`
  methodScopeCtxRef : Ref (Option (List Decl, Int)),  -- #2563: this module's decls and ordinal, the inputs `methodScopeHere` reads at
  methodScopeMemoRef : Ref (OrdMap MethodScope),  -- #2563: `methodScopeAt`'s answers for the spellings this module has read
  aliasMethodOriginsRef : Ref (OrdMap String),  -- #1386: the alias-qualified method spellings this module's imports bring into scope (`import m as A` ⇒ `A.mth`, `import m.{mth as loc}` ⇒ `loc`), each mapped to the ORIGIN method name.  A projection of the same candidate rows that supply `methodAliasEntriesRef`, UNFILTERED (the supply drops ambiguous and unresolvable keys; see `aliasMethodSpellings`), so this table is a superset of the supply's key set; read through `originMethodName`.
  implObls : Windowed UObligation,  -- #841: pendingImplObligations/N, ported onto Windowed; #991: onto UObligation
  poisonedVars : Ref (List Int),
  deferrableVarIds : Ref (Map Int Unit),  -- #838 I2: QUANTIFIED (forwarded) var ids of every generalized scheme — `undeterminedGoalExempt` defers a goal on these into the scheme
  liveMemberMonosRef : Ref (List Mono),  -- the types of the module's closed top-level members that generalization left a variable open in: a later group can still ground it (DICT-SEMANTICS §6.2 T2), so no boundary judges a goal on it (`liveMemberIds`)
  quiescentGoalsRef : Ref (List (OrdMap Unit, GoalWindow, UObligation)),  -- the goals on such a variable, newest first, each with its boundary's rigid variables and window (`judgeQuiescentGoals`)
  heldLiveGoalsRef : Ref (List (OrdMap Unit, GoalWindow, UObligation)),  -- the goals a boundary held without a verdict because it owns none of their variables and one is such a variable, newest first, with the same boundary data (`recordLiveRoots`)
  determinedRowsRef : Ref (Map Int (List (ImplRow, List Mono))),  -- the instance each determination commit chose, with the committed goal's arguments, filed under the variable heading the goal (`fileDeterminedRow`)
  declaredSigVarIds : Ref (OrdMap Unit),  -- every variable a closed binder declares, which `matchEqPairs` and determination hold rigid: a top-level signature's and a generalized local's quantified variables (an annotated local's included); `declareRigidVars` adds them. A method signature's and an expression annotation's variables are held only at their own close (`checkSigVarGoals`)
  tupleCallCandidates : Ref (List (Mono, String, Option (Loc, String))),
  numlitVarLocs : Ref (List (Mono, Loc)),  -- keeps every literal: `numlitReframeLoc` and `tagLitLocsWithRoot` need the complete list, and only the `numlitUntainted` worklist drops tainted ones
  patLitPending : Ref (List (Mono, Int, Option Loc)),  -- integer literal PATTERNS inferred since the enclosing pattern site began, awaiting `settlePatLits`
  patLitDeferred : Ref (List (Mono, Int, Option Loc)),  -- integer literal patterns whose scrutinee type was still unknown at their site (`settlePatLitsGo`)
  matchChecksDeferred : Ref (List (Mono, List Arm, Option Loc)),  -- matches whose scrutinee type was unknown after their arms (`checkDeferredMatches`)
  numlitRanges : Ref (List (Mono, Int, Option Loc)),  -- every source integer literal's (var, value, loc), for the fixed-width range check (`checkFixedWidthLiterals`)
  wideLitRanges : Ref (List (Mono, String, Int, Int, Bool, Option Loc)),  -- every wide literal's (var, lexeme, halves, negated, loc), for `checkWideLiterals`
  numlitUntainted : Ref (List (Mono, Loc)),
  numlitOpLocs : Ref (List Loc),
  numlitCtxTags : Ref (List (Loc, JoinContext)),
  localBindRefs : Ref (List (String, Option Loc, Mono)),
  localSchemesOut : Ref (List (String, Option Loc, Scheme)),
  seedSchemesOut : Ref (List (String, Scheme)),
  funPredicateSlotsRef : Ref (List (String, List PredicateSlot)),
  funPredicateSlotsIdxRef : Ref (OrdMap (List PredicateSlot)),  -- first-wins index over funPredicateSlotsRef; written only through setFunPredicateSlots (or omInsert alongside the cons at setFunConstraintEntry)
  funConstraintDeclaredRef : Ref (List (String, CDeclaredPrefix)),
  currentImportDefinersRef : Ref (OrdMap String),
  currentImportOriginsRef : Ref (OrdMap String),
  importedSchemeOblsRef : Ref (OrdMap (List VecObl)),  -- #1114/#845: this module's imported bindings' scheme contexts, keyed by LOCAL spelling (see importedSchemeOblEntries)
  obls : Windowed UObligation,  -- #838 I1: the call channel (pendingCallObligations/N), ported onto Windowed
  absorptions : Windowed AbsorptionEvent,  -- #839 2a: row-unifier atom-discard trail (write-only in 2a); windowed per body by the existing obls brackets
  -- #837: keyed by (binding-name, binding-id) — the id from resolve's
  -- stampBindingIds, so a where-helper `g`'s obligations can no longer leak onto
  -- an unrelated top-level `g` (retires the three snapshot/restore windows).
  schemeObligationsRef : Ref (List ((String, Int), List VecObl)),
  -- #837: each TOP-LEVEL value binder → its stampBindingIds id, set once per
  -- module (checkBodyImpl) right after stamping.  registerSchemeObligations reads
  -- it to tag a top-level member's obligations with its binding id.
  schemeDefIdsRef : Ref (OrdMap Int),
  methodPredicateSlotsRef : Ref (List (String, List MethodPredicateSlot)),
  currentFn : Ref String,
  currentImplBody : Ref Bool,
  methodSiteFns : Ref (OrdMap (List Mono)),
  dictAppFns : Ref (OrdMap (List (List Mono))),
  residualUnivRef : Ref ImplUniverse,
  promotedRef : Ref (List String),
  fieldOwnerModulesRef : Ref (OrdMap (List String)),  -- #1597: field-owner KEY → declaring module ids, graph-global — see fieldOwnerReachable
  fieldOwnerReachRef : Ref (OrdMap Unit),  -- #1597: the module ids THIS module can reach through DUse — see declEnvSeedDataUniverse
  typeErrors : Windowed TcDiag,  -- issue 1146: the diagnostic OUTPUT channel, on the Windowed discipline
  typeErrorMsgSetRef : Ref (OrdMap Unit),  -- #2068: membership INDEX over typeErrors' rendered messages and message-at-site keys — see recordTypeError
  ambiguitySitesRef : Ref (OrdMap Bool),  -- the spans holding a `T-AMBIGUOUS-INSTANCE`, each with whether its message names the goal (`pushAmbiguityAt`)
  ambiguityVarsRef : Ref (Map Int Unit),  -- the boundary-owned variables a boundary has reported a `T-AMBIGUOUS-INSTANCE` on (`pushBoundaryAmbiguity`)
  errorsDetected : Ref Int,  -- issue 1146: the CONTROL signal split out of it — see recordTypeError / erredDuring
  occursCheckFailed : Ref Bool,
  currentLevel : Ref Int,
  markingRef : Ref (Option ModuleMarking),
  superDeclsRef : Ref (List Decl),
  standaloneValuesRef : Ref (OrdMap Unit),
  methodDispatchIdxByIdRef : Ref (List ((IfaceRef, String), Int)),
  matchOracle : Ref Oracle,
  matchWarnings : Ref (List TcDiag),
  sigNameSetRef : Ref (OrdMap Unit),
  sigTyMapRef : Ref (OrdMap Ty),
  -- #2544 (M4): the module whose body `checkBodyImpl` is inferring (`""` for the
  -- prelude).  Read by `recordTypeError` to tag each residual diagnostic with its
  -- module, since a `Loc` carries no file on the elaborate path and the graph's
  -- residual would otherwise be unattributable.
  currentModuleRef : Ref String,
  -- The module's constructors and variance table, read by `driveOutputsNow` into
  -- `DriveOutputs` — see `InvocationView`.
  invocationViewRef : Ref InvocationView,
  -- The module's own rows of the constructor and record populations, as
  -- `appendDataUniverse` registered them: what a recorded interface replays.
  ownPopsRef : Ref (SpellingPop Scheme, SpellingPop RecordInfo),
}

-- DICT-SEMANTICS §3 W2: the one termination measure every `requires` walk shares.  A
-- walk is the path from its seed to the goal being resolved, innermost first, each goal
-- with its `monoSizes`, and the non-shrinking steps it may still take.  A step to a goal
-- strictly smaller than its parent is free; any other step spends one unit; a goal
-- equal to one already on the path is a cycle.  Between two spending steps the size
-- strictly decreases, and the spending steps are bounded, so every walk is finite.  The
-- path is a value passed down one walk, never shared between walks.  The walk's
-- `WalkMemo` is the one part every branch of the walk shares.
public export data ReqWalk =
  ReqWalk (List (IfaceRef, List Mono, Int)) Int WalkMemo

-- The goals one walk has already followed, so a goal its `requires` reach along
-- many paths (`Tag (Wrap a) requires Tag a, Tag2 a` and its twin) is followed once
-- per walk rather than once per path (#1924).  It is allocated where a walk starts
-- (`reqWalkStart`, `reqWalkSeed`) and lives only as long as that walk.
--
-- An entry is keyed on the whole goal (`sameIfaceDecl` and `monoVecSameGiven`, in a
-- bucket named by `enteredGoalKey`) and on the fuel left after entering it.  What a walk does below
-- a goal depends on that goal, that fuel and its path, and the path only decides
-- cycles.  A cached subtree cannot hide one: a goal X on a later path that the
-- subtree below G reaches also reaches G, so the first walk below G, with G on its
-- path, met G again and did not finish clean.  Only a subtree that raised no error
-- (`erredDuring`) and, on the route walk, met no cut (`wmCuts`) is recorded.
--
-- A solving walk (`residualPredsOf`, `implGoalResiduals`, `superContextLeaves`)
-- records the residuals below a goal (`wmSolved`).  Each such walk is run by one
-- function whose other arguments are fixed for the walk, so the goal and the fuel are
-- the whole key.  It also records only a subtree whose residuals hold no type or effect
-- variable minted while solving it (`solvedCleanly`), so a hit returns exactly what
-- solving again would.  The
-- prerequisite walk (`nestedRequireGoals`) records the goals it has followed
-- (`wmFollowed`) and whether any step met a cycle or ran out of fuel (`wmStopped`).
public export data WalkMemo = WalkMemo {
  wmRoutes : Ref (OrdMap (List RouteWalkEntry)),
  wmDischarged : Ref (OrdMap (List (IfaceRef, List Mono))),
  wmCuts : Ref Int,
  wmSolved : Ref (OrdMap (List SolvedGoalEntry)),
  wmFollowed : Ref (OrdMap (List (IfaceRef, List Mono))),
  wmStopped : Ref Bool,
}

-- The residuals a solving walk left below one goal, deduplicated (`dedupWalkGoals`).
public export data SolvedGoalEntry = SolvedGoalEntry {
  sgeIface : IfaceRef,
  sgeGoals : List Mono,
  sgeResiduals : List (IfaceRef, List Mono),
}

-- The prerequisite routes the route walk built below one goal, with everything they
-- were built from.
public export data RouteWalkEntry = RouteWalkEntry {
  rweIface : IfaceRef,
  rweGoals : List Mono,
  rweRow : ImplRow,
  rweEncl : String,
  rweScope : ScopeId,
  rweRoutes : List Route,
  -- what building [rweRoutes] noted below a destination's top level, replayed on a hit
  rweInner : Inner,
}

-- What entering a goal gives a walk.  A cycle carries the goal whose `requires` posed
-- the repeat and the repeated goal; running out of fuel carries the goal reached.
public export data ReqStep =
  | ReqOn ReqWalk
  | ReqCycle IfaceRef (List Mono) IfaceRef (List Mono)
  | ReqDeep IfaceRef (List Mono)

-- ── the invocation summary's view (#3463) ─────────────────────────────────
-- What `types/effect_invocation.mdk` reads of a checked program, as the last
-- module `checkBodyImpl` checked saw it (the entry of a single drive):
-- every constructor it can name, from its own environment and from the
-- identity-keyed universe (so two same-spelled constructors both count), and
-- its variance and kind tables, its own declarations over everything it
-- imports.  Written once per module, right after its data environment is
-- built; a drive's caller reads it through `DriveOutputs` (`lastInvocationOps`).
public export data PublishedInvocationView =
  PublishedInvocationView (List PubScheme) (List (TabKey, List Polarity)) (List (TabKey, List Kind))

public export data InvocationView =
  InvocationView (List Scheme) (List (TabKey, List Polarity)) (List (TabKey, List Kind))

-- The variables one signature binds: its row tails (and row-kinded type
-- arguments) and its authority binders, each name to one fresh cell shared by
-- every occurrence in that signature.  A binder is an authority only where
-- its written domain, an effect atom or an index names it; its domain is that
-- label's.
public export data SigVars = SigVars {
  svRows : List (String, Ref Effvar),
  svAuths : List (String, Ref Authvar),
}

-- ── environment ───────────────────────────────────────────────────────────
-- The type environment uses the shared `OrdMap` (support.ordmap): a persistent
-- String-keyed weight-balanced tree.  The env is looked up on EVERY variable
-- occurrence and carries the whole prelude + every imported module's public
-- bindings, so an assoc-list env made inference O(n^2); OrdMap gives O(log n)
-- lookup and structure-sharing inserts (the branching/backtracking inference env
-- stays valid).  Insert OVERWRITES on equal keys, matching the old assoc-list
-- "newest binding shadows older" semantics (prepend + first-match).
-- alphaLets (3rd field, EFFECTS WS-2 / E3 precision): same-function-body
-- `let`-bound (name, rhs) pairs in scope, seeded into α's known-prefix analysis
-- so an outer-body `let dest = "idp.example.com/page"` then `fetch dest` recovers
-- the literal prefix instead of collapsing to ⊤.  Intraprocedural ONLY —
-- accumulated as infer descends ELet/ELetGroup/block lets (PVar / single-clause
-- zero-arg only, mirroring α's own binding rule); read at the fill site via α's
-- initial `lets`.  A literal laundered through a helper stays ⊤ (spec §5
-- non-goal).  Sound: only turns over-rejections into acceptances.
-- #837 incr2 (Axis A): the 4th field is a name→is-local channel — a FAITHFUL
-- lexical-scope carrier for "does this name currently denote a body-local
-- binding?", replacing the reset-at-body-entry `bodyLocalSchemesRef` proxy.  It
-- is immutable and restored on inference return, so an out-of-scope local is
-- simply ABSENT — no stale entries, no lifetime management (the exact wish the
-- old `(name, schemeIds)` key worked around).  Only `extendLocalVar[s]` set it;
-- top-level / interface-method / ctor / SCC seeds use `extendVar[s]` and leave
-- it absent.  Read by `lookupLocalFlag` at the two `recordImplObligation` guards.
public export data StandaloneOrigin = LocalStandalone | ImportedStandalone

public export data ValueScheme = ValueScheme {
  vsScheme : Scheme,
  vsDeclared : Option CDeclared,
}

public export data EnvBinding = EnvBinding {
  ebValue : ValueScheme,
  ebMethodRow : Option MethodSchemeRow,
  ebStandalone : Option (StandaloneOrigin, ValueScheme),
}

public export data TcEnv = TcEnv {
  teVars : OrdMap EnvBinding,
  teCtors : OrdMap Scheme,
  teAlphaLets : List (String, AlphaBinder),
  teIsLocal : OrdMap Bool,
  teDyn : DynCtx,
}

-- The dynamic context of one inference walk: what the construct being checked
-- tells the checks below it.  A nested walk is handed an updated copy, so the
-- caller's copy is untouched when it returns and nothing is restored.  `TcEnv`
-- carries it through inference; the unification core, which takes no env,
-- takes it as its first parameter.
--   dcJoin — the construct whose alternatives a value join is equating, which
--     names the mismatch (an `if` without `else` is a missing branch).
--   dcNonCovariant — inside a non-covariant type argument, where two closed
--     effect rows must be equal and their mismatch takes the variance wording.
--   dcSuppressRLocalRecord, dcSuppressArgStamp — while typing a definer-shadow
--     occurrence that heads an application (`size (Box 3)`): the standalone's
--     declared domain is not the receiver, so `recordRLocalSite` and
--     `recordArgStamp` push nothing and the application records the argument.
--   dcShadowHeadCtx — while typing a shadow occurrence that heads its own
--     application: the value-position standalone pin does not apply.
--   dcDo — inside a do-lowered chain: a monad-shape mismatch is reported as
--     "do requires a monad" at the block's span.  The one Ref in the record is
--     minted by the `EDoOrigin` arm and set by the first such report, so a later
--     mismatch in the same chain is plain; a nested chain mints its own.
--   dcCallee — while unifying one argument or result of an application, the
--     spelling of the application's head when that head is not a body-local
--     binder; a mismatch there can name a selectively imported head as the cause.
--   dcMethodMismatch — while unifying an interface default body against its
--     declared type: a leaf mismatch names the method.
--   dcGroup — inside the inference of a top-level binding group: that group's
--     record.  Absent in a tail body and anywhere outside a group.
--   dcPerformSites — inside an impl method body whose signature charges an
--     effect variable only in a result index: each call there that runs a row
--     with a variable tail, with the call's span, newest first.  The body's
--     effect checks after inference name the call that ran the variable.  The
--     one Ref is minted per such body.
--   dcModule — the record of the module the walk is checking (or of the stamp
--     context the drain entered).
public export data DoCtx = DoCtx {
  doLoc : Loc,
  doDeferred : Bool,
  doReported : Ref Bool,
}

-- The state of one top-level binding group, minted by `processSCC` and carried
-- to the group's inference in `dcGroup`; nothing outside the group can reach it.
--   gcMonos — the group's `=>`-constraint variables as (interface name, the
--     constraint's instantiated mono), read by `definerReceiverIsDictVar` to
--     dispatch a definer-shadow occurrence through the dict.
--   gcPendingEscapes — the retained post-hoc escape walk's findings, held until
--     the group's solver scope has closed, so the scoped report (located at the
--     call) wins and the walk adds only what the solver did not see.
public export data GroupCtx = GroupCtx {
  gcMonos : List (String, Mono),
  gcPendingEscapes : Ref (List (String, Option Loc, String)),
}

public export data DynCtx = DynCtx {
  dcJoin : Option JoinContext,
  dcNonCovariant : Bool,
  dcSuppressRLocalRecord : Bool,
  dcSuppressArgStamp : Bool,
  dcShadowHeadCtx : Bool,
  dcDo : Option DoCtx,
  dcMethodMismatch : Option String,
  dcCallee : Option String,
  dcGroup : Option GroupCtx,
  dcPerformSites : Option (Ref (List (Ref Effvar, Option Loc))),
  dcModule : ModuleCtx,
}

-- The context outside every construct that sets one, in the module [mctx].
export
dynFor : ModuleCtx -> DynCtx
dynFor mctx = DynCtx {
  dcJoin = None,
  dcNonCovariant = False,
  dcSuppressRLocalRecord = False,
  dcSuppressArgStamp = False,
  dcShadowHeadCtx = False,
  dcDo = None,
  dcMethodMismatch = None,
  dcCallee = None,
  dcGroup = None,
  dcPerformSites = None,
  dcModule = mctx,
}

-- The context of one resolver walk: what the dispatch site being resolved tells
-- the routes and diagnostics below it.  A walk that works on a site is handed an
-- updated copy.
--   sxSite — the span of the site, for a diagnostic the route solver raises where
--     it has no span argument.  The walk runs after inference, outside every
--     construct, so its module record holds no span.  Absent (a walk outside a
--     resolver drain, such as an obligation check), the diagnostic falls back to
--     `sxModule`'s `mcLoc`: the enclosing construct's during inference, none after.
--   sxInner — the notes accumulator of the running stamp: each route built below
--     the destination's top level is ORed in.  Absent outside a stamp, where the
--     notes are not wanted.
--   sxModule — the record of the module the walk resolves in (a stamp's record
--     inside the drain).
public export data SiteCtx = SiteCtx {
  sxSite : Option Loc,
  sxInner : Option (Ref Inner),
  sxModule : ModuleCtx,
}

-- The context outside every stamp and every site, in the module [mctx].
export
siteFor : ModuleCtx -> SiteCtx
siteFor mctx = SiteCtx { sxSite = None, sxInner = None, sxModule = mctx }

-- a constrained-function occurrence (`f` where `f : C a => …`): instantiate f's
-- scheme (the call's type), and record the routes ref + the instantiated
-- constraint monos so resolveDictApps can pick a dict route once the call's args
-- pin those monos.  funConstraintsRef[f] gives f's constraint tyvar ids, mapped
-- through the instantiation subst to this call's fresh vars.
-- ── dictionary-abstracted local bindings ─────────────────────────────────────
-- A generalized local whose scheme keeps class predicates takes one dictionary
-- parameter per predicate, exactly as a top-level binding does.  The scope-threaded
-- pre-pass renamed every candidate let binder to a name no other binder carries
-- (`freshLocalAbsName`) and marked each of its occurrences `EDictAt`, so the name
-- IS the binder's identity from there on.
public export data LocalAbs = LocalAbs {
  laScope : ScopeId,
  laSlots : List PredicateSlot,
  laParams : List String,
}

public export data LocalAbsState = LocalAbsState {
  -- binder -> its abstraction (None: generalized without predicates)
  lasBinders : Ref (OrdMap (Option LocalAbs)),
  -- binder -> occurrences inferred before the binder generalized
  lasRecOccs : Ref (OrdMap (List (EvId, ScopeId))),
  -- the module being marked and the next suffix it mints, reset at each module's
  -- `beginModuleMarking`: a name is a function of its module and marking order
  lasNext : Ref (String, Int),
  -- the names the module being marked has minted, newest first, reset with
  -- `lasNext`: the keys of that module's rows here and in `gsLocalIds`
  lasMinted : Ref (List String),
  -- every type variable a generalized local's scheme quantifies: no longer a
  -- monomorphic variable, so no later numeric boundary may ground it (#3516)
  lasQuantified : Ref (OrdMap Unit),
}

-- ── authority grants (EFFECTS-SEMANTICS §8) ──────────────────────────────────
-- A use of a binding whose scheme quantifies authorities receives, for each of
-- them, the authority inference solved at that use, so that the runtime can
-- confine a file path to what the program was granted.  The pipeline is the
-- dictionary one with a different payload: the marker gives every such use an
-- `EDictAt` identity (`mintGrantOnly` when the name takes no dictionary),
-- inference records the use's authority cells under that id (`inferGrantedAt`),
-- and `grantPass` applies the solved authorities as ordinary `List String`
-- terms.  A source binding takes one leading parameter per quantified authority,
-- after its dictionary parameters.  A parameterized file extern and an interface
-- method take them after their value arguments, which is why every use of one
-- is saturated: a method's leading arguments are the ones dispatch reads.
--
-- An enclosing binder whose own parameter a grant forwards: a top-level or local
-- binding, or a method body (its parameter name and the ids it binds).
public export data GrantBinder =
  | TopGrantBinder String String
  | LocalGrantBinder String
  | BodyGrantBinder String (List Int)

-- One recorded use: its callee, the authority cells it instantiated (in grant
-- order), or, for a use inside the callee's own recursive group, the callee's
-- own quantified ids; the value arity after which a file extern or a method
-- takes its grants; the binders enclosing the use, innermost first; and whether
-- the use is a method occurrence that instantiated the standalone binding its
-- name shadows, whose grants lead its arguments as a source binding's do (its
-- value arity is then the occurrence's, which its published arity adds them to).
public export data GrantOcc = GrantOcc {
  goCallee : String,
  goCells : List Authority,
  goRecIds : List Int,
  goTrailing : Option Int,
  goChain : List GrantBinder,
  goStandalone : Bool,
}

-- An interface method whose type quantifies authorities: the value arity its
-- written type spells, and the binder names of its authorities in grant order.
public export data MethodGrant = MethodGrant {
  mgArity : Int,
  mgNames : List String,
}

-- What a use of a name denotes, for its grants: a source binding (grants lead its
-- arguments), a catalog file extern (grants follow its value arguments), or a
-- binding that takes none (any other extern).
public export data GrantCallee = SourceCallee | FileExternCallee | NoGrantCallee

public export data GrantState = GrantState {
  -- keyed by the use's evidence ordinal
  gsOccs : Ref (Map Int GrantOcc),
  -- the uses the marker identified for their grants alone
  gsGrantOnly : Ref (Map Int Unit),
  -- `mid|name` of a top-level binder, and a renamed local binder: the ids its
  -- scheme quantifies, in grant order
  gsTopIds : Ref (OrdMap (List Int)),
  gsLocalIds : Ref (OrdMap (List Int)),
  -- `iface word#method` of an interface method that takes grants
  gsMethods : Ref (OrdMap MethodGrant),
  -- a method body's scope ordinal: its grant binder
  gsBodies : Ref (Map Int GrantBinder),
  -- the scheme and authority substitution of the last value instantiation, of
  -- the last method candidate's, and of the last standalone a method occurrence
  -- selected
  gsLastInst : Ref (Option (Scheme, List (Int, Authority))),
  gsLastMethodInst : Ref (Option (Scheme, List (Int, Authority))),
  gsLastStandalone : Ref (Option (Scheme, List (Int, Authority))),
  -- the authority variables no caller supplies: an existential a pattern opened,
  -- and an instance head's index inside the instance's method bodies
  gsSourceless : Ref (Map Int Unit),
  -- the name, as its declaration spells it, of every top-level binding that
  -- takes grants
  gsTakers : Ref (OrdMap Unit),
  gsFresh : Ref Int,
  gsBounds : Ref (OrdMap (List (EffRow, List GrantBinder))),
  gsValueBounds : Ref (OrdMap (List (Mono, List GrantBinder))),
  gsPassingModule : Ref String,
}

-- The key a top-level binder's grant ids are recorded under.
export
grantTopKey : String -> String -> String
grantTopKey mid n = "\{mid}|\{n}"

-- Record [ids] as the grant ids under [key], or delete its row when [ids] is empty:
-- no binder that takes no grant has a row.
export
setGrantIds : Ref (OrdMap (List Int)) -> (String, List Int) -> Unit
setGrantIds table (key, []) = table := omDelete key table.value
setGrantIds table (key, ids) = table := omInsert key ids table.value

-- The key an interface method's grants are recorded under.
export
methodGrantKey : String -> String -> String
methodGrantKey ifaceWord method = "\{ifaceWord}#\{method}"

-- The binder-name and grant state belong to the lineage (`Lineage`), so a row
-- outlives the drive that wrote it, and each table is kept by what its key is:
--   * an evidence ordinal (`gsOccs`, `gsGrantOnly`) never repeats in a lineage, so
--     the rows stay;
--   * a variable id or scope ordinal the drive mints afresh (`lasQuantified`,
--     `gsSourceless`, `gsBodies`) and a module's file-bound site (`gsBounds`,
--     `gsValueBounds`) are cleared when the lineage starts (`graphLineageRun`); a
--     served module's sourceless ids and bounds come back with its trees;
--   * a name a module owns (`mid|name` in `gsTopIds`, a renamed local `x$mid$k$lb`
--     in `lasBinders`, `lasRecOccs` and `gsLocalIds`, `mid::Iface#method` in
--     `gsMethods`) is minted again by every check of that module id, so each check
--     and each tree serve of the module replaces the row under every such key it
--     decides, deleting the rows it has none for (`setGrantIds`, `forgetLocalRows`
--     in `types/module_interface.mdk`).
-- `gsTakers`, keyed by bare name, only arms a panic; the `gsLast*` cells and
-- `gsPassingModule` are set before each read.

-- How the constructors of one type disagree about a field: a constructor that
-- does not declare it, two that declare it at different (0-based,
-- declaration-order) positions, or two that declare it with different types.
public export data CtorFieldConflict =
  | CtorWithholds String
  | CtorSlotsDiffer String Int String Int
  | CtorTypesDiffer String Mono String Mono

-- ── §8 I7: The built-in classes, and why they are a closed enum ─────────────────
-- `DICT-SEMANTICS.md` §8 I7 (ratified 2026-08-10): *an OPERATOR's class, and a numeric
-- literal's class, are fixed by the language definition.  They are not resolved by
-- name, and no user declaration can capture them.*  The eight synthetic occurrences in
-- `compiler/types/typecheck.mdk` (the five operator handlers, `inferNumLitBare`, and the two `Num` gates)
-- have no AST node and no declaration site to read an origin from, so P1 (#1446) needs
-- a supply route for them that is neither invented nor user-writable.
--
-- the key is this enum, not a name, and that is the whole point.  The obvious route
-- — re-value `registeredIfacesRef` (`OrdMap Unit` → `OrdMap TyConOrigin`) and have the
-- operators read the origin they already gate on — was considered and REJECTED: that
-- table was written by the per-method registrar for every interface, prelude
-- or user, so a user `interface Num` would both satisfy the gate and SUPPLY the origin.
-- That is exactly the capture I7 qualification 4 forbids, reached through the gate.
-- With a four-constructor enum the capture is not merely unlikely, it is
-- UNREPRESENTABLE: there is no way to name a fifth built-in class, and the only
-- population path reads a PRELUDE declaration list (`seedBuiltinClasses`).
--
-- The member set is DERIVED from the synthetic sites, not chosen:
--   grep -n 'recordIfaceObligation B' compiler/types/typecheck.mdk   -- the 5 operators
-- plus `inferNumLitBare`'s direct `Num`.  `Num`/`Eq`/`Ord`/`Semigroup`, and no others —
-- `Display`/`Mappable`/… are ordinary interfaces reached only through a named method
-- occurrence, which is an I4 occurrence resolved by name and needs nothing from here.
public export data BuiltinClass = BNum | BEq | BOrd | BSemigroup

-- The four classes' identities AND their PRESENCE, read off the PRELUDE's own
-- `DInterface` declarations.  (Named `…Origins` until #1539; it carries the presence
-- half too now, so the name would have lied.)
--
-- Origin: plain `TyConOrigin` rather than `Option TyConOrigin` because
-- `OriginUnresolved` is the honest answer in both of the cases an `Option` would
-- distinguish — a prelude-free program (nothing declares the class, and nothing
-- implements it either, so any key answers the same) and a prelude whose declarations
-- this pass sees unstamped (the prelude-FLATTENED internal passes) — and in both the
-- impl side keys `TkBare` too, so writer and reader stay symmetric.  No sentinel, no
-- per-site decision about an empty origin (§8 I6.3).
--
-- presence is a separate field and cannot be derived from the origin (#1539).  The
-- second bullet above is exactly why: on the prelude-FLATTENED arms a PRESENT prelude
-- declares `Num` with `OriginUnresolved`, so `bcNum == OriginUnresolved` does NOT mean
-- "no prelude".  A gate that read the origin as a presence test would answer False with
-- the prelude loaded and switch every operator's obligation OFF — no golden would move,
-- because a check that stops firing moves no output, which `AGENTS.md` grades as a
-- severity INCREASE.  The two questions are independent; keep two fields.
public export data BuiltinClasses = BuiltinClasses {
  bcNum : TyConOrigin,  -- one field per BuiltinClass constructor; keep these two comments (#829)
  bcEq : TyConOrigin,
  bcOrd : TyConOrigin,
  bcSemigroup : TyConOrigin,
  bcNumPresent : Bool,
  bcEqPresent : Bool,
  bcOrdPresent : Bool,
  bcSemigroupPresent : Bool,  -- adding a member means adding a constructor AND two fields here
  bcPreludeSeeded : Bool,
}

-- One admitted declaration's answer at an occurrence, or the whole admitted set's:
-- the instance it selects (with the declaration and the parameter vector it was
-- selected at), no instance, or no answer.  A declaration has no answer when the
-- occurrence's type does not instantiate its own declared type (inference typed the
-- occurrence against one declaration of the set, chosen by scope order, so a
-- mismatch says which declaration came first, not which one is meant), when its
-- receiver has no head (rigid, or still ungrounded at quiescence), or when it has no
-- method row here; the set has none when two or more declarations select or any one
-- has no answer, since the declarations have then not been shown to agree
-- (SHADOW-SEMANTICS S2-DECL (d), (e)).  A set whose one selecting declaration
-- cannot be routed at the occurrence is unroutable (`routableSelection`).
public export data AdmittedAnswer =
  | Selects IfaceRef ImplRow (List Mono)
  | SelectsNothing
  | Undecided
  | Unroutable IfaceRef

-- A selected standalone value contributes its own forcing row and constraints.
-- Preparing a method candidate must not charge this alternate binding.
public export data SelectedValueOccurrence = SelectedValueOccurrence {
  svoScheme : Scheme,
  svoInstance : MethodTrackedInstantiation,
  svoDicts : ShadowDicts,
}

-- The scope an arm or a clause gives the existentials its pattern opened:
-- its body runs one level deeper, and the opened cells are raised to that
-- level, so a cell bound into anything the scope did not create — a clause
-- parameter, an enclosing binding's variable — is lowered by the ordinary
-- level discipline and found at the close.
public export data ExistentialScope = ExistentialScope (List (Ref Authvar)) Int

-- One record instantiation's substitution: its type params and its
-- authorities, applied together to any field on demand.
public export data RecordSubst =
  RecordSubst (List (Int, Mono)) (List (Int, Authority))

-- One explicit description of a numeric-defaulting boundary.  Member and local-group
-- boundaries carry the just-exited HM level used by BOTH defaulting and ambiguity
-- rejection.  An SCC carries that level for ambiguity rejection while retaining its
-- legacy unrestricted SCC defaulting policy; method bodies carry their owned
-- inference level while retaining the body-local surviving-channel rule.
-- These four policies preserve the existing candidate sets while making the
-- outliving channels named data instead of positional arguments:
--   * member: roots in one member, excluding its arguments; a root its type does
--     not mention is handed to the enclosing boundary (`handOffAbsentNumVars`);
--   * group (a where component): roots no member's type mentions;
--   * SCC: the group rule plus the existing per-member fallback;
--   * body-local: roots absent from the boundary's explicit surviving-channel set.
public export data NumBoundaryDisposition =
  | NumBoundaryOwnedMember Int
  | NumBoundaryOwnedGroup Int
  | NumBoundaryOwnedScc Int
  | NumBoundaryOwnedMethodBody Int

public export data NumBoundary = NumBoundary {
  nbDisposition : NumBoundaryDisposition,
  nbMembers : List Mono,
  nbSurvivingIds : OrdMap Unit,
  nbDefaultObls : List UObligation,
  nbAmbiguityObls : List UObligation,
  nbGuard : NumGuard,
}

-- What D3 clause 3 reads at one boundary: the goals it tests, the variables the
-- boundary holds for every instantiation, and, at a member or group, the level
-- below which a goal variable is an enclosing binder's.  Such a variable is held
-- too, seeds D3 clause 2's connection (`tiedSurvivors`), and is left out of this
-- boundary's ambiguity registration.
public export data NumGuard = NumGuard {
  ngGoals : List UObligation,
  ngRigidIds : OrdMap Unit,
  ngOuterBelow : Option Int,
}

-- D3 clause 3 at work over one boundary.  Its goals are taken once, before the
-- first candidate is grounded, so the outcome does not depend on candidate order.
public export data ArmedGuard = ArmedGuard {
  agWindow : GoalWindow,
  agRigidIds : OrdMap Unit,
  agOuterBelow : Option Int,
  agWithheld : Ref (List Mono),
}

-- ── scope-aware arg-position prepass (emit path; D3a shadow guard) ───────────
-- The three name sets carried through the scope-threaded rewrite (rp = return-
-- position methods, dn = constrained-fn dict names, an = arg-position methods).
-- rp = return-position methods, dn = constrained-fn dict names, an = arg-position
-- methods, sm = the P0-18 mangle definer-shadow map (mangledSymbol ↦ bareMethod).
-- #2189: rp/dn/an are OrdMap-backed SETS, not `List String` scanned by
-- `contains` — the same treatment `bound` already gets below, and for the same
-- reason: they grow with the program while the rewrite visits every EVar.
-- `sm` is the one that stays a LIST, and that is measured rather than assumed.  While
-- the definer-shadow map was empty off the emit path an assoc probe cost nothing, and
-- #2809's bare row (`name ↦ name`, one per interface method a unit defines) made it
-- non-empty on every path: `lookupAssoc` +99.1M Ir on
-- `check compiler/driver/medaka_cli.mdk`, the largest single term in that cell's
-- regression.  An `OrdMap` is the wrong repair — the map holds a HANDFUL of rows on the
-- compiler's own graph, so a tree probe (two dispatched three-way `compare`s) costs more
-- than the scan it replaces, and swapping it in read +246M in `OrdMap` work against the
-- -187M it removed.  What the `EVar` arm below does instead is probe ONCE: it used to
-- ask `isSome (lookupAssoc n sm)` in a guard and then `lookupAssoc n sm` again in the
-- body.
-- The fifth field is called once per `EDictAt` the rewrite mints, with the callee
-- name and the minted evidence id; `noDictHook` for every marker except the
-- schedule's group-recursive one, which pushes the application's goal from it.
-- The sixth field answers whether a use of a name that takes no dictionary
-- needs a grant identity (`mintGrantOnly`).
public export data ArgRw =
  ArgRw (OrdMap Unit) (OrdMap Unit) (OrdMap Unit) (List (String, String)) (String -> EvId -> Unit) (String -> Bool)

-- ══ S2-DECL (d): The choice, by cardinality of the admitted set (#2188) ═══════
--
-- `methodIfaceHere` above is a cardinality-1 projection: one `Option` per bare
-- name, from `methodEntryHere`, and `None` when two or more declarations are
-- admitted.  The admitted set is `methodAdmittedHere`, and no reader may pick one
-- member of it by any order: S2-DECL (e), "A resolution rule whose answer moves when
-- two `import` clauses are swapped is non-conformant whatever value it produces".
--
-- This is the decision the projection cannot express, and it is asked ONCE, at the
-- importer-shadow application arms, over the whole admitted set:
--
--   * fewer than two admitted → `AdDefer`.  (d)'s "exactly one" and "none" arms are
--     what `methodIfaceHere` + `ieImplExistsForHead` implement between them.
--   * two or more, and NONE of their own impl queries hits → `AdStandalone`.  (d)'s
--     bullet 2: they agree, and what they agree on is the standalone.
--   * two or more, and at least one hits → `AdReject`.  (d)'s bullet 3.
--   * two or more, and some declaration's query cannot be asked → `AdReject` as well;
--     see the second note below.
--
-- WHY "at least one hit" is the whole of the disagreement test, not a shortcut.
-- (d) bullet 2 admits "two or more that yield the SAME denotation (all the standalone,
-- or all the same impl)".  Two DISTINCT interfaces can never yield the same impl — an
-- `impl IA String` and an `impl IZ String` are different bodies — and the admitted set
-- is a set of distinct declarations (`methodRowsOfIface` upserts by identity).  So for
-- a set of size ≥ 2 the "same impl" half of bullet 2 is uninhabited, and "they agree"
-- reduces to "they all fall to the standalone", i.e. zero hits.  One hit alongside a
-- miss is bullet 3; two hits is two different impls, also bullet 3.
--
-- An unanswerable receiver is an ambiguity, not a deferral.  If any admitted
-- declaration's own receiver argument is missing from the applied prefix
-- (under-application, `g = mth "abc"` for a declaration that dispatches at argument 1),
-- has no recorded dispatch index, or is still ungrounded after
-- `groundAdmittedReceivers`, no rule decides between the declarations at this
-- occurrence, and nothing later does either: the scope holds no single declaration to
-- fall back to, so any type or row chosen here would be one declaration picked by the
-- compiler, and which one would track module order (S2-DECL (e)).  The occurrence is
-- the located reject bullet 3 already produces, in every import order
-- (`docs/spec/SHADOW-SEMANTICS.md` S2-DECL (d) bullet 2).
public export data AdmittedVerdict =
  | AdDefer
  | AdStandalone
  | AdReject (List IfaceRef)

public export data MethodTemplateGivenResult =
  | MethodTemplateGivenNone
  | MethodTemplateGivenOne GivenEntry
  | MethodTemplateGivenMany

-- a user impl, reduced to what coherence needs: iface + head-arg monos (fresh
-- vars).
-- CohImpl iface head-tys ownerModuleId headLoc.  The 3rd field is the id of the
-- module that PHYSICALLY declares this impl ("" for the single-file / entry path, so
-- its goldens stay byte-identical — only the global cross-module check threads a real
-- module id and uses it to name BOTH modules in a conflict).  The 4th is the span of
-- the impl's head type constructor (#414), so a conflict can point AT an impl instead
-- of fabricating a file-start caret; `None` for a synthesized impl with no source
-- span (e.g. desugar's `deriving` lowering, which builds `tyConUnresolved tyName None`).
--
-- #1559 A-3.7: the 1st field is an `IfaceRef` — the interface's SPELLING plus its
-- I4 identity — not a bare `String`.  It was a bare `String` compared with
-- `if1 == if2` until this unit, which is why two UNRELATED modules that each
-- declared their own interface spelled `Same` and each impl'd it at a shared head
-- were reported as conflicting (#1438's coherence reach; the false reject is
-- pinned, pre-fix, at `test/must_fail_fixtures/1438-*`).  See `cohSameIface` for
-- WHICH identity predicate is correct here and why the other one is a severity
-- increase.
public export data CohImpl = CohImpl IfaceRef (List Mono) String (Option Loc)

-- ── shared one-sided matcher core (#156 S1) ────────────────────────────────
-- cohSubsumes (Mono-space), tySubsumes (AST-space) and matchTyMono (AST head-
-- pattern vs Mono) are the SAME one-sided, consistency-enforcing structural match
-- in three node spaces: only the GENERAL side's vars bind, a var bound twice must
-- be CONSISTENT (its two specific bindings structurally equal), and effect rows
-- are ignored for coherence/ranking (§7's single-meaning law).  Impl-goal
-- matching supplies matchEqMono instead, because repeated variables are full
-- typing equations, including rows and authorities.  The frontends differ in (a) how
-- a node is destructured into a var / children / leaf and (b) the specific-side
-- equality used for the consistency check.  [matchOneSided] is that shared core:
-- it walks a worklist of (general, specific) pairs, threads a key→specific subst,
-- and returns it (None on a head-mismatch OR an inconsistent re-bind).  The Bool
-- frontends are `isSome ∘ matchOneSided`; matchTyMono returns the subst itself.
-- Enforcing consistency HERE is what makes matchTyMono a genuine SUBSTITUTION
-- (DICT-SEMANTICS §3 `inst`): the old `xs ++ ys` combine accepted an inconsistent
-- non-linear-head match (e.g. `Get (Box a) a` vs `Get (Box Int) Bool`) and so
-- could false-match and select the wrong impl's requires.  cohOverlap is NOT a
-- frontend of this core — it is two-sided unification (both sides' vars bind), the
-- coherence-overlap check, and stays separate.
--   MVar k   — the general node is a variable keyed [k]; bind/consistency-check it.
--   MKids ps — heads agree; recurse on these (general, specific) child pairs.
--   MOk      — leaf success (matching TCons, or two effect rows).
--   MFail    — head mismatch (no match).
public export data MStep k g s = MVar k | MKids (List (g, s)) | MOk | MFail

-- ── F-3d (#614/#311): the declaration-time sweep is CLASSIFIED, not deleted ──
-- DICT-SEMANTICS §6.1 choice-point 2 commits to condition **(c)** — per-goal unique
-- ⊑-minimum — and licenses at most a WARNING at declaration time on (a)-violations
-- ("An implementation MAY additionally warn at declaration time on (a)-violations as
-- an early diagnostic, but acceptance is per-goal").  So the (a) sweep is demoted.
--
-- BUT `cohAnonConflict`'s old `otherwise` arm WAS NOT (a).  It is STRICTLY
-- STRONGER, and the extra strength is exactly the class C1 requires rejecting — so
-- demoting the whole arm would have widened acceptance past the spec, silently.
-- §11's C1 row states the strength ("`cohAnonConflict` … falls through only on
-- `cohStrictlyMoreSpecific` … so mutually-subsuming heads reach its `otherwise` arm
-- and are rejected — closing, in the implementation, the ladder hole §6.1.2's
-- records"), and §6.1.2 states why it matters: two **α-equal** heads are mutually ⊑,
-- hence **⊑-COMPARABLE**, hence they SATISFY (a) — while §6 C1 rejects them outright
-- ("so are α-equal duplicate heads (mutually ⊑, hence **two** ⊑-minimal elements,
-- not one)").  **(a) ⇏ (c).**  Demoting an (a)-violation is what the spec licenses;
-- demoting a C1 violation is not, and nothing downstream would catch it — F-3c's
-- goal-site reject cannot see this class either, because `entryCovers` is
-- `tyHeadEqV || tyStrictlyMoreSpecificV`, so two equal heads cover each other,
-- `findMostSpecificEntry` returns `Some`, and `reportAmbiguousOverlap` never runs
-- (that function's own says so: "Only ⊑-INCOMPARABLE OVERLAP lands here").
--
-- Hence the two classes, split on mutual subsumption:
--
--   HARD (`CohScan`'s first field, still `T-CONFLICTING-IMPL`) — the two heads are
--     mutually ⊑, i.e. α-equal up to renaming.  A §6 C1 violation at every goal that
--     matches them, and NO third impl can rank the pair.  Unchanged behaviour:
--     `test/typecheck_error_fixtures/{dup_impl,overlapping_impls}.mdk`,
--     `test/check_json_fixtures/conflicting_impl_duplicate.mdk`,
--     `test/dict_fixtures/s6-c1-duplicate-heads-rejected.mdk` and
--     `test/run_check_agreement_fixtures/p0_1_overlapping_impls.mdk` all still reject.
--     Strictly, (c) is per-GOAL, so a duplicate pair no goal ever poses is legal
--     under it; this site is goal-blind and keeps over-rejecting there exactly as it
--     did before F-3d.  That residue is deliberately UNCHANGED — F-3d is a widening
--     and this is the one place it declines to widen, because the widening would be
--     into a class nothing else rejects.
--
--   SOFT (`CohScan`'s second field, the new `W-INCOMPARABLE-IMPLS`) — the two heads
--     are ⊑-INCOMPARABLE.  A condition-(a) violation ALONE.  (c) may well accept the
--     program: the §6.1 separating case adds a third impl that is ⊑ both, and at the
--     goal that third impl is the unique minimum.  Acceptance now belongs to the
--     goal-site `min⊑` reject (F-3c / #1155), which is a HARD error at a closed goal.
--
-- the scan now collects one of each class, not "the first conflict".  Returning a
-- single classified verdict would have made a soft pair found first HIDE a hard pair
-- found later — an error → nothing transition, i.e. the loud-to-silent regression
-- this whole stage is gated on not committing.  `cohScanDone` stops the sweep once
-- both slots are filled, so the clean-program cost (the only cost paid on a compile
-- that succeeds) is byte-for-byte the old full O(pairs) scan.
--
-- #414: each payload is the message PLUS the span to blame — the scan runs over a
-- `reverseL`-ed list, so the outer element `e1` is the LATER-declared impl of the
-- pair, which is also the head the message names FIRST.  Blaming it keeps caret and
-- wording consistent.  The two cross-module pushes deliberately drop the span (see
-- `globalCoherenceConflict`) — a span is only useful to a consumer that files the
-- diagnostic against the span's OWN file, which today only the single-file
-- `checkCoherence` path does.
public export data CohScan =
  CohScan (Option (String, Option Loc)) (Option (String, Option Loc))

-- #1559 A-3.7: Which sweep is running, threaded as a value instead of inferred from
-- the shape of the module ids.  `cohSoftInScope` used to answer "am I the per-module
-- sweep?" by testing `mid1 == "" && mid2 == ""`, which was only ever a PROXY: the
-- per-module input was built by `cohImplsOf`, which stamped `""` because it had no
-- module id to stamp.  The proxy is correct exactly while that holds and silently
-- wrong the moment the per-module sweep is fed rows that carry a real id — which is
-- what pointing it at `IE` does.  See `cohSoftInScope` for the failure it prevents.
public export data CohSweep = CohSweepOwn | CohSweepGlobal

-- ── TYPECHECK-AUDIT C7: canonical-impl-key registry ────────────────────────
-- One entry per USER impl (regardless of `requires`): the methods it defines (to
-- match a method site), its head tycon (to detect a head-tag collision), its
-- head-arg type pattern (matched against the site's concrete result mono), and its
-- canonical impl key.
-- The route normally keeps the bare head tycon (the established head-tag dispatch
-- the native Core-IR/LLVM backend keys symbols by); it is UPGRADED to the full
-- canonical key ONLY when two impls share that head tycon for the method (the C7
-- case, e.g. Pair Int Bool vs Pair Bool Int).  This keeps every single-impl-per-head
-- site — i.e. all existing code and the native backend — byte-identical, while
-- letting eval's narrowMethod pick the right VTypedImpl by its key field when the
-- heads genuinely collide.
-- #203: the last three fields (iface, full impl type-args, requires) were added so
-- this ALL-impls registry (every user impl, requires-bearing or not) can serve as the
-- single most-specific-wins selector for EVERY resolution position (§6 uniform
-- resolution).  ImplBuckets OMITS no-requires impls, so it cannot see the specific
-- `List Int` sibling next to a general `List a`; KeyBuckets carries every impl plus its
-- requires, so `ieSelectRowByIface` / `ieSelectRowByMethod` return the min⊑ winner's OWN
-- requires ([] for a no-requires specific impl — never the general sibling's).
-- #1128 (F-3b): the trailing Int is the entry's DECLARATION INDEX — its position in
-- the flat, forward-ordered entry list this table was built from.  It exists for one
-- reason: a fully-general `impl C a` has NO head tycon, so it buckets under
-- `noneHeadTag` rather than beside its concrete siblings, and every goal-head lookup
-- must now UNION two buckets.  A bare `bucketOf tag ++ bucketOf noneHeadTag` would
-- make "concrete always first" the tie-break `pickMostSpecificEntry` falls back on
-- when no unique min⊑ exists — i.e. an arbitrary internal constant, invisible to the
-- declaration-order permutation differential (which permutes SOURCE order and leaves
-- bucket order untouched, so both permutations agree and the row passes either way).
-- With the index the union is a stable merge on declaration order, which is the
-- tie-break `compiler/types/typecheck.mdk` already documents AND the one that gate can see.
-- A-2.2b (#1111): the second field is the entry's PROJECTED HEAD, not its head
-- tycon NAME.  `keyEntryOf` already computed a `HeadKey` (A-2.2) and threw it
-- away by projecting it to a bare name; keeping it is what lets this registry
-- be keyed by the head's IDENTITY instead of its spelling, so two same-named
-- types declared in two modules no longer share a bucket.
--
-- The projected head field remains a bare-name bucket key.  Live route producers
-- may choose that short word or the impl's canonical key; eval and both emitters
-- accept both aliases.  Re-keying this table by identity is still a separate change.
public export data KeyEntry =
  KeyEntry (List String) (Option HeadKey) Ty String String (List Ty) (List Require) Int

-- Caller-supplied policy for the UNDETERMINED arm of routeOf (the constraint var is
-- pinned by NEITHER an argument nor the result).  KeepNone (the nested element-dict
-- recursion) keeps the existing RNone; CountImpls iface (a TOP-LEVEL
-- constrained-call site) routes by the instances of [iface] the goal can still reach
-- (`routeUndeterminedTop`).  A VARIANT (not a
-- callback) so a nested element-position caller STRUCTURALLY cannot
-- raise T-AMBIGUOUS-INSTANCE — the type forbids it, so a blanket RNone→RKey can never
-- corrupt element-dict routing (the fear the three variants were "kept SEPARATE" for).
-- CommitSuper (a dictionary's super segment, `superRouteAt`) commits the instance the
-- checker's super judgment selects for the goal (`committedSuperRoute`).
-- lint-disable-next-line rule-clone-type
public export data Undetermined = KeepNone | CountImpls IfaceRef | CommitSuper

-- #156 S3b: the SiteKind-parametrized entailment core.  ONE `assum → inst → fallback`
-- ladder that both the genuine return-position method resolver (`resolveSite`, EKReturn)
-- and the nested/top constrained-call router (`routeOfD`, EKNestedTop) route through.
-- Returns `(primary route, element-dict route list)`.  Genuine sites carry their element
-- routes in the SEPARATE `implRef` (primary is `RKey key []`), so `snd` is non-empty and
-- the adapter stamps it into `implRef`; nested/top PACK their `requires` into the primary
-- RKey (byte-identical to the pre-S3b `routeOfD`) and leave `snd` empty.
--   * assum: EKNestedTop uses `activeDictVarForEncl`; EKReturn uses the enclDictVarOf-
--     preferring `activeDictVarOfEncl`.  EKReturn routes RDictFwd when the method is
--     return-position (name∈rpNames), else RDict; EKNestedTop routes RDict.
--   * inst: EKReturn selects one row for its canonical key and element routes;
--     EKNestedTop stamps the
--     canonical key of the min⊑ winner + `argImplRequiresRoutesForRow`-packed requires (under
--     the shared W2 measure, `reqWalkEnter`).
--   * fallback: EKReturn → RNone; EKNestedTop → the caller-supplied `Undetermined` policy.
-- #156 S3c wired arg-position + operator sites in (EKArg / EKOp below).
public export data EntailKind =
  -- return-position method site: the method's full (un-stripped) mono (for
  -- ifaceParamMonos), and whether the method is return-position.
  | EKReturn Mono Bool
  -- Numeric return sites carry the producer's fixed class predicate.  The method
  -- name remains separate because the route-word collision ABI is method-keyed.
  | EKNumReturn ClassPredicate Mono Bool (Option Loc)
  -- nested-element / top-level constrained call: iface, undetermined policy, and the
  -- `requires` walk that reached this goal (`ReqWalk`, the shared measure; `reqWalkStart`
  -- at a seed site).  See `argImplRequiresRoutesForRow`.
  -- #1154 (F-3a): the predicate's goal args PAST arg 0.  Arg 0 stays in `entail`'s
  -- own [m] (it keys `assum` and supplies the head tag), so this field holds only the
  -- TAIL — storing the whole vector would duplicate arg 0 and let the two copies
  -- drift.  `[]` at every caller with no vector to offer, which reproduces the
  -- pre-#1154 singleton exactly.  Same pattern as EKReturn/EKArg carrying the
  -- `fullMono` only THEY need.
  | EKNestedTop IfaceRef Undetermined ReqWalk (List Mono)
  -- #156 S3c: arg-position stamp (resolveArgStamp).  assum =
  -- activeDictVarOfEncl → RDict (never RDictFwd; arg-position); inst = same canonical
  -- RKey primary as EKReturn but element routes via argImplDictRoutesForEncl keyed on
  -- the (default-reduced) method; fallback = RNone (the load-bearing do-nothing arm).
  -- #609: also carries the method's full occurrence mono, so this kind can recover
  -- the interface's whole param vector (ifaceParamMonos) exactly as EKReturn does.
  -- Without it the arm could only ever see arg 0, and the arg-position leg is the
  -- one an ordinary `ix 1 'x'` call takes.  The list is the site's `SKArg`
  -- omitted-typaram variables (`occurrenceParamMonos`).
  | EKArg Mono (List (String, Mono))
  -- #156 S3c: operator site (resolveOpSite).  isBinop and the in-impl-body flag
  -- (for opDictVarOf's dict-var policy).  assum = opDictVarOf → RDict;
  -- inst = stampOpRouteVal (builtin head → RNone, else RKey with reqs PACKED in — no
  -- separate implRef); fallback = RNone.  Both do-nothing arms preserved by the adapter's
  -- RNone guard (op-site refs are always Ref RNone-seeded — parser/desugar).
  | EKOp Bool Bool
  -- Arithmetic operator site with the producer's exact prelude Num predicate.
  -- Selection and assumption lookup use this identity and its complete args;
  -- the method name remains separate for the route-word ABI.
  | EKPredicateOp Bool Bool ClassPredicate

-- How a method occurrence takes grants: after the method's value arguments, ahead
-- of the arguments of the standalone binding it was routed to, or not at all.
public export data MethodGrantUse =
  | MethodGrants Int (List Expr)
  | LeadingGrants Int (List Expr)
  | NoGrants

-- ── Error-path B4: missing-impl dispatch-obligation check ──────────────────
-- The `No impl of … for …` reject.  For each recorded interface-method occurrence, recover the types the
-- interface params resolved to at this site (dispatchMonosOf), and — ONLY when
-- they are all CONCRETE (a resolved head tycon, no remaining polymorphic var, so
-- a constrained-generic `Ord a =>` site whose receiver is still `a` is correctly
-- deferred to the caller) — verify the program declares a matching impl.  None →
-- `No impl of <iface> for <args>`.  An impl block (even one defaulting every
-- method to its interface default body) creates a head entry, so a default-method
-- call on a type WITH an impl is satisfied; a default-method call on a type with
-- NO impl is rejected — both matching the oracle.
-- #154 PR3: the KEYED impl universe consumed by the obligation checkers below.  Bundles
-- the two buckets `insertUnivImplAt` writes (#1112 A-3.4 PR2 deleted the three
-- `CrossRun` refs this line used to name): concrete-head impls keyed "iface|tag" and
-- HEADLESS-receiver impls keyed by iface (matched against ANY receiver). Standalone
-- builds one from its whole `prog` via `buildImplUniverse` (O(N) once — the same cost
-- as the old `implDeclsWithReqs`+`implHeadsOf` it replaces); the Module path passes the
-- #1112 A-3.4 PR2: No longer a persistent accumulator.  This block's header used
-- to read "PERSISTENT accumulator (grown one module at a time in
-- appendUniverseAccums)"; those three `CrossRun` refs are deleted.  The Module path
-- now PROJECTS this value out of stage K's `IE` at the reading module's ordinal
-- (`ieUniverseAt`, selecting from the per-ordinal `ieUnivSnaps` built once by
-- `ieBuildSnapsGo`); internal standalone-list checks use `buildImplUniverse`.
-- Everything below about the KEYS is unchanged — the same `insertUnivImplAt` writer
-- mints them on both paths, which is what made that flip equality-preserving.
-- A-2.2b (#1111): both buckets are IDENTITY-KEYED registries.  What each
-- key carries, and what it deliberately does NOT:
--   * the INTERFACE half is an IDENTITY key on both the writer and every reader
--     (#1446 T2) — `tabKeyOf NsIface` over the occurrence's `TyConOrigin`, see
--     `oblIfaceKey`.  An impl that HAS an identity is additionally indexed under its
--     bare spelling, for goals that cannot supply one: see `insertUnivImplKeys`.
--   * the RECEIVER-HEAD half is the `TabKey` inside the `HeadKey` that
--     `headTyconTy` projected, so it carries the head's declaring module
--     wherever the pipeline has one (module path) and lands in `TkBare`
--     wherever it does not (flat path, until #1115/E-1).
-- `MultiRegistry` rather than `Registry (List …)`: these buckets are explicitly
-- COMMUTATIVE — every impl ever added is kept, none can be lost to arrival
-- order — which is the invariant the ratchet asks a cross-module table to
-- declare.  They use `mregAppendK`, not `mregAddK`, because within one bucket
-- the FORWARD declaration order is semantic (`findMatchingImplReqsU`).
public export data ImplUniverse =
  ImplUniverse (MultiRegistry (List Ty, List Require)) (MultiRegistry (List Ty, List Require))

-- What an undetermined goal's counted candidates decide (DICT-SEMANTICS §3, §4.2
-- OD3).  None leaves the goal no instance.  One is the instance.  So is one that
-- matches the goal as it stands and is ⊑ every other candidate: min⊑ selects it,
-- and no binding of the goal's variables can make another instance more specific.
-- Anything else is ambiguous.
public export data GoalReach = ReachNone | ReachOne ImplRow | ReachMany

-- A goal a boundary held for a live root (`undeterminedVectorVerdict`), kept for the
-- drain: its module, the binding its verdict is reported for, its boundary's rigid
-- variables less the live ones, and its boundary's window.
public export data LiveGoal = LiveGoal {
  lgModule : String,
  lgBinding : Int,
  lgRigidIds : OrdMap Unit,
  lgWindow : GoalWindow,
  lgGoal : UObligation,
}

-- A boundary's goals by position in the window, and the positions of the goals on
-- each free variable, so a commit is tested against the siblings that share a
-- variable it binds rather than against the whole window.  An entry may be stale
-- after a commit re-files a goal; a stale entry costs one test and nothing else.
public export data GoalWindow = GoalWindow {
  gwGoals : List (Int, UObligation),
  gwByIndex : Map Int UObligation,
  gwByVar : Ref (Map Int (List Int)),
}

-- Who wrote the variables a `checkSigVarGoals` run holds rigid: the signature of a
-- member or method (each entry's name is the member's), or an expression
-- annotation (its entry's type is the written annotation).
-- lint-disable-next-line rule-clone-type
public export data DeclaringBinder = DeclaredBySignature | DeclaredByAnnotation

-- A super goal a goal's construction builds, entered on the walk that reached the goal.
public export data SuperGoalEntry = SuperGoalEntry {
  sgWalk : ReqWalk,
  sgIface : IfaceRef,
  sgArgs : List Mono,
}

public export data ScopedImplMethod = ScopedImplMethod {
  simMethod : ImplMethod,
  simScope : ScopeId,
}

-- Which kind of method body `inferMethodBody` is checking.  An impl body answers
-- for one instance head, in the scope `scopeImplMethods` minted for it beside its
-- siblings.  A default body is inferred once, for every instance that inherits
-- it, in a scope of its own where the receiver is a given.  The kind is not an
-- optional site: each differing step names the case it serves.
-- lint-disable-next-line rule-clone-type
public export data MethodBodyKind = ImplBody ImplBodySite | DefaultBody

public export data ImplBodySite = ImplBodySite {
  ibImplTvMap : List (String, Mono),
  ibHeadMonos : List Mono,
  ibRequires : List Require,
  ibScope : ScopeId,
}

-- The declared method type instantiated for one body.
--   * [mbiSurvivors]: the caller-owned type variables W3 requires to survive the
--     body: the non-head variables of an impl body, every signature variable of a
--     default body (the default must be parametric in the receiver too).
--   * [mbiNamedVars]: each signature variable name's mono (an impl body maps its
--     interface params to the head monos), which the method-level dictionary givens
--     are published over and the head-prerequisite verdict is read against.
--   * [mbiCheckedForce]: read where the body's own forcing row is checked.  An impl
--     body elaborates its written leading row again at that point, so a row naming
--     several tail variables gets a join cell of its own there.
--   * [mbiDictSlots]/[mbiTypeSubst]: a default body's method-level constraint slot
--     ids and the substitution that instantiated them; empty on an impl body, whose
--     slots are registered by name.
public export data MethodBodyInstance = MethodBodyInstance {
  mbiExpected : Mono,
  mbiContractForce : EffRow,
  mbiCheckedForce : Unit -> EffRow,
  mbiEffVars : List (String, Ref Effvar),
  mbiSurvivors : List (String, Mono),
  mbiNamedVars : List (String, Mono),
  mbiDictSlots : List Int,
  mbiTypeSubst : List (Int, Mono),
}

-- What checking a body against its declared type reports to the steps after it.
-- [mbcPerformedAt] is the span of the call that ran an effect variable, in a body
-- that collects them (`dcPerformSites`).
public export data MethodBodyCheck = MethodBodyCheck {
  mbcLaunderFlagged : Bool,
  mbcEagerIndexed : List String,
  mbcPerformedAt : Option Loc,
}

-- W3-inst (DICT-SEMANTICS §3): an impl head's type variables are the instance's
-- quantifiers, and its bodies are checked against them as a signature's body is
-- against its own.  Each head variable's union-find root while it is still a
-- variable; a variable already fixed to a constructed type is absent.  A head
-- variable in an `Effect`-kinded slot is related to a row by the first body
-- that builds or matches the type, and it is still a variable while that row
-- has no atoms and an unbound tail.  The two sorts count their ids separately,
-- so a root carries its sort.
-- lint-disable-next-line rule-clone-type
public export data HeadVarRoot = TypeVarRoot Int | RowVarRoot Int deriving (Eq)

public export data ScopedMember = ScopedMember {
  smName : String,
  smMono : Mono,
  smOwned : BindingSummary,
  smDeclaredRoots : Ref (Map Int Unit),
  smDeclaredAuths : Ref (Map Int Unit),
  smSigned : Ref Bool,
  smRecursive : Ref (Option EnvBinding),
  smForce : Option EffRow,
  smForceBound : Ref (Option EffRow),
  smScope : ScopeId,
}

public export data ConstraintReg = ConstraintReg {
  crName : String,
  crScope : ScopeId,
  crIfaceMonos : List (IfaceRef, List Mono),
  crArgVecs : List (List Mono),
}

public export data ScopedScheme = ScopedScheme {
  ssName : String,
  ssScheme : Scheme,
  ssScope : ScopeId,
}

-- What a binding's scheme does with the authorities of its type.
public export data BindingRole =
  -- an unsigned binding that generalizes: it quantifies them
  | RoleQuantifies
  -- one the value restriction keeps monomorphic: they are the enclosing
  -- scope's, which bounds them at its uses
  | RoleMonomorphic
  -- a signed binding: it publishes its signature, whose universals are rigid
  -- in its own scope and never leave it
  | RoleDeclared

-- Import selection precedes the ordinary environment's last-write overlay.
-- A name can export both a method and a standalone. Preserve both schemes and
-- their shared cells; neither spelling nor type shape identifies the supplier.
public export data ModuleBindings = ModuleBindings {
  mbSchemes : List (String, Scheme),
  -- Only standalone definitions owned by this module, before method overlays.
  mbStandaloneSchemes : OrdMap Scheme,
}

-- [xbExtern]: the binding is a foreign declaration, which takes no grant ahead of
-- its arguments however its scheme reads.
public export data ExportBinding = ExportBinding {
  xbScheme : Scheme,
  xbStandalone : Option Scheme,
  xbExtern : Bool,
}

public export data ModuleSeed = ModuleSeed {
  msSchemes : List (String, Scheme),
  msImportedValues : OrdMap Scheme,
  -- every value name an import of the module supplies
  msImportedNames : OrdMap Unit,
  -- the imported names that denote an extern
  msImportedExterns : OrdMap Unit,
}

-- Shared preamble of the ONE graph driver (`driveGraphK`), and of the schemes-only
-- `checkModulesK` beside it: reset the cross-module accumulators, derive the graph
-- identity indexes and the declaration envelope, register abstract record types,
-- compute the mark sets, and run the core pass.  `graphPreamble` below is the
-- function; `checkModulesPreambleK` is its two-component projection.
--
-- #1110: the caller acquires type-constructor identity FIRST
-- (`stampGraphTyOrigins`, the resolve→typecheck channel) and hands this preamble
-- the ALREADY-STAMPED prelude and modules.  It is not done here, where one line
-- would serve both callers, for a specific reason: `checkModulesPreambleK`'s
-- inferred type is pinned by the selfproc LEG A golden, and widening its result to
-- carry the stamped decls back out is the one change that would make that golden's
-- move non-additive.
-- ── the core pass's cache key ────────────────────────────────────────────────
-- The prelude (runtime + core) is typechecked at the head of EVERY driver entry
-- (`checkModulesPreambleK` below): `medaka check`, the LSP on each didChange, and
-- the playground on each keystroke all pay it again for the same two decl lists.
-- So the diagnostics arm caches the core pass's result as a value
-- (`PreludeInterface`, types/prelude_interface.mdk) keyed by the prelude trees'
-- identity plus the section chosen by the drive's IO join; the identity a caller
-- hands down EXPLICITLY as the desugar cache's generation
-- pair (`desugaredPreludeKey`, frontend/desugar_cache.mdk; the K-suffixed entry
-- points below).  An unkeyed call (`None`) never hits and never stores: the AST
-- carries mutable Refs and no equality, so identity cannot be recovered from the
-- decls themselves, and a caller that hands in a MODIFIED prelude
-- (`autoPrintPinCore`) must not be able to hit by accident.

-- ── prelude-preamble memo ────────────────────────────────────────────────────
-- The whole-graph derivations below run on every analyze, and on an LSP keystroke
-- almost everything they walk is the PRELUDE: the entry module's source changed,
-- its imports' did not, and core's cannot change under a process.  So the
-- prelude's own contribution to each is derived once and RESUMED -- the envelope
-- fold from its accumulator (`DeclEnvAcc`), the three graph identity indexes from
-- core's rows, the mark sets from core's decl-level facts.  MEASURED on the
-- `import list` warm analyze of ruling 7's LSP proxy: `checkModulesPreambleK` was
-- 49.6M of 97.2M Ir, of which `buildDeclEnvs` 33.2M and `markSetsOf` 11.3M.
--
-- The key is the SAME `desugaredPreludeKey` generation pair `checkCoreMemoized`
-- uses, and for the same reason: the AST carries mutable Refs and no equality, so
-- identity cannot be recovered from the decls, and a caller handing in a MODIFIED
-- prelude (`autoPrintPinCore`) passes `None` and must not be able to hit.  An
-- unkeyed call neither hits nor stores, so a one-shot `run`/`build` pays exactly
-- what it paid before -- no key is hashed and no source is concatenated.
--
-- what a hit may carry: every field must be a pure function of `coreDecls`.  Not
-- "holds no `Ref`" -- that is weaker, and the weaker reading is what let an
-- effect-domain READ into an earlier draft of this record.  Two consequences:
--   * no `Decl` and no `Ref`.  The tree is re-stamped into FRESH decls on every
--     analyze (`stampGraphTyOrigins`), so a shared decl would hand this analyze a
--     live cell minted into an older tree.  A `Scheme` is excluded for the same
--     reason read the other way -- it carries live union-find cells -- so
--     `externSchemes` is still derived per analyze.
--   * no read of process-global state either, however immutable the RESULT looks:
--     a cached value derived through such a read is a function of WHEN it was
--     first taken, and a hit pins that reading for the process.  `DeclEnvAcc`'s
--     own note carries the worked instance (the atom seed, and why it is derived
--     per call instead).
--
-- Two things a hit does not do, neither of them load-bearing: it retains
-- `pmfConstrainedNames` (every `=>`-constrained prelude name) for the process
-- lifetime, where the parent recomputed it transiently;
-- and it does not re-walk the prelude, so `opBump` (`support/opcount.mdk`, default
-- off, profiler-only) counts the prelude's steps once per process rather than once
-- per analyze.
public export data PreludePreamble = PreludePreamble {
  ppEnvAcc : DeclEnvAcc,
  ppMangledFunDefs : Bool,
  ppMarkFacts : PreludeMarkFacts,
}

-- `preludeKey`: the desugar-cache generation pair identifying `runtimeDecls` /
-- `coreDecls` (see the core pass's cache key above); `None` = unkeyed, no cache.
-- What a graph drive is asked to PRODUCE.  It is one driver either way
-- (`driveGraphK`): the same preamble, the same per-module worker, the same
-- graph-end drain.  The selection names the three points where the two output
-- contracts genuinely part company — the promotion-eligible seed, the core pass
-- (the tree arm needs core's dict-passed decls back, so it continues from the
-- prelude interface only when the shipped trees are held too), and whether the
-- marked trees are dict-passed and published.
--   * `GOutDiags` — per-module diagnostics and schemes.  What `check`, the LSP,
--     the playground, MCP and `medaka test`'s gate consume.
--   * `GOutTrees` — the same diagnostics PLUS the elaborated, dict-passed trees,
--     the residual and the evidence table.  What `run`, `build`'s child,
--     `medaka test`'s phases and the emit entries consume.
public export data GraphOut = GOutDiags | GOutTrees

-- ── serving modules from their interfaces ─────────────────────────────────────
-- A drive's serve policy (`foldModules`), consulted once for each module before the
-- entry.  It serves the module from a recorded interface (`ServeHit`: the module's
-- own export bindings, its private bindings when the drive's test sibling imports
-- it and none otherwise, its payload, and the policy for the next module), or has it
-- checked (`ServeCheck`: given the module's record after its check, its own export
-- and private bindings and the payloads so far, newest first, it returns those
-- payloads and the policy for the next module).  `msServed` counts the modules served and `msFrozen`
-- the oldest payloads already frozen, which the drive's graph-end freeze skips.  The
-- interfaces themselves are `types/module_interface.mdk`'s.
public export data ModuleServe e = ModuleServe {
  msServed : Int,
  msFrozen : Int,
  msStep : String -> List Decl -> ModuleCtx -> ServeStep e,
}

public export data ServeStep e =
  | ServeHit (List (String, ExportBinding)) (List (String, ExportBinding)) e (ModuleServe e)
  | ServeCheck (ModuleCtx -> List (String, ExportBinding) -> List (String, ExportBinding) -> List (String, e) -> (List (String, e), ModuleServe e))

-- ── THE graph driver ─────────────────────────────────────────────────────────
-- What a whole-graph drive produces, for either output selection.  `gdPerMod`,
-- `gdCoreSchemes` and `gdCoreContexts` are filled on both; `gdCore`, `gdModules`
-- and `gdResidual` are the tree arm's and are empty on `GOutDiags`.  `gdEvTable`
-- is the whole evidence table the tree arm returns (what `ElabResult` carries, and
-- the report's `cpEvidence`), and on `GOutDiags` the goal half only (the drain's
-- per-goal entries).
public export data GraphDrive = GraphDrive {
  gdPerMod : List ModDiags,
  gdCoreSchemes : List (String, PubScheme),
  -- core's own contexts, keyed by bare name, snapshotted after the core pass
  gdCoreContexts : OrdMap (List VecObl),
  gdCore : List Decl,
  gdModules : List (String, List Decl),
  gdResidual : List (String, TcDiag),
  gdEvTable : EvTable,
  -- #1112 A-3: the whole-graph per-method disposition table, filled on both
  -- arms exactly like `gdEvTable` — the whole-graph IE/CE it is built from
  -- (`declEnvsRef`) is complete by the graph preamble above, before either
  -- arm's own work begins.
  gdDispositions : DispositionTable,
  gdBinders : BinderTypeTable,
  -- The drive's frozen outputs as one value (`types/publish.mdk`'s `TcReport`).
  gdReport : TcReport,
  -- The drive's graph record as the drive left it.  Its `Ref` fields are the
  -- process's, so a later drive writes them.
  gdGraph : GraphCtx,
  -- The drive's frozen answers to the post-drive questions.
  gdOutputs : DriveOutputs,
}

-- ── TYPED multi-module elaboration (bootstrap eval front-end) ──────────────
-- The BINDER-TYPE table and selected entry outcome an elaboration produced (#1112 A-3).
public export data ElabFacts = ElabFacts {
  efManifests : List CapabilityManifest,
  efBinders : BinderTypeTable,
  efEntryOutcome : EntryOutcome,
}

-- `ElabResult` is what a multi-module elaboration returns: the core decls, the
-- elaborated modules, and three diagnostic/evidence views over the same run.
-- `erCore` is the elaborated CORE decls (prelude, post dict-pass).
-- `erModules` is the elaborated user MODULES, in load order, trees refs filled.
-- `erPerModule` is the PER-MODULE diagnostics, one `(mid, (errs, warns))` per user
-- module in load order, with the whole-graph coherence verdict attached to the
-- entry module: the same list `driveGraphK GOutDiags` returns, produced by the same
-- `checkModuleFullDiags` worker.  It is NOT a partition with the residual below:
-- `recordTypeError` writes both channels, so every per-module error is in the
-- residual too; the residual additionally holds what the graph-end drain raised
-- (after every module closed), and this list additionally holds the coherence
-- verdict, which `globalCoherenceConflict` pushes to neither channel.  A consumer
-- renders ONE of them for errors, this one to report as `check` does, the
-- residual to gate on `hadTypeErrors`, never both.
-- `erResidual` is the RESIDUAL: every diagnostic this elaboration recorded and left
-- standing, tagged with its module id, per goal with its own `Loc`, in push order.
-- Callers that gate on `hadTypeErrors` render it instead of a deflection; the emit
-- driver's #2089 gate prints it.  It is the same list the sticky channel holds, cut
-- to this call.
-- `erEvidence` is the EVIDENCE TABLE: the whole table this elaboration produced, keyed
-- by `EvId`: every goal it solved, every method occurrence and every minted site.  It
-- is the table before `mangleUnitsEv` renames the trees, so a caller that lowers
-- mangled trees lowers against the table that call returns.
-- `erDispositions` is the whole-graph per-method DISPOSITION TABLE
-- (`compiler/types/disposition.mdk`).  `erFacts` bundles the binder-type table and the
-- selected entry outcome (`ElabFacts`).
public export data ElabResult = ElabResult {
  erCore : List Decl,
  erModules : List (String, List Decl),
  erPerModule : List (String, (List TcDiag, List TcDiag)),
  erResidual : List (String, TcDiag),
  erEvidence : EvTable,
  erDispositions : DispositionTable,
  erFacts : ElabFacts,
}

-- E4/E6: prePass a module rewriting ARG-position method occurrences to EMethodAt
-- (argNames) AND `=>`-constrained-fn occurrences to EDictAt (dictNames); both
-- populated on every path (single elaboration mode).  Degenerates to
-- prePassModulePair when both are [] (prePassDictArg with empty argNames/dictNames
-- == prePassDict).
-- #1354 unit A (#1353): [shadowNames] (the graph-wide standalone-shadow set) and
-- [argNames] (every interface method with a dispatch argument index, graph-wide) are BOTH
-- decided over the whole loaded graph and BOTH consumed here, per module — so an interface
-- the module cannot name still rewrote its occurrences of a same-named imported standalone
-- to `EMethodAt`, and dispatch then answered from an impl the module has no path to.  Both
-- are filtered to `SHADOW-SEMANTICS.md` S1's `nameable in M` (§1.0; ruling #1375) using the
-- module's own decls, which are exactly what this function already has in hand.
--
-- This is the RUN/BUILD half of the fix; `checkBodyImpl`'s `definerShadows`/
-- `importerShadows` are the CHECK half.  Neither is sufficient alone — the mark pass
-- rewrites the occurrence before typecheck ever consults `standaloneValuesRef`, so
-- filtering only there leaves `check` right and the binary wrong (the S7 divergence #1375
-- warns a mark-pass-only fix introduces, with the arms swapped).
--
-- [shadowMap] is filtered too, and THAT is the arm the emit path actually takes: the
-- mangler rewrites an imported `size` occurrence to `fmod__size`, so neither name set above
-- can match it and `rewriteArgScoped`'s FIRST guard — the `sm` lookup — is what marks it.
-- Filtering it here, at the CONSUMING module, is the placement #1375 requires: the map is a
-- PRODUCER-side index (`computeMangledShadowMap` walks the unit that DEFINES the
-- standalone), and keying its visibility on that definer instead fails CLOSED and reddens
-- the corpus's `i1`/`i3`/`i8`/`i10` — the provider module does not import the consumer
-- where the interface lives (the #411 shape).  Same reason [shadowNames] is scoped through
-- `shadowBareName`: on the emit path `buildStandaloneShadowsGraph` returns MANGLED symbols,
-- and testing a mangled symbol against a set of METHOD names would answer False for every
-- legitimate shadow.
--
-- [dictNames] is the ONE input NOT filtered: those are `=>`-constrained FUNCTION names, not
-- interface methods, and dropping one under-applies a dict-passed callee (`unbound
-- identifier: $dict_…`) — the Phase-134 shape.
--
-- [rpNames] **IS** FILTERED, by the same predicate as everything else here — read the
-- `otherwise` arm below, which is four `filterList`s and one bare `dictNames`.  The split
-- that makes the per-module filter possible is at `markSharedNames`.  This paragraph read
-- *"[rpNames] is not filtered either"* until 2026-08-08: introduced and falsified by the
-- same PR, and then missed by the very commit whose job was retiring that claim at its
-- sibling site.  It was the THIRD copy of the sentence.  Nothing in this tree links a claim
-- to the code it describes, so when one of these turns out to be false, check the SET of
-- sites that assert it — not the one you were handed.
-- The mark inputs for ONE module, minus the dict-name set: the return-position /
-- method-constraint names, the arg-dispatch names and the definer-shadow map, each
-- filtered to what is nameable in the module (the S1 filter below).  Computed once
-- per module by `checkBodyImpl` and applied to each binding group as the schedule
-- reaches it (`markGroupClauses`); the dict-name set is the one input the schedule
-- grows, so it lives beside this in `ModuleMarking`, not in it.
public export data MarkCtx = MarkCtx {
  mcRp : OrdMap Unit,
  mcAn : OrdMap Unit,
  mcSm : List (String, String),
}

-- The three module-level facts the predicate below asks for, derived ONCE for a module
-- instead of once per row.  Every caller filters a whole list against one module, and
-- each conjunct used to rebuild its own answer inside that filter: `declTopFnNames prog`
-- allocated the module's entire top-level name list per row (`funDefs` +21.7M Ir on
-- `check compiler/driver/medaka_cli.mdk`, and its share of a +63.4M `GC_malloc_kind`),
-- `declsBindBareLocal` re-walked its import decls per row (+12.9M), and
-- `mangledName "core" bare` built a fresh String through `sanitizeId` per row
-- (`mangledName` +2.1M, `safeChar` +2.0M, part of `string_slice` +14.2M).  The prefix is
-- `mangledName`'s own answer for the empty name, so the comparison below is the same
-- one, guarded by a `startsWith` that spends no allocation on a symbol that cannot match.
public export data SpellCtx = SpellCtx {
  scTopFns : List String,
  scBare : BareLocals,
  scCorePfx : String,
}

-- The bare LOCAL names a module's import forms bind, as a set — the same answer
-- `importFormBindsBare` gives per name, taken over the module's decls once.  `blAll`
-- is the one case a finite set cannot carry: a WILDCARD form whose dependency the graph
-- cannot speak for answers True for every name, so it admits all of them.  A member list
-- stays finite in that case (its locals are what it spells), which is why the fail-open
-- test sits on the wildcard arm alone.
-- A LIST, not a set, and that is measured: `moduleSpellsShadowBare` is asked a handful
-- of times per module (once per row of a definer-shadow map that holds four rows on the
-- compiler's own graph), so building an `OrdMap` here costs more in inserts than the
-- scans it saves -- the same result the shadow-map index got, one level down.
public export data BareLocals = BareLocals { blAll : Bool, blSet : List String }

-- ── #2548 / DICT §6.2 T4: the stamper order, written once ────────────────────
-- One step per route-stamping resolver, plus the Float literal stamp.  #1116: the
-- sequence is a VALUE rather than nine hand-copied calls, so the schedule that
-- runs it states its order in one vocabulary.
public export data StampStep =
  | SSNumlitFloats
  | SSReturnSites
  | SSBinopSites
  | SSUnopSites
  | SSArithSites
  | SSArgStamps
  | SSRLocalSites
  | SSRecDictApps
  | SSDictApps
  | SSMethodDicts

-- Everything one module's stampers read, cut at the moment they used to run.
--
-- `scModuleCtx` is the module record captured by reference, its run fields whole
-- rather than field by field.  `checkBodyImpl` mints a fresh `ModuleCtx` for the next
-- module, so the record captured here is frozen from that point on and replaying it
-- reproduces, exactly, the tables the per-module drain read — including the ones a
-- graph-end read would silently get wrong (`funPredicateSlotsRef` is scoped to its
-- module and its importers, so at graph end it is the ENTRY module's table, missing
-- every earlier module's rows; `realizeRecDictApps` and `enclDictVarOf` read it).
-- Naming a subset of fields here would make the drain's correctness depend on a
-- reachability argument over `entail`'s transitive reads, which nothing checks.
-- What is deliberately NOT captured is the tyvar substitution, which is not on
-- `ModuleCtx` at all: the drain therefore resolves every module's goals against the
-- FINAL, whole-graph solution, which is the point of draining at quiescence.
--
-- The module-input fields differ from the live record, because each is a per-module
-- table whose size grows with the graph, and holding every module's until the drain
-- would keep them all live and re-marked by every collection.  `superDeclsRef` holds
-- the impl universe reduced to its interface declarations, the only decls
-- `ifaceSupersOf` (super-expansion's reader of `superDeclsRef`) matches, and
-- `currentModuleRef` the module id (`stampCtxOf`).  `standaloneValuesRef` and
-- `methodDispatchIdxByIdRef` are placeholders: the drain reads the record current
-- when it began for those two (`enterStampCtx`).  The other five are empty: nothing
-- the drain runs after `enterStampCtx` reads them, a reachability claim that, unlike
-- the run fields', rests on the drain's call graph and must be re-made when it grows.
public export data StampCtx = StampCtx {
  scModule : String,
  scModuleCtx : ModuleCtx,
  scRpNames : List String,
  scGoals : List Obligation,
  scNumlits : List (Mono, Ref (Option Float), Int, Ref Route),
  -- the spans (`locKey`) of the goals and admitted-set occurrences whose types
  -- mention a live root's variable when the module closed (`liveLocsOf`)
  scLiveLocs : List String,
}

-- A finding of the graph-end drain, under the module it belongs to: a verdict the
-- drain decides (an error in its own right) or an evidence hole (`judgeEvidence`).
-- A live one rests on what quiescence left a live root's variable
-- (`GraphRun.liveRoots`), which an importer's own error can leave unground or ground
-- wrongly.
public export data DrainFinding = DrainFinding {
  dfModule : String,
  dfDiag : TcDiag,
  dfVerdict : Bool,
  dfLive : Bool,
}

-- #2705 (M2 phase 2): the name sets the mark pass consumes, computed ONCE per driver
-- entry from the whole (stamped) graph, by the check drivers' preamble and by
-- `elaborateModules` alike — solving is not optional, so both drivers mark, and
-- they must mark the same tree the same way.
--
-- `msMarkRpNames` (the unsplit set: return-position + method-constrained methods +
-- the graph-wide standalone shadows) is what CORE is marked with; the split halves
-- `msMarkSharedNames`/`msGraphShadowNames` let `moduleMarkCtx` scope the
-- shadow component per user module (#1354).  `msArgNames` is the arg-dispatch NAME
-- set (#1351 L5: names only — the indices are answered by the identity-keyed
-- `argDispatchIdxByIdRef`, written here so a marked tree can be inferred by
-- whichever driver marked it).  `msCoreShadowMap` is the definer-shadow map filtered
-- to what is nameable in core (#2153).  `msBareDictNames` is the `=>`-constrained
-- function set WITHOUT any promotion — the seed the check drivers mark with outright
-- and the promotion fixpoint grows.
public export data MarkSets = MarkSets {
  msMarkRpNames : List String,
  msMarkSharedNames : List String,
  msGraphShadowNames : List String,
  msArgNames : List String,
  msCoreShadowMap : List (String, String),
  msBareDictNames : List String,
  msUnits : List (String, List Decl),  -- `("core", coreDecls) :: modules`, for import-alias expansion
}

-- What `graphPreamble` returns: the runtime seed rows, the prelude's schemes, its
-- published rows (present only when the pass closed core), its contexts, its
-- shipped trees (empty on the diags arm), the mark sets, and the record the core
-- pass leaves current, which the drive's first module starts from.
public export data GraphPreamble = GraphPreamble {
  gpRuntimeSeed : List (String, Scheme),
  gpCoreSchemes : ModuleBindings,
  gpCorePub : Option (List (String, PubScheme)),
  gpCoreContexts : OrdMap (List VecObl),
  gpCoreTree : List Decl,
  gpMarkSets : MarkSets,
  gpCoreCtx : ModuleCtx,
}

-- The prelude-only half of `markSetsOf`'s inputs.  Every field is a pure value
-- of `coreDecls` alone, holding only `String`/`Int`/`IfaceRef` rows -- see
-- `PreludePreamble` for why nothing decl-shaped may live here.
public export data PreludeMarkFacts = PreludeMarkFacts {
  pmfReturnPos : List String,
  pmfMethodConstraints : List String,
  pmfArgDispatch : List (String, Int),
  pmfArgDispatchById : List ((IfaceRef, String), Int),
  pmfConstrainedNames : List String,
}

-- ── Marking on the schedule (ARCH §E) ────────────────────────────────────────
-- Marking is the `EVar` → `EDictAt`/`EMethodAt` rewrite; every input it needs is
-- declaration-level EXCEPT the promoted set — the unsignatured functions that infer
-- a constraint and so gain a leading dict parameter — which only inference can
-- supply.  A whole-tree pre-pass therefore had to be re-run once per layer of a
-- promoted call chain (`elabPromotionFixpoint`, retired).  Instead `checkBodyImpl`
-- marks each binding group as the schedule reaches it, after its callees have
-- generalized: a callee promoted in an earlier group (or module — the loader orders
-- modules dependency-first) is already in the set when its caller's group is marked,
-- so one sweep marks what the fixpoint's closing sweep marked.  The one place a
-- callee has NOT generalized when its caller is marked is its own group; those
-- occurrences are rewritten when the group closes (`markRecursiveOccurrences`),
-- carrying the goal inference would have pushed for them.
--
-- One module's marking state: the mark context (`moduleMarkCtx`), the binding-id
-- scope resolve's `stampTopScope` minted for the module, and the dict-name set —
-- the bare set plus every promotion so far (earlier modules through
-- `promotionHarvestRef`, this module's earlier groups through
-- `markRecursiveOccurrences`) plus this module's import aliases of those names.
public export data ModuleMarking = ModuleMarking {
  mmCtx : MarkCtx,
  mmTop : OrdMap Int,
  mmDictSet : Ref (OrdMap Unit),
  -- the value names the module defines at top level or imports: a use of one is
  -- that binding, never a catalog extern of the same spelling
  mmUserNames : OrdMap Unit,
  -- the externs among the names the module declares or imports
  mmExterns : OrdMap Unit,
}

-- What one `dictPass` call reads a method occurrence's published entry from: the
-- drive's index, and then, by ordinal, the occurrences the call itself mints
-- (`mintMethodCellWith`) after the index was taken.
public export data PassEvidence = PassEvidence EvIndex (Ref (OrdMap EvVal))

-- What a method occurrence's published entry says: its interface word, dispatch
-- route and dict routes (impl dicts first).
public export data PassMethod = PassMethod String Route (List Route)

-- ── UNIFIED per-module fold ───────────────────────────────────────────────────
-- The single home for the identical per-module skeleton the four module drivers
-- (checkModules / checkModulesDiagsChain / checkModulesEntryFull / elaborateModules)
-- share, so the next import-scoped-seed-style fix touches ONE place instead of
-- four (the miss would otherwise be path-specific — LSP-only or emit-only).  It
-- owns: the IMPORT-SCOPED seed (`baseSeed ++ importSeed prog depEnv` — a flat
-- union let `string.reverse` shadow the `list.reverse` a module imports), the
-- per-module PUBLIC accumulator (`pubV = pickSchemes (exportedValueNames prog) schemes
-- ++ reexportSeed coreV prog depEnv`), and the DEPENDENCY-FIRST threading of
-- depEnv (PREPEND `(mid,pubV)::depEnv`, so importSeed's first-match picks the
-- nearest dependency), accData (`++ publicDataDecls prog`) and accAll (`++ prog`,
-- the cumulative impl-body universe).  Each driver supplies:
--   * worker  : prev mid seed accData accAll prog -> (schemes, extra, mctx) — runs
--               the per-module pass; MUST surface `schemes` (pubV needs it for the
--               next depEnv) plus its driver-specific payload `extra`.  [prev] is the
--               record current before the module; [mctx] the one it was checked in,
--               which the next module starts from and the fold returns last.
--   * collect : place mid extra restResult -> result — a foldr combiner, where
--               restResult is the fold over the REMAINING modules (`base` for []).
--               `place` is `LastModule` only for the terminal (entry) module — the one
--               place checkModulesEntryFull keeps the module's OWN schemes/warns
--               rather than the recursion's.
--   * serve   : the drive's serve policy (`ModuleServe`), `None` for a drive that
--               checks every module.  It is consulted once for each module before the
--               entry; a module it serves skips the worker, and the policy supplies
--               its own export bindings and its payload.  The policy comes back last.
-- foldModules owns ONLY the loop and performs NO mintGraphCtx: the reset
-- boundary stays in each driver's preamble (a reset leaking in here would hand the
-- `check*` drivers a reset they must not have).
-- `Accumulate` is the per-worker "needs" signal gating the two accumulator
-- concats.  Each worker declares which accumulator it reads; under
-- `AccumulateNone` neither is read, so both are threaded unchanged (no copy of the
-- growing left operand, which would make the graph O(modules^2) in allocation) and
-- a path that consumes neither does O(|prog|) per module.  Under `AccumulateBoth`
-- each is extended (`accData ++ publicDataDecls prog`, `accAll ++ prog`).  No
-- worker reads one accumulator without the other.
public export data Accumulate = AccumulateNone | AccumulateBoth

-- Where a module sits in the fold's right-to-left `collect`: the terminal (entry)
-- module, or any earlier one.
public export data ModulePlace = LastModule | NotLastModule

-- What `foldModules` and `workModules` take unchanged for every module: the
-- accumulator policy, the per-module worker, the combiner `collect` applies to the
-- payloads, the base seed rows, and the prelude's export bindings (`coreV`).
public export data FoldPlan e acc = FoldPlan {
  fpAccumulate : Accumulate,
  fpWorker : ModuleCtx -> String -> ModuleSeed -> List Decl -> List Decl -> List Decl -> (ModuleBindings, e, ModuleCtx),
  fpCollect : ModulePlace -> String -> e -> acc -> acc,
  fpBaseSeed : List (String, Scheme),
  fpCoreV : List (String, ExportBinding),
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Ident" true) (mem "Route" true) (mem "EvId" true) (mem "EvVal" true) (mem "EvTable" false) (mem "Arm" true) (mem "Expr" true) (mem "Loc" true) (mem "Field" true) (mem "Variant" true) (mem "Require" true) (mem "Super" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Decl" true) (mem "TabKey" true) (mem "EffParamTy" true))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omInsert" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true) (mem "Atom" true) (mem "EffRow" true) (mem "Effvar" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "AlphaBinder" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "SummarySolver" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true) (mem "SolverEvidence" true))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true) (mem "SolverOutcome" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "registry") ((mem "RegKey" false) (mem "Registry" false) (mem "HeadKey" true) (mem "MultiRegistry" false) (mem "SpellingPop" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeCursor" true) (mem "ScopeStore" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "ModDiags" false) (mem "PubScheme" true) (mem "TcReport" false) (mem "EntryOutcome" false) (mem "noEntryOutcome" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" false) (mem "ManifestRequest" false) (mem "CapabilityManifest" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false))))
(DData Public "ObligationSite" () ((variant "ObligationSite" (ConNamed (field "osLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "osFn" (TyCon "String")) (field "osCovering" (TyCon "Bool"))))) ())
(DData Public "RecordInfo" () ((variant "RecordInfo" (ConPos (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "OrdMap") (TyCon "Mono"))))) ())
(DData Public "Kind" () ((variant "KType" (ConPos)) (variant "KRow" (ConPos)) (variant "KAuth" (ConPos (TyCon "EffLabel") (TyCon "Bool")))) ())
(DData Public "Polarity" () ((variant "PCo" (ConPos)) (variant "PContra" (ConPos)) (variant "PInv" (ConPos)) (variant "PPhantom" (ConPos))) ())
(DData Public "SiteKind" () ((variant "SKReturn" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono"))) (variant "SKAdmittedReturn" (ConPos (TyApp (TyCon "Ref") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono"))) (variant "SKExactReturn" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "MethodReturnRequest"))) (variant "SKNumReturn" (ConPos (TyCon "ClassPredicate") (TyCon "Mono"))) (variant "SKArg" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "SKOp" (ConPos (TyCon "Bool"))) (variant "SKPredicateOp" (ConPos (TyCon "Bool") (TyCon "ClassPredicate"))) (variant "SKRLocal" (ConPos (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "PendingEntry" () ((variant "PendingEntry" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono") (TyCon "String") (TyCon "SiteKind") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "ScopeId") (TyCon "EvId")))) ())
(DData Public "GoalKind" () ((variant "GKReturnSite" (ConPos)) (variant "GKArgStamp" (ConPos)) (variant "GKRLocalSite" (ConPos)) (variant "GKBinopSite" (ConPos)) (variant "GKUnopSite" (ConPos)) (variant "GKArithSite" (ConPos)) (variant "GKDictApp" (ConPos)) (variant "GKMethodDict" (ConPos)) (variant "GKRecDictApp" (ConPos))) ())
(DData Public "EvDest" () ((variant "EvRoute" (ConPos (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EvRoutes" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "GoalPayload" () ((variant "GPSite" (ConPos (TyCon "String") (TyCon "Mono") (TyCon "SiteKind"))) (variant "GPArith" (ConPos (TyCon "Mono"))) (variant "GPDictApp" (ConPos (TyCon "PendingDictApp"))) (variant "GPMethodDict" (ConPos (TyCon "PendingMethodDict"))) (variant "GPRecDictApp" (ConPos (TyCon "RecDictApp")))) ())
(DData Public "Obligation" () ((variant "Obligation" (ConNamed (field "oKind" (TyCon "GoalKind")) (field "oDest" (TyCon "EvDest")) (field "oEv" (TyCon "EvId")) (field "oEncl" (TyCon "String")) (field "oLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "oScope" (TyCon "ScopeId")) (field "oPayload" (TyCon "GoalPayload")) (field "oInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "DeclEnvModule" () ((variant "DeclEnvModule" (ConNamed (field "demOrd" (TyCon "Int")) (field "demId" (TyCon "String")) (field "demDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "demPubDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "demKindEntries" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))) (field "demSiblingOrd" (TyCon "Int"))))) ())
(DData Public "DeclEnvs" () ((variant "DeclEnvs" (ConNamed (field "deModules" (TyApp (TyCon "List") (TyCon "DeclEnvModule"))) (field "deOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "deDefiners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))) (field "deAmbigValues" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "deAllDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "deData" (TyCon "DataEnv")) (field "deImpls" (TyCon "ImplEnv")) (field "deIfaces" (TyCon "ClassEnv")) (field "deMethods" (TyCon "MethodEnv")) (field "deKindsBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "deNameIndexBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "dePolaritiesBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (field "deAtomsBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (field "deOwnersBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "deOwnerModules" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "deReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "DeclEnvAcc" () ((variant "DeclEnvAcc" (ConNamed (field "daOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "daDefiners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))) (field "daAmbig" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "daData" (TyCon "DataEnv")) (field "daImpls" (TyCon "ImplAcc")) (field "daIfaces" (TyCon "ClassEnv")) (field "daMethods" (TyCon "MethodEnv")) (field "daSeeds" (TyCon "DeclEnvSeedAcc")) (field "daPolarity" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity"))))))) (field "daOwnerModules" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DData Public "DeclEnvSeedAcc" () ((variant "DeclEnvSeedAcc" (ConNamed (field "dsKAcc" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))) (field "dsOAcc" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "dsNAcc" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "dsKinds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "dsOwners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "dsNames" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "DataTypeDecl" () ((variant "DataTypeDecl" (ConNamed (field "dtKey" (TyCon "TabKey")) (field "dtName" (TyCon "String")) (field "dtOrigin" (TyCon "TyConOrigin")) (field "dtParams" (TyApp (TyCon "List") (TyCon "String"))) (field "dtVariants" (TyApp (TyCon "List") (TyCon "Variant")))))) ())
(DData Public "AliasDecl" () ((variant "AliasDecl" (ConNamed (field "adKey" (TyCon "TabKey")) (field "adName" (TyCon "String")) (field "adParams" (TyApp (TyCon "List") (TyCon "String"))) (field "adRhs" (TyCon "Ty")) (field "adOrd" (TyCon "Int")) (field "adPub" (TyCon "Bool")) (field "adAttrib" (TyCon "Bool"))))) ())
(DData Public "DataEnv" () ((variant "DataEnv" (ConNamed (field "deTypes" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "DataTypeDecl")))) (field "deCtorIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Variant"))))) (field "deRecordIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyApp (TyCon "List") (TyCon "Field")))))) (field "deFieldOwnerIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String"))))) (field "deAliases" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl")))) (field "deCtorExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))) ())
(DData Public "InstRef" () ((variant "InstRef" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "ImplRow" () ((variant "ImplRow" (ConPos (TyCon "Int") (TyCon "InstRef") (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ImplEnv" () ((variant "ImplEnv" (ConNamed (field "ieRows" (TyApp (TyCon "List") (TyCon "ImplRow"))) (field "ieConcrete" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieHeadless" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieByHead" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieUnivSnaps" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))))))) ())
(DData Public "ImplAcc" () ((variant "ImplAcc" (ConNamed (field "iaEnv" (TyCon "ImplEnv")) (field "iaSeq" (TyCon "Int")) (field "iaSnaps" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))) ())
(DData Public "CeRow" () ((variant "CeRow" (ConPos (TyCon "RegKey") (TyCon "Int") (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ClassEnv" () ((variant "ClassEnv" (ConNamed (field "ceRows" (TyApp (TyCon "List") (TyCon "CeRow"))) (field "ceByKey" (TyApp (TyCon "Registry") (TyCon "CeRow")))))) ())
(DTypeAlias true "MethodEntry" () (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))
(DData Public "MethodRow" () ((variant "MethodRow" (ConNamed (field "mrIdent" (TyCon "Ident")) (field "mrOrd" (TyCon "Int")) (field "mrIface" (TyCon "RegKey")) (field "mrEntry" (TyCon "MethodEntry"))))) ())
(DData Public "MethodEnv" () ((variant "MethodEnv" (ConNamed (field "meByName" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow")))) (field "meExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))) (field "meIfaceExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))) ())
(DData Public "MethodScope" () ((variant "MsAbsent" (ConPos)) (variant "MsOne" (ConPos (TyCon "MethodRow"))) (variant "MsMany" (ConPos (TyApp (TyCon "List") (TyCon "IfaceRef"))))) ())
(DData Public "GraphCtx" () ((variant "GraphCtx" (ConNamed (field "crossRun" (TyCon "CrossRun")) (field "graphRun" (TyCon "GraphRun")) (field "effectDomains" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))) (field "config" (TyApp (TyCon "Ref") (TyCon "TcConfig"))) (field "trace" (TyApp (TyCon "Option") (TyCon "TraceSink"))) (field "graphAdmittedMethodsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) (field "declEnvsRef" (TyApp (TyCon "Ref") (TyCon "DeclEnvs"))) (field "abstractRecordTypesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "argDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "dictEligibleRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "dictEligibleSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "mangledShadowMapRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (field "mangledFunDefsPresentRef" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "builtinExternNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))) (field "promotionHarvestRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "mainSchemeRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Scheme")))) (field "markSetsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MarkSets")))) (field "typeErrorsSticky" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "typeErrorsStickyDiags" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))) ())
(DData Public "TcConfig" () ((variant "TcConfig" (ConNamed (field "tcIoJoin" (TyApp (TyCon "List") (TyCon "Atom"))) (field "tcIoJoinProfile" (TyCon "String")) (field "tcStdlibOwned" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "tcFlatEntryIsStdlib" (TyCon "Bool")) (field "tcKey" (TyCon "String")) (field "tcSibling" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "TraceSink" () ((variant "TraceSink" (ConNamed (field "tsAssumptionEnabled" (TyCon "Bool")) (field "tsAssumptionEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "AssumptionTraceEntry")))) (field "tsNumericPredicateEnabled" (TyCon "Bool")) (field "tsNumericPredicateEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "NumericPredicateTraceEntry")))) (field "tsMethodReturnEnabled" (TyCon "Bool")) (field "tsMethodReturnEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "MethodReturnTraceEntry")))) (field "tsEvidenceObservationEnabled" (TyCon "Bool")) (field "tsEvidenceObservationEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))) ())
(DData Public "DriveInputs" () ((variant "DriveInputs" (ConNamed (field "diExecutedMainDriver" (TyApp (TyCon "Option") (TyCon "EntryKey"))) (field "diManifestRequests" (TyApp (TyCon "List") (TyCon "ManifestSelector"))) (field "diStdlibOwned" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "diFlatEntryIsStdlib" (TyCon "Bool")) (field "diTrace" (TyApp (TyCon "Option") (TyCon "TraceSink"))) (field "diIoJoinGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))) (field "diProfileName" (TyCon "String")) (field "diPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "diSibling" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "DriveArgs" () ((variant "DriveArgs" (ConNamed (field "daInputs" (TyCon "DriveInputs")) (field "daValueMain" (TyCon "Bool")) (field "daExecutes" (TyApp (TyCon "Option") (TyCon "String"))) (field "daPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "daKeyed" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))) (field "daRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "daCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "daModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "DriveOutputs" () ((variant "DriveOutputs" (ConNamed (field "doManifestRequests" (TyApp (TyCon "List") (TyCon "ManifestRequest"))) (field "doManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "doEntryOutcome" (TyCon "EntryOutcome")) (field "doHadTypeErrors" (TyCon "Bool")) (field "doHadMatchWarnings" (TyCon "Bool")) (field "doInvocationView" (TyCon "InvocationView")) (field "doGrantsEnabled" (TyCon "Bool")) (field "doEffectDomains" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))) (field "doStickyDiags" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "doIfaceExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "doFfiAliases" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl")))) (field "doOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "doEffvarNext" (TyCon "Int")) (field "doServedModules" (TyCon "Int"))))) ())
(DTypeSig true "emptyDriveOutputs" (TyFun (TyCon "Unit") (TyCon "DriveOutputs")))
(DFunDef false "emptyDriveOutputs" (PWild) (ERecordCreate "DriveOutputs" ((fa "doManifestRequests" (EListLit)) (fa "doManifests" (EListLit)) (fa "doEntryOutcome" (EVar "noEntryOutcome")) (fa "doHadTypeErrors" (EVar "False")) (fa "doHadMatchWarnings" (EVar "False")) (fa "doInvocationView" (EApp (EApp (EApp (EVar "InvocationView") (EListLit)) (EListLit)) (EListLit))) (fa "doGrantsEnabled" (EVar "False")) (fa "doEffectDomains" (EListLit)) (fa "doStickyDiags" (EListLit)) (fa "doIfaceExports" (EVar "omEmpty")) (fa "doFfiAliases" (EListLit)) (fa "doOrdIndex" (EVar "omEmpty")) (fa "doEffvarNext" (ELit (LInt 0))) (fa "doServedModules" (ELit (LInt 0))))))
(DTypeSig true "withPublishedManifests" (TyFun (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyFun (TyCon "DriveOutputs") (TyCon "DriveOutputs")))))
(DFunDef false "withPublishedManifests" ((PVar "requests") (PVar "manifests") (PVar "outputs")) (ERecordUpdate (EVar "outputs") ((fa "doManifestRequests" (EVar "requests")) (fa "doManifests" (EVar "manifests")))))
(DTypeSig true "manifestDriverFor" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "EntryKey")))))
(DFunDef false "manifestDriverFor" (PWild (PCon "Some" (PVar "name"))) (EApp (EVar "Some") (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (EVar "name"))))))
(DFunDef false "manifestDriverFor" ((PVar "inputs") (PCon "None")) (EFieldAccess (EVar "inputs") "diExecutedMainDriver"))
(DData Public "Windowed" ("a") ((variant "Windowed" (ConNamed (field "items" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyVar "a")))) (field "n" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "CSlot" () ((variant "CSlot" (ConNamed (field "csIface" (TyCon "IfaceRef")) (field "csId" (TyCon "Int"))))) ())
(DData Public "PredicateSlotArgs" () ((variant "PSArgsUnknown" (ConPos)) (variant "PSArgsKnown" (ConPos (TyApp (TyCon "List") (TyCon "Mono"))))) ())
(DData Public "PredicateRequest" () ((variant "PredicateRequest" (ConNamed (field "prIface" (TyCon "IfaceRef")) (field "prArgs" (TyCon "PredicateSlotArgs"))))) ())
(DData Public "PredicateSlot" () ((variant "PredicateSlot" (ConNamed (field "psIface" (TyCon "IfaceRef")) (field "psArgs" (TyCon "PredicateSlotArgs")) (field "psBoundIds" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "MethodPredicateSlot" () ((variant "MethodPredicateSlot" (ConNamed (field "mpsPredicate" (TyCon "PredicateSlot")) (field "mpsPositions" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "MethodPredicateTemplate" () ((variant "MethodPredicateTemplate" (ConNamed (field "mptInterface" (TyCon "IfaceRef")) (field "mptArguments" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))))))) ())
(DData Public "MethodSchemeRow" () ((variant "MethodSchemeRow" (ConNamed (field "msrIface" (TyCon "IfaceRef")) (field "msrName" (TyCon "String")) (field "msrTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "msrType" (TyCon "Ty")) (field "msrScheme" (TyCon "Scheme")) (field "msrPredicateTemplate" (TyCon "MethodPredicateTemplate")) (field "msrMethodSlots" (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) ())
(DData Public "MethodInstantiationSubst" () ((variant "MethodInstantiationSubst" (ConNamed (field "misTypeSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (field "misEffectSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "misAuthSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) ())
(DData Public "MethodTrackedInstantiation" () ((variant "MethodTrackedInstantiation" (ConNamed (field "mtiBody" (TyCon "Mono")) (field "mtiForce" (TyCon "EffRow")) (field "mtiResidual" (TyApp (TyCon "List") (TyCon "AuthResidual"))) (field "mtiSubstitution" (TyCon "MethodInstantiationSubst"))))) ())
(DData Public "MethodReturnResolution" () ((variant "MethodReturnResolution" (ConNamed (field "mrrWanted" (TyCon "Wanted")) (field "mrrOutcome" (TyCon "SolverOutcome")) (field "mrrSelectedRow" (TyApp (TyCon "Option") (TyCon "ImplRow")))))) ())
(DData Public "MethodReturnRequest" () ((variant "MethodReturnRequest" (ConNamed (field "mrrIface" (TyCon "IfaceRef")) (field "mrrName" (TyCon "String")) (field "mrrTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "mrrType" (TyCon "Ty")) (field "mrrOccurrence" (TyCon "Mono")) (field "mrrEnclosing" (TyCon "String")) (field "mrrLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "mrrScope" (TyCon "ScopeId")) (field "mrrGoalEv" (TyApp (TyCon "Option") (TyCon "EvId"))) (field "mrrQualifiedBody" (TyCon "Mono")) (field "mrrPredicateTemplate" (TyCon "MethodPredicateTemplate")) (field "mrrOmitted" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mrrResolution" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MethodReturnResolution"))))))) ())
(DData Public "NumAnchorTestObservation" () ((variant "NumAnchorTestObservation" (ConNamed (field "natoCase" (TyCon "String")) (field "natoHasRow" (TyCon "Bool")) (field "natoIface" (TyCon "String")) (field "natoSchemeBody" (TyCon "String")) (field "natoDeclaredType" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "NumAnchorTestObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__a0")) (rf "natoHasRow" (PVar "__a1")) (rf "natoIface" (PVar "__a2")) (rf "natoSchemeBody" (PVar "__a3")) (rf "natoDeclaredType" (PVar "__a4"))) false) (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__b0")) (rf "natoHasRow" (PVar "__b1")) (rf "natoIface" (PVar "__b2")) (rf "natoSchemeBody" (PVar "__b3")) (rf "natoDeclaredType" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "NumAnchorTestObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__a0")) (rf "natoHasRow" (PVar "__a1")) (rf "natoIface" (PVar "__a2")) (rf "natoSchemeBody" (PVar "__a3")) (rf "natoDeclaredType" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "NumAnchorTestObservation {")) (ELit (LString " natoCase = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", natoHasRow = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", natoIface = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", natoSchemeBody = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", natoDeclaredType = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "MethodRowTestObservation" () ((variant "MethodRowTestObservation" (ConNamed (field "mrtoSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoSlotBoundIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotPositions" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotIdsAtPositions" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotArgumentIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoCounterBefore" (TyCon "Int")) (field "mrtoCounterAfterFirst" (TyCon "Int")) (field "mrtoCounterAfterSecond" (TyCon "Int")) (field "mrtoFirstSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoSecondSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoFirstRowSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSecondRowSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoRegistryAfterSecondSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSameNameForward" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) (field "mrtoSameNameReverse" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) (field "mrtoConstantRowCount" (TyCon "Int")) (field "mrtoConstantSchemeIdCount" (TyCon "Int")) (field "mrtoConstantBodyIsFunction" (TyCon "Bool")) (field "mrtoConstantSlotCount" (TyCon "Int")) (field "mrtoAttributedRowCount" (TyCon "Int")) (field "mrtoAttributedParamIface" (TyCon "String")) (field "mrtoAttributedParamTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "mrtoNumAnchors" (TyApp (TyCon "List") (TyCon "NumAnchorTestObservation")))))) ())
(DImpl true "Eq" ((TyCon "MethodRowTestObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__a0")) (rf "mrtoSlotBoundIds" (PVar "__a1")) (rf "mrtoSlotPositions" (PVar "__a2")) (rf "mrtoSlotIdsAtPositions" (PVar "__a3")) (rf "mrtoSlotArgumentIds" (PVar "__a4")) (rf "mrtoCounterBefore" (PVar "__a5")) (rf "mrtoCounterAfterFirst" (PVar "__a6")) (rf "mrtoCounterAfterSecond" (PVar "__a7")) (rf "mrtoFirstSchemeIds" (PVar "__a8")) (rf "mrtoSecondSchemeIds" (PVar "__a9")) (rf "mrtoFirstRowSlotIds" (PVar "__a10")) (rf "mrtoSecondRowSlotIds" (PVar "__a11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__a12")) (rf "mrtoSameNameForward" (PVar "__a13")) (rf "mrtoSameNameReverse" (PVar "__a14")) (rf "mrtoConstantRowCount" (PVar "__a15")) (rf "mrtoConstantSchemeIdCount" (PVar "__a16")) (rf "mrtoConstantBodyIsFunction" (PVar "__a17")) (rf "mrtoConstantSlotCount" (PVar "__a18")) (rf "mrtoAttributedRowCount" (PVar "__a19")) (rf "mrtoAttributedParamIface" (PVar "__a20")) (rf "mrtoAttributedParamTyparams" (PVar "__a21")) (rf "mrtoNumAnchors" (PVar "__a22"))) false) (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__b0")) (rf "mrtoSlotBoundIds" (PVar "__b1")) (rf "mrtoSlotPositions" (PVar "__b2")) (rf "mrtoSlotIdsAtPositions" (PVar "__b3")) (rf "mrtoSlotArgumentIds" (PVar "__b4")) (rf "mrtoCounterBefore" (PVar "__b5")) (rf "mrtoCounterAfterFirst" (PVar "__b6")) (rf "mrtoCounterAfterSecond" (PVar "__b7")) (rf "mrtoFirstSchemeIds" (PVar "__b8")) (rf "mrtoSecondSchemeIds" (PVar "__b9")) (rf "mrtoFirstRowSlotIds" (PVar "__b10")) (rf "mrtoSecondRowSlotIds" (PVar "__b11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__b12")) (rf "mrtoSameNameForward" (PVar "__b13")) (rf "mrtoSameNameReverse" (PVar "__b14")) (rf "mrtoConstantRowCount" (PVar "__b15")) (rf "mrtoConstantSchemeIdCount" (PVar "__b16")) (rf "mrtoConstantBodyIsFunction" (PVar "__b17")) (rf "mrtoConstantSlotCount" (PVar "__b18")) (rf "mrtoAttributedRowCount" (PVar "__b19")) (rf "mrtoAttributedParamIface" (PVar "__b20")) (rf "mrtoAttributedParamTyparams" (PVar "__b21")) (rf "mrtoNumAnchors" (PVar "__b22"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EVar "eq") (EVar "__a6")) (EVar "__b6"))) (EApp (EApp (EVar "eq") (EVar "__a7")) (EVar "__b7"))) (EApp (EApp (EVar "eq") (EVar "__a8")) (EVar "__b8"))) (EApp (EApp (EVar "eq") (EVar "__a9")) (EVar "__b9"))) (EApp (EApp (EVar "eq") (EVar "__a10")) (EVar "__b10"))) (EApp (EApp (EVar "eq") (EVar "__a11")) (EVar "__b11"))) (EApp (EApp (EVar "eq") (EVar "__a12")) (EVar "__b12"))) (EApp (EApp (EVar "eq") (EVar "__a13")) (EVar "__b13"))) (EApp (EApp (EVar "eq") (EVar "__a14")) (EVar "__b14"))) (EApp (EApp (EVar "eq") (EVar "__a15")) (EVar "__b15"))) (EApp (EApp (EVar "eq") (EVar "__a16")) (EVar "__b16"))) (EApp (EApp (EVar "eq") (EVar "__a17")) (EVar "__b17"))) (EApp (EApp (EVar "eq") (EVar "__a18")) (EVar "__b18"))) (EApp (EApp (EVar "eq") (EVar "__a19")) (EVar "__b19"))) (EApp (EApp (EVar "eq") (EVar "__a20")) (EVar "__b20"))) (EApp (EApp (EVar "eq") (EVar "__a21")) (EVar "__b21"))) (EApp (EApp (EVar "eq") (EVar "__a22")) (EVar "__b22"))))))))
(DImpl true "Debug" ((TyCon "MethodRowTestObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__a0")) (rf "mrtoSlotBoundIds" (PVar "__a1")) (rf "mrtoSlotPositions" (PVar "__a2")) (rf "mrtoSlotIdsAtPositions" (PVar "__a3")) (rf "mrtoSlotArgumentIds" (PVar "__a4")) (rf "mrtoCounterBefore" (PVar "__a5")) (rf "mrtoCounterAfterFirst" (PVar "__a6")) (rf "mrtoCounterAfterSecond" (PVar "__a7")) (rf "mrtoFirstSchemeIds" (PVar "__a8")) (rf "mrtoSecondSchemeIds" (PVar "__a9")) (rf "mrtoFirstRowSlotIds" (PVar "__a10")) (rf "mrtoSecondRowSlotIds" (PVar "__a11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__a12")) (rf "mrtoSameNameForward" (PVar "__a13")) (rf "mrtoSameNameReverse" (PVar "__a14")) (rf "mrtoConstantRowCount" (PVar "__a15")) (rf "mrtoConstantSchemeIdCount" (PVar "__a16")) (rf "mrtoConstantBodyIsFunction" (PVar "__a17")) (rf "mrtoConstantSlotCount" (PVar "__a18")) (rf "mrtoAttributedRowCount" (PVar "__a19")) (rf "mrtoAttributedParamIface" (PVar "__a20")) (rf "mrtoAttributedParamTyparams" (PVar "__a21")) (rf "mrtoNumAnchors" (PVar "__a22"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodRowTestObservation {")) (ELit (LString " mrtoSchemeIds = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", mrtoSlotBoundIds = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", mrtoSlotPositions = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", mrtoSlotIdsAtPositions = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", mrtoSlotArgumentIds = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString ", mrtoCounterBefore = "))) (EApp (EVar "debug") (EVar "__a5"))) (ELit (LString ", mrtoCounterAfterFirst = "))) (EApp (EVar "debug") (EVar "__a6"))) (ELit (LString ", mrtoCounterAfterSecond = "))) (EApp (EVar "debug") (EVar "__a7"))) (ELit (LString ", mrtoFirstSchemeIds = "))) (EApp (EVar "debug") (EVar "__a8"))) (ELit (LString ", mrtoSecondSchemeIds = "))) (EApp (EVar "debug") (EVar "__a9"))) (ELit (LString ", mrtoFirstRowSlotIds = "))) (EApp (EVar "debug") (EVar "__a10"))) (ELit (LString ", mrtoSecondRowSlotIds = "))) (EApp (EVar "debug") (EVar "__a11"))) (ELit (LString ", mrtoRegistryAfterSecondSlotIds = "))) (EApp (EVar "debug") (EVar "__a12"))) (ELit (LString ", mrtoSameNameForward = "))) (EApp (EVar "debug") (EVar "__a13"))) (ELit (LString ", mrtoSameNameReverse = "))) (EApp (EVar "debug") (EVar "__a14"))) (ELit (LString ", mrtoConstantRowCount = "))) (EApp (EVar "debug") (EVar "__a15"))) (ELit (LString ", mrtoConstantSchemeIdCount = "))) (EApp (EVar "debug") (EVar "__a16"))) (ELit (LString ", mrtoConstantBodyIsFunction = "))) (EApp (EVar "debug") (EVar "__a17"))) (ELit (LString ", mrtoConstantSlotCount = "))) (EApp (EVar "debug") (EVar "__a18"))) (ELit (LString ", mrtoAttributedRowCount = "))) (EApp (EVar "debug") (EVar "__a19"))) (ELit (LString ", mrtoAttributedParamIface = "))) (EApp (EVar "debug") (EVar "__a20"))) (ELit (LString ", mrtoAttributedParamTyparams = "))) (EApp (EVar "debug") (EVar "__a21"))) (ELit (LString ", mrtoNumAnchors = "))) (EApp (EVar "debug") (EVar "__a22"))) (ELit (LString " }"))))))))
(DData Public "CDeclaredPrefix" () ((variant "CDPUnknown" (ConPos)) (variant "CDPLen" (ConPos (TyCon "Int")))) ())
(DData Public "CDeclared" () ((variant "CDeclared" (ConNamed (field "cdSlots" (TyApp (TyCon "List") (TyCon "CSlot"))) (field "cdPrefix" (TyCon "CDeclaredPrefix")) (field "cdArgs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ShadowDicts" () ((variant "ShadowDicts" (ConNamed (field "sdMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "sdIfaces" (TyApp (TyCon "List") (TyCon "IfaceRef"))) (field "sdArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "Predicate" () ((variant "Predicate" (ConNamed (field "iface" (TyCon "IfaceRef")) (field "args" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "Provenance" () ((variant "POperator" (ConPos)) (variant "PNumLit" (ConPos)) (variant "PMethodOcc" (ConPos)) (variant "PCallSlot" (ConPos)) (variant "PSchemeReinst" (ConPos)) (variant "PMethodLevel" (ConPos))) ())
(DData Public "OblProjection" () ((variant "OpProjected" (ConPos)) (variant "OpMethodOcc" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "OpExactReturn" (ConPos (TyCon "MethodReturnRequest"))) (variant "OpNumLit" (ConPos (TyCon "Mono")))) ())
(DData Public "UObligation" () ((variant "UObligation" (ConNamed (field "pred" (TyCon "Predicate")) (field "originId" (TyCon "Int")) (field "prov" (TyCon "Provenance")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "uoScope" (TyCon "ScopeId")) (field "oblProj" (TyCon "OblProjection"))))) ())
(DData Public "AbsorptionEvent" () ((variant "AbsorptionEvent" (ConNamed (field "atom" (TyCon "Atom")) (field "cell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "PendingDictApp" () ((variant "PendingDictApp" (ConNamed (field "pdaRoutesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "pdaEv" (TyCon "EvId")) (field "pdaMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "pdaIfaces" (TyApp (TyCon "List") (TyCon "IfaceRef"))) (field "pdaArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))) (field "pdaEncl" (TyCon "String")) (field "pdaLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "pdaScope" (TyCon "ScopeId")) (field "pdaCallee" (TyCon "String"))))) ())
(DData Public "PendingMethodDict" () ((variant "PendingMethodDict" (ConNamed (field "pmdRoutesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "pmdEv" (TyCon "EvId")) (field "pmdSlots" (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (field "pmdEncl" (TyCon "String")) (field "pmdScope" (TyCon "ScopeId")) (field "pmdInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "CrossRun" () ((variant "CrossRun" (ConNamed (field "universeFunNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "universeMethodDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "universeDataCtors" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))))) (field "universeCtorPop" (TyApp (TyCon "Ref") (TyApp (TyCon "SpellingPop") (TyCon "Scheme")))) (field "universeRecordPop" (TyApp (TyCon "Ref") (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")))) (field "builtinClassesRef" (TyApp (TyCon "Ref") (TyCon "BuiltinClasses"))) (field "crossModuleFunPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "crossModuleFunPredicateSlotsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "crossModuleFunConstraintDeclaredRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix"))))) (field "crossModuleFunConstraintDeclaredQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix"))))) (field "crossModuleMethodPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "crossModuleMethodPredicateSlotsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "coreSchemeObligationsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "crossModuleSchemeOblsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))))))) ())
(DData Public "RecDictApp" () ((variant "RecDictApp" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "String") (TyCon "String") (TyCon "Mono") (TyCon "ScopeId") (TyCon "EvId")))) ())
(DData Public "JoinContext" () ((variant "JoinIf" (ConPos)) (variant "JoinElselessIf" (ConPos)) (variant "JoinList" (ConPos)) (variant "JoinCons" (ConPos)) (variant "JoinArray" (ConPos)) (variant "JoinMatch" (ConPos)) (variant "JoinArgument" (ConPos)) (variant "JoinClause" (ConPos))) ())
(DData Public "GraphMarks" () ((variant "GraphMarks" (ConNamed (field "mGoals" (TyCon "Int")) (field "mNumlit" (TyCon "Int"))))) ())
(DData Public "AssumptionTraceKind" () ((variant "ATDirectPredicate" (ConPos)) (variant "ATLegacyScalar" (ConPos)) (variant "ATSuperclassProjection" (ConPos)) (variant "ATLegacyPredicate" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AssumptionTraceKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ATDirectPredicate") (PCon "ATDirectPredicate")) () (EVar "True")) (arm (PTuple (PCon "ATLegacyScalar") (PCon "ATLegacyScalar")) () (EVar "True")) (arm (PTuple (PCon "ATSuperclassProjection") (PCon "ATSuperclassProjection")) () (EVar "True")) (arm (PTuple (PCon "ATLegacyPredicate") (PCon "ATLegacyPredicate")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AssumptionTraceKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ATDirectPredicate") () (ELit (LString "ATDirectPredicate"))) (arm (PCon "ATLegacyScalar") () (ELit (LString "ATLegacyScalar"))) (arm (PCon "ATSuperclassProjection") () (ELit (LString "ATSuperclassProjection"))) (arm (PCon "ATLegacyPredicate") () (ELit (LString "ATLegacyPredicate")))))))
(DData Public "AssumptionTraceEntry" () ((variant "AssumptionTraceEntry" (ConNamed (field "atGoalScope" (TyCon "ScopeId")) (field "atBinder" (TyCon "EvidenceBinderId")) (field "atKind" (TyCon "AssumptionTraceKind"))))) ())
(DData Public "NumericPredicateTraceStage" () ((variant "NPTProduced" (ConPos)) (variant "NPTChecked" (ConPos)) (variant "NPTReturn" (ConPos)) (variant "NPTArithmetic" (ConPos))) ())
(DImpl true "Eq" ((TyCon "NumericPredicateTraceStage")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NPTProduced") (PCon "NPTProduced")) () (EVar "True")) (arm (PTuple (PCon "NPTChecked") (PCon "NPTChecked")) () (EVar "True")) (arm (PTuple (PCon "NPTReturn") (PCon "NPTReturn")) () (EVar "True")) (arm (PTuple (PCon "NPTArithmetic") (PCon "NPTArithmetic")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NumericPredicateTraceStage")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NPTProduced") () (ELit (LString "NPTProduced"))) (arm (PCon "NPTChecked") () (ELit (LString "NPTChecked"))) (arm (PCon "NPTReturn") () (ELit (LString "NPTReturn"))) (arm (PCon "NPTArithmetic") () (ELit (LString "NPTArithmetic")))))))
(DData Public "NumericPredicateTraceEntry" () ((variant "NumericPredicateTraceEntry" (ConNamed (field "nptStage" (TyCon "NumericPredicateTraceStage")) (field "nptPredicate" (TyCon "ClassPredicate")) (field "nptScope" (TyCon "ScopeId")) (field "nptOrigin" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "nptSelectedInterface" (TyApp (TyCon "Option") (TyCon "IfaceRef"))) (field "nptRoute" (TyApp (TyCon "Option") (TyCon "Route"))) (field "nptPrerequisites" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "MethodReturnTraceStage" () ((variant "MRTProduced" (ConPos)) (variant "MRTChecked" (ConPos)) (variant "MRTStamped" (ConPos))) ())
(DImpl true "Eq" ((TyCon "MethodReturnTraceStage")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MRTProduced") (PCon "MRTProduced")) () (EVar "True")) (arm (PTuple (PCon "MRTChecked") (PCon "MRTChecked")) () (EVar "True")) (arm (PTuple (PCon "MRTStamped") (PCon "MRTStamped")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "MethodReturnTraceStage")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MRTProduced") () (ELit (LString "MRTProduced"))) (arm (PCon "MRTChecked") () (ELit (LString "MRTChecked"))) (arm (PCon "MRTStamped") () (ELit (LString "MRTStamped")))))))
(DData Public "MethodReturnTraceEntry" () ((variant "MethodReturnTraceEntry" (ConNamed (field "mrtStage" (TyCon "MethodReturnTraceStage")) (field "mrtInterface" (TyCon "IfaceRef")) (field "mrtMethod" (TyCon "String")) (field "mrtArguments" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))) (field "mrtScope" (TyCon "ScopeId")) (field "mrtOrigin" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "mrtGoal" (TyApp (TyCon "Option") (TyCon "EvId"))) (field "mrtPublished" (TyApp (TyCon "Option") (TyCon "EvVal"))) (field "mrtQualifiedBody" (TyApp (TyCon "Option") (TyCon "Mono"))) (field "mrtWanted" (TyApp (TyCon "Option") (TyCon "Wanted"))) (field "mrtOutcome" (TyApp (TyCon "Option") (TyCon "SolverOutcome"))) (field "mrtRoute" (TyApp (TyCon "Option") (TyCon "Route"))) (field "mrtPrerequisites" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "MethodReturnMemoView" () ((variant "MethodReturnMemoView" (ConNamed (field "mrmvInterface" (TyCon "String")) (field "mrmvMethod" (TyCon "String")) (field "mrmvArguments" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))) (field "mrmvOutcome" (TyCon "String")) (field "mrmvPrerequisites" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "mrmvEvidence" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "MethodReturnMemoView")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__a0")) (rf "mrmvMethod" (PVar "__a1")) (rf "mrmvArguments" (PVar "__a2")) (rf "mrmvOutcome" (PVar "__a3")) (rf "mrmvPrerequisites" (PVar "__a4")) (rf "mrmvEvidence" (PVar "__a5"))) false) (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__b0")) (rf "mrmvMethod" (PVar "__b1")) (rf "mrmvArguments" (PVar "__b2")) (rf "mrmvOutcome" (PVar "__b3")) (rf "mrmvPrerequisites" (PVar "__b4")) (rf "mrmvEvidence" (PVar "__b5"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))))))))
(DImpl true "Debug" ((TyCon "MethodReturnMemoView")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__a0")) (rf "mrmvMethod" (PVar "__a1")) (rf "mrmvArguments" (PVar "__a2")) (rf "mrmvOutcome" (PVar "__a3")) (rf "mrmvPrerequisites" (PVar "__a4")) (rf "mrmvEvidence" (PVar "__a5"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodReturnMemoView {")) (ELit (LString " mrmvInterface = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", mrmvMethod = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", mrmvArguments = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", mrmvOutcome = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", mrmvPrerequisites = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString ", mrmvEvidence = "))) (EApp (EVar "debug") (EVar "__a5"))) (ELit (LString " }"))))))))
(DData Public "EvidenceOutcomeKind" () ((variant "EOKGiven" (ConPos)) (variant "EOKInstance" (ConPos)) (variant "EOKLocal" (ConPos)) (variant "EOKScalar" (ConPos)) (variant "EOKNone" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EvidenceOutcomeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EOKGiven") (PCon "EOKGiven")) () (EVar "True")) (arm (PTuple (PCon "EOKInstance") (PCon "EOKInstance")) () (EVar "True")) (arm (PTuple (PCon "EOKLocal") (PCon "EOKLocal")) () (EVar "True")) (arm (PTuple (PCon "EOKScalar") (PCon "EOKScalar")) () (EVar "True")) (arm (PTuple (PCon "EOKNone") (PCon "EOKNone")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvidenceOutcomeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EOKGiven") () (ELit (LString "EOKGiven"))) (arm (PCon "EOKInstance") () (ELit (LString "EOKInstance"))) (arm (PCon "EOKLocal") () (ELit (LString "EOKLocal"))) (arm (PCon "EOKScalar") () (ELit (LString "EOKScalar"))) (arm (PCon "EOKNone") () (ELit (LString "EOKNone")))))))
(DData Public "EvidenceObservationEntry" () ((variant "EvidenceObservationEntry" (ConNamed (field "eoeEv" (TyCon "EvId")) (field "eoeGoalKind" (TyCon "String")) (field "eoeSlot" (TyCon "Int")) (field "eoeArity" (TyCon "Int")) (field "eoePredicate" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoeOutcome" (TyCon "EvidenceOutcomeKind")) (field "eoeGivenBinder" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoeInstanceKey" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoePrerequisites" (TyApp (TyCon "List") (TyCon "String"))) (field "eoeScope" (TyCon "ScopeId"))))) ())
(DData Public "AssumAnswer" () ((variant "SemanticGiven" (ConPos (TyCon "SolverEvidence"))) (variant "LegacyScalar" (ConPos (TyCon "EvidenceBinderId"))) (variant "LegacyPredicate" (ConPos (TyCon "EvidenceBinderId"))) (variant "LegacyProjected" (ConPos (TyCon "EvidenceBinderId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Public "GivenEntry" () ((variant "GivenEntry" (ConNamed (field "geSlot" (TyCon "PredicateSlot")) (field "geBinder" (TyCon "EvidenceBinderId")) (field "geMatch" (TyCon "GivenMatch")) (field "geProvenance" (TyCon "GivenProvenance"))))) ())
(DData Public "GivenProvenance" () ((variant "DirectGiven" (ConPos)) (variant "ProjectedGiven" (ConPos (TyCon "EvidenceBinderId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "GivenProvenance")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DirectGiven") (PCon "DirectGiven")) () (EVar "True")) (arm (PTuple (PCon "ProjectedGiven" (PVar "__a0") (PVar "__a1")) (PCon "ProjectedGiven" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "GivenMatch" () ((variant "GMPredicate" (ConPos)) (variant "GMIdWitnessed" (ConPos))) ())
(DData Public "EvCell" () ((variant "EvCell" (ConNamed (field "ecId" (TyCon "EvId")) (field "ecIface" (TyApp (TyCon "Ref") (TyCon "String"))) (field "ecArity" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (field "ecTag" (TyApp (TyCon "Ref") (TyCon "Route"))) (field "ecImpl" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "ecMeth" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "ecLoc" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Loc")))) (field "ecName" (TyApp (TyCon "Ref") (TyCon "String"))) (field "ecInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "SiteCell" () ((variant "OpSite" (ConPos (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "LitSite" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "HeadSite" (ConPos (TyApp (TyCon "Ref") (TyCon "String"))))) ())
(DData Public "GraphRun" () ((variant "GraphRun" (ConNamed (field "tyvarCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "effvarCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "ctorExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "patternAuthIdsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "anyExistentialsRef" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "goals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Obligation")))) (field "numlitRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))))) (field "numlitN" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "activeDictVars" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))))) (field "gGiven" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "GivenEntry"))))) (field "moduleRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GraphMarks"))))) (field "stampCtxs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "StampCtx")))) (field "goalsN" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evBase" (TyCon "Int")) (field "evJudged" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evScopedJudged" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (field "evTable" (TyApp (TyCon "Ref") (TyCon "EvTable"))) (field "evCells" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))))) (field "siteCells" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyTuple (TyCon "EvId") (TyCon "SiteCell")))))) (field "scopeStore" (TyCon "ScopeStore")) (field "localAbs" (TyCon "LocalAbsState")) (field "grants" (TyCon "GrantState")) (field "binderPending" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PendingBinder")))) (field "binderRows" (TyApp (TyCon "Ref") (TyCon "BinderTypeTable"))) (field "liveRoots" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "liveNumRoots" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "liveNumGoals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "UObligation")))) (field "liveGoals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "LiveGoal"))))))) ())
(DData Public "Lineage" () ((variant "Lineage" (ConNamed (field "lnEvCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "lnLocalAbs" (TyCon "LocalAbsState")) (field "lnGrants" (TyCon "GrantState")) (field "lnTyvarHigh" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "lnEffvarHigh" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "Interners" () ((variant "Interners" (ConNamed (field "lineage" (TyCon "Lineage")) (field "externCatalog" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))))) ())
(DData Public "PendingBinder" () ((variant "PendingBinder" (ConPos (TyCon "BinderId") (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Bool")))) ())
(DData Public "GivenScope" () ((variant "GSPredicateOnly" (ConPos)) (variant "GSImplRequires" (ConPos))) ())
(DData Public "PendingJoin" () ((variant "PendingJoin" (ConNamed (field "pjResult" (TyCon "Mono")) (field "pjValues" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))) (field "pjLevel" (TyCon "Int")) (field "pjContext" (TyCon "JoinContext")) (field "pjCollector" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))))) ())
(DData Public "CheckRunSeed" () ((variant "CheckRunSeed" (ConNamed (field "crsOracle" (TyCon "Oracle")) (field "crsWarnings" (TyApp (TyCon "List") (TyCon "TcDiag")))))) ())
(DData Public "ModuleCtx" () ((variant "ModuleCtx" (ConNamed (field "mcCells" (TyCon "ModuleCells")) (field "mcGraph" (TyCon "GraphCtx")) (field "mcLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "ModuleCells" () ((variant "ModuleCells" (ConNamed (field "currentScope" (TyApp (TyCon "Ref") (TyCon "ScopeCursor"))) (field "admittedOccObls" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "curEffect" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow")))) (field "effectSummaries" (TyApp (TyCon "SummarySolver") (TyCon "ObligationSite"))) (field "pendingJoinsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PendingJoin")))) (field "fileValueFlows" (TyApp (TyCon "Windowed") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")))) (field "fileValueScopes" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono"))) (TyCon "Int"))))) (field "rigidEffvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "rigidAuthvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "effectSitesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Loc"))))))) (field "rowFailureReportedRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "typeErrorKeySetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "escapedExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "openedAuthvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "indexSubstitutedRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "extendedBindersRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "displayHiddenBindersRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "openedExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))) (field "openedExistentialsStackRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))) (field "recordByNameRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "RecordInfo")))) (field "fieldOwnersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "dataParamKindsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "dataParamNameIndexRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "dataParamPolarityRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (field "dataParamRowAtomsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (field "aliasTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))) (field "numLitFromIntAnchorRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow")))) (field "definerShadowNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "definerShadowSigsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Ty")))) (field "bodyImplEnvRef" (TyApp (TyCon "Ref") (TyCon "ImplEnv"))) (field "methodAliasEntriesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodEntry")))) (field "methodScopeCtxRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Int"))))) (field "methodScopeMemoRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodScope")))) (field "aliasMethodOriginsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "implObls" (TyApp (TyCon "Windowed") (TyCon "UObligation"))) (field "poisonedVars" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int")))) (field "deferrableVarIds" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "liveMemberMonosRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "quiescentGoalsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "GoalWindow") (TyCon "UObligation"))))) (field "heldLiveGoalsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "GoalWindow") (TyCon "UObligation"))))) (field "determinedRowsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "declaredSigVarIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "tupleCallCandidates" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))) (field "numlitVarLocs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))))) (field "patLitPending" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "patLitDeferred" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "matchChecksDeferred" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "numlitRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "wideLitRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "numlitUntainted" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))))) (field "numlitOpLocs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Loc")))) (field "numlitCtxTags" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "JoinContext"))))) (field "localBindRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))) (field "localSchemesOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Scheme"))))) (field "seedSchemesOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (field "funPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "funPredicateSlotsIdxRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "funConstraintDeclaredRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix"))))) (field "currentImportDefinersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "currentImportOriginsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "importedSchemeOblsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "obls" (TyApp (TyCon "Windowed") (TyCon "UObligation"))) (field "absorptions" (TyApp (TyCon "Windowed") (TyCon "AbsorptionEvent"))) (field "schemeObligationsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))))) (field "schemeDefIdsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int")))) (field "methodPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "currentFn" (TyApp (TyCon "Ref") (TyCon "String"))) (field "currentImplBody" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "methodSiteFns" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Mono"))))) (field "dictAppFns" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))) (field "residualUnivRef" (TyApp (TyCon "Ref") (TyCon "ImplUniverse"))) (field "promotedRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "fieldOwnerModulesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "fieldOwnerReachRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "typeErrors" (TyApp (TyCon "Windowed") (TyCon "TcDiag"))) (field "typeErrorMsgSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "ambiguitySitesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool")))) (field "ambiguityVarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "errorsDetected" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "occursCheckFailed" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "currentLevel" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "markingRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ModuleMarking")))) (field "superDeclsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Decl")))) (field "standaloneValuesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "methodDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "matchOracle" (TyApp (TyCon "Ref") (TyCon "Oracle"))) (field "matchWarnings" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "TcDiag")))) (field "sigNameSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "sigTyMapRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Ty")))) (field "currentModuleRef" (TyApp (TyCon "Ref") (TyCon "String"))) (field "invocationViewRef" (TyApp (TyCon "Ref") (TyCon "InvocationView"))) (field "ownPopsRef" (TyApp (TyCon "Ref") (TyTuple (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")))))))) ())
(DData Public "ReqWalk" () ((variant "ReqWalk" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int"))) (TyCon "Int") (TyCon "WalkMemo")))) ())
(DData Public "WalkMemo" () ((variant "WalkMemo" (ConNamed (field "wmRoutes" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "RouteWalkEntry"))))) (field "wmDischarged" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "wmCuts" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "wmSolved" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SolvedGoalEntry"))))) (field "wmFollowed" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "wmStopped" (TyApp (TyCon "Ref") (TyCon "Bool")))))) ())
(DData Public "SolvedGoalEntry" () ((variant "SolvedGoalEntry" (ConNamed (field "sgeIface" (TyCon "IfaceRef")) (field "sgeGoals" (TyApp (TyCon "List") (TyCon "Mono"))) (field "sgeResiduals" (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))) ())
(DData Public "RouteWalkEntry" () ((variant "RouteWalkEntry" (ConNamed (field "rweIface" (TyCon "IfaceRef")) (field "rweGoals" (TyApp (TyCon "List") (TyCon "Mono"))) (field "rweRow" (TyCon "ImplRow")) (field "rweEncl" (TyCon "String")) (field "rweScope" (TyCon "ScopeId")) (field "rweRoutes" (TyApp (TyCon "List") (TyCon "Route"))) (field "rweInner" (TyCon "Inner"))))) ())
(DData Public "ReqStep" () ((variant "ReqOn" (ConPos (TyCon "ReqWalk"))) (variant "ReqCycle" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "ReqDeep" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) ())
(DData Public "PublishedInvocationView" () ((variant "PublishedInvocationView" (ConPos (TyApp (TyCon "List") (TyCon "PubScheme")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))) ())
(DData Public "InvocationView" () ((variant "InvocationView" (ConPos (TyApp (TyCon "List") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))) ())
(DData Public "SigVars" () ((variant "SigVars" (ConNamed (field "svRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "svAuths" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))) ())
(DData Public "StandaloneOrigin" () ((variant "LocalStandalone" (ConPos)) (variant "ImportedStandalone" (ConPos))) ())
(DData Public "ValueScheme" () ((variant "ValueScheme" (ConNamed (field "vsScheme" (TyCon "Scheme")) (field "vsDeclared" (TyApp (TyCon "Option") (TyCon "CDeclared")))))) ())
(DData Public "EnvBinding" () ((variant "EnvBinding" (ConNamed (field "ebValue" (TyCon "ValueScheme")) (field "ebMethodRow" (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))) (field "ebStandalone" (TyApp (TyCon "Option") (TyTuple (TyCon "StandaloneOrigin") (TyCon "ValueScheme"))))))) ())
(DData Public "TcEnv" () ((variant "TcEnv" (ConNamed (field "teVars" (TyApp (TyCon "OrdMap") (TyCon "EnvBinding"))) (field "teCtors" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "teAlphaLets" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder")))) (field "teIsLocal" (TyApp (TyCon "OrdMap") (TyCon "Bool"))) (field "teDyn" (TyCon "DynCtx"))))) ())
(DData Public "DoCtx" () ((variant "DoCtx" (ConNamed (field "doLoc" (TyCon "Loc")) (field "doDeferred" (TyCon "Bool")) (field "doReported" (TyApp (TyCon "Ref") (TyCon "Bool")))))) ())
(DData Public "GroupCtx" () ((variant "GroupCtx" (ConNamed (field "gcMonos" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "gcPendingEscapes" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))) ())
(DData Public "DynCtx" () ((variant "DynCtx" (ConNamed (field "dcJoin" (TyApp (TyCon "Option") (TyCon "JoinContext"))) (field "dcNonCovariant" (TyCon "Bool")) (field "dcSuppressRLocalRecord" (TyCon "Bool")) (field "dcSuppressArgStamp" (TyCon "Bool")) (field "dcShadowHeadCtx" (TyCon "Bool")) (field "dcDo" (TyApp (TyCon "Option") (TyCon "DoCtx"))) (field "dcMethodMismatch" (TyApp (TyCon "Option") (TyCon "String"))) (field "dcCallee" (TyApp (TyCon "Option") (TyCon "String"))) (field "dcGroup" (TyApp (TyCon "Option") (TyCon "GroupCtx"))) (field "dcPerformSites" (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Option") (TyCon "Loc"))))))) (field "dcModule" (TyCon "ModuleCtx"))))) ())
(DTypeSig true "dynFor" (TyFun (TyCon "ModuleCtx") (TyCon "DynCtx")))
(DFunDef false "dynFor" ((PVar "mctx")) (ERecordCreate "DynCtx" ((fa "dcJoin" (EVar "None")) (fa "dcNonCovariant" (EVar "False")) (fa "dcSuppressRLocalRecord" (EVar "False")) (fa "dcSuppressArgStamp" (EVar "False")) (fa "dcShadowHeadCtx" (EVar "False")) (fa "dcDo" (EVar "None")) (fa "dcMethodMismatch" (EVar "None")) (fa "dcCallee" (EVar "None")) (fa "dcGroup" (EVar "None")) (fa "dcPerformSites" (EVar "None")) (fa "dcModule" (EVar "mctx")))))
(DData Public "SiteCtx" () ((variant "SiteCtx" (ConNamed (field "sxSite" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "sxInner" (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Inner")))) (field "sxModule" (TyCon "ModuleCtx"))))) ())
(DTypeSig true "siteFor" (TyFun (TyCon "ModuleCtx") (TyCon "SiteCtx")))
(DFunDef false "siteFor" ((PVar "mctx")) (ERecordCreate "SiteCtx" ((fa "sxSite" (EVar "None")) (fa "sxInner" (EVar "None")) (fa "sxModule" (EVar "mctx")))))
(DData Public "LocalAbs" () ((variant "LocalAbs" (ConNamed (field "laScope" (TyCon "ScopeId")) (field "laSlots" (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (field "laParams" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "LocalAbsState" () ((variant "LocalAbsState" (ConNamed (field "lasBinders" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "Option") (TyCon "LocalAbs"))))) (field "lasRecOccs" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EvId") (TyCon "ScopeId")))))) (field "lasNext" (TyApp (TyCon "Ref") (TyTuple (TyCon "String") (TyCon "Int")))) (field "lasMinted" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "lasQuantified" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "GrantBinder" () ((variant "TopGrantBinder" (ConPos (TyCon "String") (TyCon "String"))) (variant "LocalGrantBinder" (ConPos (TyCon "String"))) (variant "BodyGrantBinder" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Public "GrantOcc" () ((variant "GrantOcc" (ConNamed (field "goCallee" (TyCon "String")) (field "goCells" (TyApp (TyCon "List") (TyCon "Authority"))) (field "goRecIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "goTrailing" (TyApp (TyCon "Option") (TyCon "Int"))) (field "goChain" (TyApp (TyCon "List") (TyCon "GrantBinder"))) (field "goStandalone" (TyCon "Bool"))))) ())
(DData Public "MethodGrant" () ((variant "MethodGrant" (ConNamed (field "mgArity" (TyCon "Int")) (field "mgNames" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "GrantCallee" () ((variant "SourceCallee" (ConPos)) (variant "FileExternCallee" (ConPos)) (variant "NoGrantCallee" (ConPos))) ())
(DData Public "GrantState" () ((variant "GrantState" (ConNamed (field "gsOccs" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "GrantOcc")))) (field "gsGrantOnly" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "gsTopIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))))) (field "gsLocalIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))))) (field "gsMethods" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodGrant")))) (field "gsBodies" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "GrantBinder")))) (field "gsLastInst" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsLastMethodInst" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsLastStandalone" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsSourceless" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "gsTakers" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "gsFresh" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "gsBounds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "gsValueBounds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "gsPassingModule" (TyApp (TyCon "Ref") (TyCon "String")))))) ())
(DTypeSig true "grantTopKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "grantTopKey" ((PVar "mid") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "|"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig true "setGrantIds" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "Unit"))))
(DFunDef false "setGrantIds" ((PVar "table") (PTuple (PVar "key") (PList))) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EVar "omDelete") (EVar "key")) (EFieldAccess (EVar "table") "value"))))
(DFunDef false "setGrantIds" ((PVar "table") (PTuple (PVar "key") (PVar "ids"))) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ids")) (EFieldAccess (EVar "table") "value"))))
(DTypeSig true "methodGrantKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "methodGrantKey" ((PVar "ifaceWord") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))
(DData Public "CtorFieldConflict" () ((variant "CtorWithholds" (ConPos (TyCon "String"))) (variant "CtorSlotsDiffer" (ConPos (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "Int"))) (variant "CtorTypesDiffer" (ConPos (TyCon "String") (TyCon "Mono") (TyCon "String") (TyCon "Mono")))) ())
(DData Public "BuiltinClass" () ((variant "BNum" (ConPos)) (variant "BEq" (ConPos)) (variant "BOrd" (ConPos)) (variant "BSemigroup" (ConPos))) ())
(DData Public "BuiltinClasses" () ((variant "BuiltinClasses" (ConNamed (field "bcNum" (TyCon "TyConOrigin")) (field "bcEq" (TyCon "TyConOrigin")) (field "bcOrd" (TyCon "TyConOrigin")) (field "bcSemigroup" (TyCon "TyConOrigin")) (field "bcNumPresent" (TyCon "Bool")) (field "bcEqPresent" (TyCon "Bool")) (field "bcOrdPresent" (TyCon "Bool")) (field "bcSemigroupPresent" (TyCon "Bool")) (field "bcPreludeSeeded" (TyCon "Bool"))))) ())
(DData Public "AdmittedAnswer" () ((variant "Selects" (ConPos (TyCon "IfaceRef") (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "SelectsNothing" (ConPos)) (variant "Undecided" (ConPos)) (variant "Unroutable" (ConPos (TyCon "IfaceRef")))) ())
(DData Public "SelectedValueOccurrence" () ((variant "SelectedValueOccurrence" (ConNamed (field "svoScheme" (TyCon "Scheme")) (field "svoInstance" (TyCon "MethodTrackedInstantiation")) (field "svoDicts" (TyCon "ShadowDicts"))))) ())
(DData Public "ExistentialScope" () ((variant "ExistentialScope" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Int")))) ())
(DData Public "RecordSubst" () ((variant "RecordSubst" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))))) ())
(DData Public "NumBoundaryDisposition" () ((variant "NumBoundaryOwnedMember" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedGroup" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedScc" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedMethodBody" (ConPos (TyCon "Int")))) ())
(DData Public "NumBoundary" () ((variant "NumBoundary" (ConNamed (field "nbDisposition" (TyCon "NumBoundaryDisposition")) (field "nbMembers" (TyApp (TyCon "List") (TyCon "Mono"))) (field "nbSurvivingIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "nbDefaultObls" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "nbAmbiguityObls" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "nbGuard" (TyCon "NumGuard"))))) ())
(DData Public "NumGuard" () ((variant "NumGuard" (ConNamed (field "ngGoals" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "ngRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ngOuterBelow" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DData Public "ArmedGuard" () ((variant "ArmedGuard" (ConNamed (field "agWindow" (TyCon "GoalWindow")) (field "agRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "agOuterBelow" (TyApp (TyCon "Option") (TyCon "Int"))) (field "agWithheld" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ArgRw" () ((variant "ArgRw" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Bool"))))) ())
(DData Public "AdmittedVerdict" () ((variant "AdDefer" (ConPos)) (variant "AdStandalone" (ConPos)) (variant "AdReject" (ConPos (TyApp (TyCon "List") (TyCon "IfaceRef"))))) ())
(DData Public "MethodTemplateGivenResult" () ((variant "MethodTemplateGivenNone" (ConPos)) (variant "MethodTemplateGivenOne" (ConPos (TyCon "GivenEntry"))) (variant "MethodTemplateGivenMany" (ConPos))) ())
(DData Public "CohImpl" () ((variant "CohImpl" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "MStep" ("k" "g" "s") ((variant "MVar" (ConPos (TyVar "k"))) (variant "MKids" (ConPos (TyApp (TyCon "List") (TyTuple (TyVar "g") (TyVar "s"))))) (variant "MOk" (ConPos)) (variant "MFail" (ConPos))) ())
(DData Public "CohScan" () ((variant "CohScan" (ConPos (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))) ())
(DData Public "CohSweep" () ((variant "CohSweepOwn" (ConPos)) (variant "CohSweepGlobal" (ConPos))) ())
(DData Public "KeyEntry" () ((variant "KeyEntry" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "Ty") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Int")))) ())
(DData Public "Undetermined" () ((variant "KeepNone" (ConPos)) (variant "CountImpls" (ConPos (TyCon "IfaceRef"))) (variant "CommitSuper" (ConPos))) ())
(DData Public "EntailKind" () ((variant "EKReturn" (ConPos (TyCon "Mono") (TyCon "Bool"))) (variant "EKNumReturn" (ConPos (TyCon "ClassPredicate") (TyCon "Mono") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "EKNestedTop" (ConPos (TyCon "IfaceRef") (TyCon "Undetermined") (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "EKArg" (ConPos (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "EKOp" (ConPos (TyCon "Bool") (TyCon "Bool"))) (variant "EKPredicateOp" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "ClassPredicate")))) ())
(DData Public "MethodGrantUse" () ((variant "MethodGrants" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "LeadingGrants" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "NoGrants" (ConPos))) ())
(DData Public "ImplUniverse" () ((variant "ImplUniverse" (ConPos (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))) ())
(DData Public "GoalReach" () ((variant "ReachNone" (ConPos)) (variant "ReachOne" (ConPos (TyCon "ImplRow"))) (variant "ReachMany" (ConPos))) ())
(DData Public "LiveGoal" () ((variant "LiveGoal" (ConNamed (field "lgModule" (TyCon "String")) (field "lgBinding" (TyCon "Int")) (field "lgRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "lgWindow" (TyCon "GoalWindow")) (field "lgGoal" (TyCon "UObligation"))))) ())
(DData Public "GoalWindow" () ((variant "GoalWindow" (ConNamed (field "gwGoals" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "UObligation")))) (field "gwByIndex" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "UObligation"))) (field "gwByVar" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))) ())
(DData Public "DeclaringBinder" () ((variant "DeclaredBySignature" (ConPos)) (variant "DeclaredByAnnotation" (ConPos))) ())
(DData Public "SuperGoalEntry" () ((variant "SuperGoalEntry" (ConNamed (field "sgWalk" (TyCon "ReqWalk")) (field "sgIface" (TyCon "IfaceRef")) (field "sgArgs" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "ScopedImplMethod" () ((variant "ScopedImplMethod" (ConNamed (field "simMethod" (TyCon "ImplMethod")) (field "simScope" (TyCon "ScopeId"))))) ())
(DData Public "MethodBodyKind" () ((variant "ImplBody" (ConPos (TyCon "ImplBodySite"))) (variant "DefaultBody" (ConPos))) ())
(DData Public "ImplBodySite" () ((variant "ImplBodySite" (ConNamed (field "ibImplTvMap" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "ibHeadMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "ibRequires" (TyApp (TyCon "List") (TyCon "Require"))) (field "ibScope" (TyCon "ScopeId"))))) ())
(DData Public "MethodBodyInstance" () ((variant "MethodBodyInstance" (ConNamed (field "mbiExpected" (TyCon "Mono")) (field "mbiContractForce" (TyCon "EffRow")) (field "mbiCheckedForce" (TyFun (TyCon "Unit") (TyCon "EffRow"))) (field "mbiEffVars" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "mbiSurvivors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mbiNamedVars" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mbiDictSlots" (TyApp (TyCon "List") (TyCon "Int"))) (field "mbiTypeSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))) ())
(DData Public "MethodBodyCheck" () ((variant "MethodBodyCheck" (ConNamed (field "mbcLaunderFlagged" (TyCon "Bool")) (field "mbcEagerIndexed" (TyApp (TyCon "List") (TyCon "String"))) (field "mbcPerformedAt" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "HeadVarRoot" () ((variant "TypeVarRoot" (ConPos (TyCon "Int"))) (variant "RowVarRoot" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "HeadVarRoot")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TypeVarRoot" (PVar "__a0")) (PCon "TypeVarRoot" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "RowVarRoot" (PVar "__a0")) (PCon "RowVarRoot" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ScopedMember" () ((variant "ScopedMember" (ConNamed (field "smName" (TyCon "String")) (field "smMono" (TyCon "Mono")) (field "smOwned" (TyCon "BindingSummary")) (field "smDeclaredRoots" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "smDeclaredAuths" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "smSigned" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "smRecursive" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EnvBinding")))) (field "smForce" (TyApp (TyCon "Option") (TyCon "EffRow"))) (field "smForceBound" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EffRow")))) (field "smScope" (TyCon "ScopeId"))))) ())
(DData Public "ConstraintReg" () ((variant "ConstraintReg" (ConNamed (field "crName" (TyCon "String")) (field "crScope" (TyCon "ScopeId")) (field "crIfaceMonos" (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (field "crArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ScopedScheme" () ((variant "ScopedScheme" (ConNamed (field "ssName" (TyCon "String")) (field "ssScheme" (TyCon "Scheme")) (field "ssScope" (TyCon "ScopeId"))))) ())
(DData Public "BindingRole" () ((variant "RoleQuantifies" (ConPos)) (variant "RoleMonomorphic" (ConPos)) (variant "RoleDeclared" (ConPos))) ())
(DData Public "ModuleBindings" () ((variant "ModuleBindings" (ConNamed (field "mbSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "mbStandaloneSchemes" (TyApp (TyCon "OrdMap") (TyCon "Scheme")))))) ())
(DData Public "ExportBinding" () ((variant "ExportBinding" (ConNamed (field "xbScheme" (TyCon "Scheme")) (field "xbStandalone" (TyApp (TyCon "Option") (TyCon "Scheme"))) (field "xbExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleSeed" () ((variant "ModuleSeed" (ConNamed (field "msSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "msImportedValues" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "msImportedNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "msImportedExterns" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "PreludePreamble" () ((variant "PreludePreamble" (ConNamed (field "ppEnvAcc" (TyCon "DeclEnvAcc")) (field "ppMangledFunDefs" (TyCon "Bool")) (field "ppMarkFacts" (TyCon "PreludeMarkFacts"))))) ())
(DData Public "GraphOut" () ((variant "GOutDiags" (ConPos)) (variant "GOutTrees" (ConPos))) ())
(DData Public "ModuleServe" ("e") ((variant "ModuleServe" (ConNamed (field "msServed" (TyCon "Int")) (field "msFrozen" (TyCon "Int")) (field "msStep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "ServeStep") (TyVar "e"))))))))) ())
(DData Public "ServeStep" ("e") ((variant "ServeHit" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyVar "e") (TyApp (TyCon "ModuleServe") (TyVar "e")))) (variant "ServeCheck" (ConPos (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyApp (TyCon "ModuleServe") (TyVar "e")))))))))) ())
(DData Public "GraphDrive" () ((variant "GraphDrive" (ConNamed (field "gdPerMod" (TyApp (TyCon "List") (TyCon "ModDiags"))) (field "gdCoreSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "gdCoreContexts" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))) (field "gdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "gdModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "gdResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "gdEvTable" (TyCon "EvTable")) (field "gdDispositions" (TyCon "DispositionTable")) (field "gdBinders" (TyCon "BinderTypeTable")) (field "gdReport" (TyCon "TcReport")) (field "gdGraph" (TyCon "GraphCtx")) (field "gdOutputs" (TyCon "DriveOutputs"))))) ())
(DData Public "ElabFacts" () ((variant "ElabFacts" (ConNamed (field "efManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "efBinders" (TyCon "BinderTypeTable")) (field "efEntryOutcome" (TyCon "EntryOutcome"))))) ())
(DData Public "ElabResult" () ((variant "ElabResult" (ConNamed (field "erCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "erModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "erPerModule" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))) (field "erResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "erEvidence" (TyCon "EvTable")) (field "erDispositions" (TyCon "DispositionTable")) (field "erFacts" (TyCon "ElabFacts"))))) ())
(DData Public "MarkCtx" () ((variant "MarkCtx" (ConNamed (field "mcRp" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mcAn" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mcSm" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "SpellCtx" () ((variant "SpellCtx" (ConNamed (field "scTopFns" (TyApp (TyCon "List") (TyCon "String"))) (field "scBare" (TyCon "BareLocals")) (field "scCorePfx" (TyCon "String"))))) ())
(DData Public "BareLocals" () ((variant "BareLocals" (ConNamed (field "blAll" (TyCon "Bool")) (field "blSet" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "StampStep" () ((variant "SSNumlitFloats" (ConPos)) (variant "SSReturnSites" (ConPos)) (variant "SSBinopSites" (ConPos)) (variant "SSUnopSites" (ConPos)) (variant "SSArithSites" (ConPos)) (variant "SSArgStamps" (ConPos)) (variant "SSRLocalSites" (ConPos)) (variant "SSRecDictApps" (ConPos)) (variant "SSDictApps" (ConPos)) (variant "SSMethodDicts" (ConPos))) ())
(DData Public "StampCtx" () ((variant "StampCtx" (ConNamed (field "scModule" (TyCon "String")) (field "scModuleCtx" (TyCon "ModuleCtx")) (field "scRpNames" (TyApp (TyCon "List") (TyCon "String"))) (field "scGoals" (TyApp (TyCon "List") (TyCon "Obligation"))) (field "scNumlits" (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route"))))) (field "scLiveLocs" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "DrainFinding" () ((variant "DrainFinding" (ConNamed (field "dfModule" (TyCon "String")) (field "dfDiag" (TyCon "TcDiag")) (field "dfVerdict" (TyCon "Bool")) (field "dfLive" (TyCon "Bool"))))) ())
(DData Public "MarkSets" () ((variant "MarkSets" (ConNamed (field "msMarkRpNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msMarkSharedNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msGraphShadowNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msArgNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msCoreShadowMap" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "msBareDictNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msUnits" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "GraphPreamble" () ((variant "GraphPreamble" (ConNamed (field "gpRuntimeSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "gpCoreSchemes" (TyCon "ModuleBindings")) (field "gpCorePub" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (field "gpCoreContexts" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))) (field "gpCoreTree" (TyApp (TyCon "List") (TyCon "Decl"))) (field "gpMarkSets" (TyCon "MarkSets")) (field "gpCoreCtx" (TyCon "ModuleCtx"))))) ())
(DData Public "PreludeMarkFacts" () ((variant "PreludeMarkFacts" (ConNamed (field "pmfReturnPos" (TyApp (TyCon "List") (TyCon "String"))) (field "pmfMethodConstraints" (TyApp (TyCon "List") (TyCon "String"))) (field "pmfArgDispatch" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "pmfArgDispatchById" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "pmfConstrainedNames" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ModuleMarking" () ((variant "ModuleMarking" (ConNamed (field "mmCtx" (TyCon "MarkCtx")) (field "mmTop" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "mmDictSet" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "mmUserNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mmExterns" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "PassEvidence" () ((variant "PassEvidence" (ConPos (TyCon "EvIndex") (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "EvVal")))))) ())
(DData Public "PassMethod" () ((variant "PassMethod" (ConPos (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))) ())
(DData Public "Accumulate" () ((variant "AccumulateNone" (ConPos)) (variant "AccumulateBoth" (ConPos))) ())
(DData Public "ModulePlace" () ((variant "LastModule" (ConPos)) (variant "NotLastModule" (ConPos))) ())
(DData Public "FoldPlan" ("e" "acc") ((variant "FoldPlan" (ConNamed (field "fpAccumulate" (TyCon "Accumulate")) (field "fpWorker" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyVar "e") (TyCon "ModuleCtx"))))))))) (field "fpCollect" (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyVar "e") (TyFun (TyVar "acc") (TyVar "acc")))))) (field "fpBaseSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "fpCoreV" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))) ())
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Ident" true) (mem "Route" true) (mem "EvId" true) (mem "EvVal" true) (mem "EvTable" false) (mem "Arm" true) (mem "Expr" true) (mem "Loc" true) (mem "Field" true) (mem "Variant" true) (mem "Require" true) (mem "Super" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Decl" true) (mem "TabKey" true) (mem "EffParamTy" true))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omInsert" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true) (mem "Atom" true) (mem "EffRow" true) (mem "Effvar" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "AlphaBinder" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "SummarySolver" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true) (mem "SolverEvidence" true))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true) (mem "SolverOutcome" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "registry") ((mem "RegKey" false) (mem "Registry" false) (mem "HeadKey" true) (mem "MultiRegistry" false) (mem "SpellingPop" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeCursor" true) (mem "ScopeStore" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "ModDiags" false) (mem "PubScheme" true) (mem "TcReport" false) (mem "EntryOutcome" false) (mem "noEntryOutcome" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" false) (mem "ManifestRequest" false) (mem "CapabilityManifest" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false))))
(DData Public "ObligationSite" () ((variant "ObligationSite" (ConNamed (field "osLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "osFn" (TyCon "String")) (field "osCovering" (TyCon "Bool"))))) ())
(DData Public "RecordInfo" () ((variant "RecordInfo" (ConPos (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "OrdMap") (TyCon "Mono"))))) ())
(DData Public "Kind" () ((variant "KType" (ConPos)) (variant "KRow" (ConPos)) (variant "KAuth" (ConPos (TyCon "EffLabel") (TyCon "Bool")))) ())
(DData Public "Polarity" () ((variant "PCo" (ConPos)) (variant "PContra" (ConPos)) (variant "PInv" (ConPos)) (variant "PPhantom" (ConPos))) ())
(DData Public "SiteKind" () ((variant "SKReturn" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono"))) (variant "SKAdmittedReturn" (ConPos (TyApp (TyCon "Ref") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono"))) (variant "SKExactReturn" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "MethodReturnRequest"))) (variant "SKNumReturn" (ConPos (TyCon "ClassPredicate") (TyCon "Mono"))) (variant "SKArg" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "SKOp" (ConPos (TyCon "Bool"))) (variant "SKPredicateOp" (ConPos (TyCon "Bool") (TyCon "ClassPredicate"))) (variant "SKRLocal" (ConPos (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "PendingEntry" () ((variant "PendingEntry" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono") (TyCon "String") (TyCon "SiteKind") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "ScopeId") (TyCon "EvId")))) ())
(DData Public "GoalKind" () ((variant "GKReturnSite" (ConPos)) (variant "GKArgStamp" (ConPos)) (variant "GKRLocalSite" (ConPos)) (variant "GKBinopSite" (ConPos)) (variant "GKUnopSite" (ConPos)) (variant "GKArithSite" (ConPos)) (variant "GKDictApp" (ConPos)) (variant "GKMethodDict" (ConPos)) (variant "GKRecDictApp" (ConPos))) ())
(DData Public "EvDest" () ((variant "EvRoute" (ConPos (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EvRoutes" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "GoalPayload" () ((variant "GPSite" (ConPos (TyCon "String") (TyCon "Mono") (TyCon "SiteKind"))) (variant "GPArith" (ConPos (TyCon "Mono"))) (variant "GPDictApp" (ConPos (TyCon "PendingDictApp"))) (variant "GPMethodDict" (ConPos (TyCon "PendingMethodDict"))) (variant "GPRecDictApp" (ConPos (TyCon "RecDictApp")))) ())
(DData Public "Obligation" () ((variant "Obligation" (ConNamed (field "oKind" (TyCon "GoalKind")) (field "oDest" (TyCon "EvDest")) (field "oEv" (TyCon "EvId")) (field "oEncl" (TyCon "String")) (field "oLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "oScope" (TyCon "ScopeId")) (field "oPayload" (TyCon "GoalPayload")) (field "oInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "DeclEnvModule" () ((variant "DeclEnvModule" (ConNamed (field "demOrd" (TyCon "Int")) (field "demId" (TyCon "String")) (field "demDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "demPubDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "demKindEntries" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))) (field "demSiblingOrd" (TyCon "Int"))))) ())
(DData Public "DeclEnvs" () ((variant "DeclEnvs" (ConNamed (field "deModules" (TyApp (TyCon "List") (TyCon "DeclEnvModule"))) (field "deOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "deDefiners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))) (field "deAmbigValues" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "deAllDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "deData" (TyCon "DataEnv")) (field "deImpls" (TyCon "ImplEnv")) (field "deIfaces" (TyCon "ClassEnv")) (field "deMethods" (TyCon "MethodEnv")) (field "deKindsBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "deNameIndexBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "dePolaritiesBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (field "deAtomsBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (field "deOwnersBefore" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "deOwnerModules" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "deReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "DeclEnvAcc" () ((variant "DeclEnvAcc" (ConNamed (field "daOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "daDefiners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))) (field "daAmbig" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "daData" (TyCon "DataEnv")) (field "daImpls" (TyCon "ImplAcc")) (field "daIfaces" (TyCon "ClassEnv")) (field "daMethods" (TyCon "MethodEnv")) (field "daSeeds" (TyCon "DeclEnvSeedAcc")) (field "daPolarity" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity"))))))) (field "daOwnerModules" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DData Public "DeclEnvSeedAcc" () ((variant "DeclEnvSeedAcc" (ConNamed (field "dsKAcc" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))) (field "dsOAcc" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "dsNAcc" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "dsKinds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "dsOwners" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "dsNames" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "DataTypeDecl" () ((variant "DataTypeDecl" (ConNamed (field "dtKey" (TyCon "TabKey")) (field "dtName" (TyCon "String")) (field "dtOrigin" (TyCon "TyConOrigin")) (field "dtParams" (TyApp (TyCon "List") (TyCon "String"))) (field "dtVariants" (TyApp (TyCon "List") (TyCon "Variant")))))) ())
(DData Public "AliasDecl" () ((variant "AliasDecl" (ConNamed (field "adKey" (TyCon "TabKey")) (field "adName" (TyCon "String")) (field "adParams" (TyApp (TyCon "List") (TyCon "String"))) (field "adRhs" (TyCon "Ty")) (field "adOrd" (TyCon "Int")) (field "adPub" (TyCon "Bool")) (field "adAttrib" (TyCon "Bool"))))) ())
(DData Public "DataEnv" () ((variant "DataEnv" (ConNamed (field "deTypes" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "DataTypeDecl")))) (field "deCtorIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Variant"))))) (field "deRecordIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyApp (TyCon "List") (TyCon "Field")))))) (field "deFieldOwnerIdents" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String"))))) (field "deAliases" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl")))) (field "deCtorExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))) ())
(DData Public "InstRef" () ((variant "InstRef" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "ImplRow" () ((variant "ImplRow" (ConPos (TyCon "Int") (TyCon "InstRef") (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ImplEnv" () ((variant "ImplEnv" (ConNamed (field "ieRows" (TyApp (TyCon "List") (TyCon "ImplRow"))) (field "ieConcrete" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieHeadless" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieByHead" (TyApp (TyCon "MultiRegistry") (TyCon "ImplRow"))) (field "ieUnivSnaps" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))))))) ())
(DData Public "ImplAcc" () ((variant "ImplAcc" (ConNamed (field "iaEnv" (TyCon "ImplEnv")) (field "iaSeq" (TyCon "Int")) (field "iaSnaps" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))) ())
(DData Public "CeRow" () ((variant "CeRow" (ConPos (TyCon "RegKey") (TyCon "Int") (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ClassEnv" () ((variant "ClassEnv" (ConNamed (field "ceRows" (TyApp (TyCon "List") (TyCon "CeRow"))) (field "ceByKey" (TyApp (TyCon "Registry") (TyCon "CeRow")))))) ())
(DTypeAlias true "MethodEntry" () (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))
(DData Public "MethodRow" () ((variant "MethodRow" (ConNamed (field "mrIdent" (TyCon "Ident")) (field "mrOrd" (TyCon "Int")) (field "mrIface" (TyCon "RegKey")) (field "mrEntry" (TyCon "MethodEntry"))))) ())
(DData Public "MethodEnv" () ((variant "MethodEnv" (ConNamed (field "meByName" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow")))) (field "meExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))) (field "meIfaceExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))) ())
(DData Public "MethodScope" () ((variant "MsAbsent" (ConPos)) (variant "MsOne" (ConPos (TyCon "MethodRow"))) (variant "MsMany" (ConPos (TyApp (TyCon "List") (TyCon "IfaceRef"))))) ())
(DData Public "GraphCtx" () ((variant "GraphCtx" (ConNamed (field "crossRun" (TyCon "CrossRun")) (field "graphRun" (TyCon "GraphRun")) (field "effectDomains" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))) (field "config" (TyApp (TyCon "Ref") (TyCon "TcConfig"))) (field "trace" (TyApp (TyCon "Option") (TyCon "TraceSink"))) (field "graphAdmittedMethodsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) (field "declEnvsRef" (TyApp (TyCon "Ref") (TyCon "DeclEnvs"))) (field "abstractRecordTypesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "argDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "dictEligibleRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "dictEligibleSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "mangledShadowMapRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (field "mangledFunDefsPresentRef" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "builtinExternNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))) (field "promotionHarvestRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "mainSchemeRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Scheme")))) (field "markSetsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MarkSets")))) (field "typeErrorsSticky" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "typeErrorsStickyDiags" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))) ())
(DData Public "TcConfig" () ((variant "TcConfig" (ConNamed (field "tcIoJoin" (TyApp (TyCon "List") (TyCon "Atom"))) (field "tcIoJoinProfile" (TyCon "String")) (field "tcStdlibOwned" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "tcFlatEntryIsStdlib" (TyCon "Bool")) (field "tcKey" (TyCon "String")) (field "tcSibling" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "TraceSink" () ((variant "TraceSink" (ConNamed (field "tsAssumptionEnabled" (TyCon "Bool")) (field "tsAssumptionEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "AssumptionTraceEntry")))) (field "tsNumericPredicateEnabled" (TyCon "Bool")) (field "tsNumericPredicateEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "NumericPredicateTraceEntry")))) (field "tsMethodReturnEnabled" (TyCon "Bool")) (field "tsMethodReturnEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "MethodReturnTraceEntry")))) (field "tsEvidenceObservationEnabled" (TyCon "Bool")) (field "tsEvidenceObservationEntries" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))) ())
(DData Public "DriveInputs" () ((variant "DriveInputs" (ConNamed (field "diExecutedMainDriver" (TyApp (TyCon "Option") (TyCon "EntryKey"))) (field "diManifestRequests" (TyApp (TyCon "List") (TyCon "ManifestSelector"))) (field "diStdlibOwned" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "diFlatEntryIsStdlib" (TyCon "Bool")) (field "diTrace" (TyApp (TyCon "Option") (TyCon "TraceSink"))) (field "diIoJoinGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))) (field "diProfileName" (TyCon "String")) (field "diPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "diSibling" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "DriveArgs" () ((variant "DriveArgs" (ConNamed (field "daInputs" (TyCon "DriveInputs")) (field "daValueMain" (TyCon "Bool")) (field "daExecutes" (TyApp (TyCon "Option") (TyCon "String"))) (field "daPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "daKeyed" (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))) (field "daRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "daCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "daModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "DriveOutputs" () ((variant "DriveOutputs" (ConNamed (field "doManifestRequests" (TyApp (TyCon "List") (TyCon "ManifestRequest"))) (field "doManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "doEntryOutcome" (TyCon "EntryOutcome")) (field "doHadTypeErrors" (TyCon "Bool")) (field "doHadMatchWarnings" (TyCon "Bool")) (field "doInvocationView" (TyCon "InvocationView")) (field "doGrantsEnabled" (TyCon "Bool")) (field "doEffectDomains" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))) (field "doStickyDiags" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "doIfaceExports" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (field "doFfiAliases" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl")))) (field "doOrdIndex" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "doEffvarNext" (TyCon "Int")) (field "doServedModules" (TyCon "Int"))))) ())
(DTypeSig true "emptyDriveOutputs" (TyFun (TyCon "Unit") (TyCon "DriveOutputs")))
(DFunDef false "emptyDriveOutputs" (PWild) (ERecordCreate "DriveOutputs" ((fa "doManifestRequests" (EListLit)) (fa "doManifests" (EListLit)) (fa "doEntryOutcome" (EVar "noEntryOutcome")) (fa "doHadTypeErrors" (EVar "False")) (fa "doHadMatchWarnings" (EVar "False")) (fa "doInvocationView" (EApp (EApp (EApp (EVar "InvocationView") (EListLit)) (EListLit)) (EListLit))) (fa "doGrantsEnabled" (EVar "False")) (fa "doEffectDomains" (EListLit)) (fa "doStickyDiags" (EListLit)) (fa "doIfaceExports" (EVar "omEmpty")) (fa "doFfiAliases" (EListLit)) (fa "doOrdIndex" (EVar "omEmpty")) (fa "doEffvarNext" (ELit (LInt 0))) (fa "doServedModules" (ELit (LInt 0))))))
(DTypeSig true "withPublishedManifests" (TyFun (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyFun (TyCon "DriveOutputs") (TyCon "DriveOutputs")))))
(DFunDef false "withPublishedManifests" ((PVar "requests") (PVar "manifests") (PVar "outputs")) (ERecordUpdate (EVar "outputs") ((fa "doManifestRequests" (EVar "requests")) (fa "doManifests" (EVar "manifests")))))
(DTypeSig true "manifestDriverFor" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "EntryKey")))))
(DFunDef false "manifestDriverFor" (PWild (PCon "Some" (PVar "name"))) (EApp (EVar "Some") (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (EVar "name"))))))
(DFunDef false "manifestDriverFor" ((PVar "inputs") (PCon "None")) (EFieldAccess (EVar "inputs") "diExecutedMainDriver"))
(DData Public "Windowed" ("a") ((variant "Windowed" (ConNamed (field "items" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyVar "a")))) (field "n" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "CSlot" () ((variant "CSlot" (ConNamed (field "csIface" (TyCon "IfaceRef")) (field "csId" (TyCon "Int"))))) ())
(DData Public "PredicateSlotArgs" () ((variant "PSArgsUnknown" (ConPos)) (variant "PSArgsKnown" (ConPos (TyApp (TyCon "List") (TyCon "Mono"))))) ())
(DData Public "PredicateRequest" () ((variant "PredicateRequest" (ConNamed (field "prIface" (TyCon "IfaceRef")) (field "prArgs" (TyCon "PredicateSlotArgs"))))) ())
(DData Public "PredicateSlot" () ((variant "PredicateSlot" (ConNamed (field "psIface" (TyCon "IfaceRef")) (field "psArgs" (TyCon "PredicateSlotArgs")) (field "psBoundIds" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "MethodPredicateSlot" () ((variant "MethodPredicateSlot" (ConNamed (field "mpsPredicate" (TyCon "PredicateSlot")) (field "mpsPositions" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "MethodPredicateTemplate" () ((variant "MethodPredicateTemplate" (ConNamed (field "mptInterface" (TyCon "IfaceRef")) (field "mptArguments" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))))))) ())
(DData Public "MethodSchemeRow" () ((variant "MethodSchemeRow" (ConNamed (field "msrIface" (TyCon "IfaceRef")) (field "msrName" (TyCon "String")) (field "msrTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "msrType" (TyCon "Ty")) (field "msrScheme" (TyCon "Scheme")) (field "msrPredicateTemplate" (TyCon "MethodPredicateTemplate")) (field "msrMethodSlots" (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) ())
(DData Public "MethodInstantiationSubst" () ((variant "MethodInstantiationSubst" (ConNamed (field "misTypeSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (field "misEffectSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "misAuthSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) ())
(DData Public "MethodTrackedInstantiation" () ((variant "MethodTrackedInstantiation" (ConNamed (field "mtiBody" (TyCon "Mono")) (field "mtiForce" (TyCon "EffRow")) (field "mtiResidual" (TyApp (TyCon "List") (TyCon "AuthResidual"))) (field "mtiSubstitution" (TyCon "MethodInstantiationSubst"))))) ())
(DData Public "MethodReturnResolution" () ((variant "MethodReturnResolution" (ConNamed (field "mrrWanted" (TyCon "Wanted")) (field "mrrOutcome" (TyCon "SolverOutcome")) (field "mrrSelectedRow" (TyApp (TyCon "Option") (TyCon "ImplRow")))))) ())
(DData Public "MethodReturnRequest" () ((variant "MethodReturnRequest" (ConNamed (field "mrrIface" (TyCon "IfaceRef")) (field "mrrName" (TyCon "String")) (field "mrrTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "mrrType" (TyCon "Ty")) (field "mrrOccurrence" (TyCon "Mono")) (field "mrrEnclosing" (TyCon "String")) (field "mrrLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "mrrScope" (TyCon "ScopeId")) (field "mrrGoalEv" (TyApp (TyCon "Option") (TyCon "EvId"))) (field "mrrQualifiedBody" (TyCon "Mono")) (field "mrrPredicateTemplate" (TyCon "MethodPredicateTemplate")) (field "mrrOmitted" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mrrResolution" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MethodReturnResolution"))))))) ())
(DData Public "NumAnchorTestObservation" () ((variant "NumAnchorTestObservation" (ConNamed (field "natoCase" (TyCon "String")) (field "natoHasRow" (TyCon "Bool")) (field "natoIface" (TyCon "String")) (field "natoSchemeBody" (TyCon "String")) (field "natoDeclaredType" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "NumAnchorTestObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__a0")) (rf "natoHasRow" (PVar "__a1")) (rf "natoIface" (PVar "__a2")) (rf "natoSchemeBody" (PVar "__a3")) (rf "natoDeclaredType" (PVar "__a4"))) false) (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__b0")) (rf "natoHasRow" (PVar "__b1")) (rf "natoIface" (PVar "__b2")) (rf "natoSchemeBody" (PVar "__b3")) (rf "natoDeclaredType" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "NumAnchorTestObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "NumAnchorTestObservation" ((rf "natoCase" (PVar "__a0")) (rf "natoHasRow" (PVar "__a1")) (rf "natoIface" (PVar "__a2")) (rf "natoSchemeBody" (PVar "__a3")) (rf "natoDeclaredType" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "NumAnchorTestObservation {")) (ELit (LString " natoCase = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", natoHasRow = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", natoIface = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", natoSchemeBody = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", natoDeclaredType = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "MethodRowTestObservation" () ((variant "MethodRowTestObservation" (ConNamed (field "mrtoSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoSlotBoundIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotPositions" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotIdsAtPositions" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSlotArgumentIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoCounterBefore" (TyCon "Int")) (field "mrtoCounterAfterFirst" (TyCon "Int")) (field "mrtoCounterAfterSecond" (TyCon "Int")) (field "mrtoFirstSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoSecondSchemeIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "mrtoFirstRowSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSecondRowSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoRegistryAfterSecondSlotIds" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrtoSameNameForward" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) (field "mrtoSameNameReverse" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) (field "mrtoConstantRowCount" (TyCon "Int")) (field "mrtoConstantSchemeIdCount" (TyCon "Int")) (field "mrtoConstantBodyIsFunction" (TyCon "Bool")) (field "mrtoConstantSlotCount" (TyCon "Int")) (field "mrtoAttributedRowCount" (TyCon "Int")) (field "mrtoAttributedParamIface" (TyCon "String")) (field "mrtoAttributedParamTyparams" (TyApp (TyCon "List") (TyCon "String"))) (field "mrtoNumAnchors" (TyApp (TyCon "List") (TyCon "NumAnchorTestObservation")))))) ())
(DImpl true "Eq" ((TyCon "MethodRowTestObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__a0")) (rf "mrtoSlotBoundIds" (PVar "__a1")) (rf "mrtoSlotPositions" (PVar "__a2")) (rf "mrtoSlotIdsAtPositions" (PVar "__a3")) (rf "mrtoSlotArgumentIds" (PVar "__a4")) (rf "mrtoCounterBefore" (PVar "__a5")) (rf "mrtoCounterAfterFirst" (PVar "__a6")) (rf "mrtoCounterAfterSecond" (PVar "__a7")) (rf "mrtoFirstSchemeIds" (PVar "__a8")) (rf "mrtoSecondSchemeIds" (PVar "__a9")) (rf "mrtoFirstRowSlotIds" (PVar "__a10")) (rf "mrtoSecondRowSlotIds" (PVar "__a11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__a12")) (rf "mrtoSameNameForward" (PVar "__a13")) (rf "mrtoSameNameReverse" (PVar "__a14")) (rf "mrtoConstantRowCount" (PVar "__a15")) (rf "mrtoConstantSchemeIdCount" (PVar "__a16")) (rf "mrtoConstantBodyIsFunction" (PVar "__a17")) (rf "mrtoConstantSlotCount" (PVar "__a18")) (rf "mrtoAttributedRowCount" (PVar "__a19")) (rf "mrtoAttributedParamIface" (PVar "__a20")) (rf "mrtoAttributedParamTyparams" (PVar "__a21")) (rf "mrtoNumAnchors" (PVar "__a22"))) false) (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__b0")) (rf "mrtoSlotBoundIds" (PVar "__b1")) (rf "mrtoSlotPositions" (PVar "__b2")) (rf "mrtoSlotIdsAtPositions" (PVar "__b3")) (rf "mrtoSlotArgumentIds" (PVar "__b4")) (rf "mrtoCounterBefore" (PVar "__b5")) (rf "mrtoCounterAfterFirst" (PVar "__b6")) (rf "mrtoCounterAfterSecond" (PVar "__b7")) (rf "mrtoFirstSchemeIds" (PVar "__b8")) (rf "mrtoSecondSchemeIds" (PVar "__b9")) (rf "mrtoFirstRowSlotIds" (PVar "__b10")) (rf "mrtoSecondRowSlotIds" (PVar "__b11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__b12")) (rf "mrtoSameNameForward" (PVar "__b13")) (rf "mrtoSameNameReverse" (PVar "__b14")) (rf "mrtoConstantRowCount" (PVar "__b15")) (rf "mrtoConstantSchemeIdCount" (PVar "__b16")) (rf "mrtoConstantBodyIsFunction" (PVar "__b17")) (rf "mrtoConstantSlotCount" (PVar "__b18")) (rf "mrtoAttributedRowCount" (PVar "__b19")) (rf "mrtoAttributedParamIface" (PVar "__b20")) (rf "mrtoAttributedParamTyparams" (PVar "__b21")) (rf "mrtoNumAnchors" (PVar "__b22"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EMethodRef "eq") (EVar "__a6")) (EVar "__b6"))) (EApp (EApp (EMethodRef "eq") (EVar "__a7")) (EVar "__b7"))) (EApp (EApp (EMethodRef "eq") (EVar "__a8")) (EVar "__b8"))) (EApp (EApp (EMethodRef "eq") (EVar "__a9")) (EVar "__b9"))) (EApp (EApp (EMethodRef "eq") (EVar "__a10")) (EVar "__b10"))) (EApp (EApp (EMethodRef "eq") (EVar "__a11")) (EVar "__b11"))) (EApp (EApp (EMethodRef "eq") (EVar "__a12")) (EVar "__b12"))) (EApp (EApp (EMethodRef "eq") (EVar "__a13")) (EVar "__b13"))) (EApp (EApp (EMethodRef "eq") (EVar "__a14")) (EVar "__b14"))) (EApp (EApp (EMethodRef "eq") (EVar "__a15")) (EVar "__b15"))) (EApp (EApp (EMethodRef "eq") (EVar "__a16")) (EVar "__b16"))) (EApp (EApp (EMethodRef "eq") (EVar "__a17")) (EVar "__b17"))) (EApp (EApp (EMethodRef "eq") (EVar "__a18")) (EVar "__b18"))) (EApp (EApp (EMethodRef "eq") (EVar "__a19")) (EVar "__b19"))) (EApp (EApp (EMethodRef "eq") (EVar "__a20")) (EVar "__b20"))) (EApp (EApp (EMethodRef "eq") (EVar "__a21")) (EVar "__b21"))) (EApp (EApp (EMethodRef "eq") (EVar "__a22")) (EVar "__b22"))))))))
(DImpl true "Debug" ((TyCon "MethodRowTestObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodRowTestObservation" ((rf "mrtoSchemeIds" (PVar "__a0")) (rf "mrtoSlotBoundIds" (PVar "__a1")) (rf "mrtoSlotPositions" (PVar "__a2")) (rf "mrtoSlotIdsAtPositions" (PVar "__a3")) (rf "mrtoSlotArgumentIds" (PVar "__a4")) (rf "mrtoCounterBefore" (PVar "__a5")) (rf "mrtoCounterAfterFirst" (PVar "__a6")) (rf "mrtoCounterAfterSecond" (PVar "__a7")) (rf "mrtoFirstSchemeIds" (PVar "__a8")) (rf "mrtoSecondSchemeIds" (PVar "__a9")) (rf "mrtoFirstRowSlotIds" (PVar "__a10")) (rf "mrtoSecondRowSlotIds" (PVar "__a11")) (rf "mrtoRegistryAfterSecondSlotIds" (PVar "__a12")) (rf "mrtoSameNameForward" (PVar "__a13")) (rf "mrtoSameNameReverse" (PVar "__a14")) (rf "mrtoConstantRowCount" (PVar "__a15")) (rf "mrtoConstantSchemeIdCount" (PVar "__a16")) (rf "mrtoConstantBodyIsFunction" (PVar "__a17")) (rf "mrtoConstantSlotCount" (PVar "__a18")) (rf "mrtoAttributedRowCount" (PVar "__a19")) (rf "mrtoAttributedParamIface" (PVar "__a20")) (rf "mrtoAttributedParamTyparams" (PVar "__a21")) (rf "mrtoNumAnchors" (PVar "__a22"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodRowTestObservation {")) (ELit (LString " mrtoSchemeIds = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", mrtoSlotBoundIds = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", mrtoSlotPositions = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", mrtoSlotIdsAtPositions = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", mrtoSlotArgumentIds = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString ", mrtoCounterBefore = "))) (EApp (EMethodRef "debug") (EVar "__a5"))) (ELit (LString ", mrtoCounterAfterFirst = "))) (EApp (EMethodRef "debug") (EVar "__a6"))) (ELit (LString ", mrtoCounterAfterSecond = "))) (EApp (EMethodRef "debug") (EVar "__a7"))) (ELit (LString ", mrtoFirstSchemeIds = "))) (EApp (EMethodRef "debug") (EVar "__a8"))) (ELit (LString ", mrtoSecondSchemeIds = "))) (EApp (EMethodRef "debug") (EVar "__a9"))) (ELit (LString ", mrtoFirstRowSlotIds = "))) (EApp (EMethodRef "debug") (EVar "__a10"))) (ELit (LString ", mrtoSecondRowSlotIds = "))) (EApp (EMethodRef "debug") (EVar "__a11"))) (ELit (LString ", mrtoRegistryAfterSecondSlotIds = "))) (EApp (EMethodRef "debug") (EVar "__a12"))) (ELit (LString ", mrtoSameNameForward = "))) (EApp (EMethodRef "debug") (EVar "__a13"))) (ELit (LString ", mrtoSameNameReverse = "))) (EApp (EMethodRef "debug") (EVar "__a14"))) (ELit (LString ", mrtoConstantRowCount = "))) (EApp (EMethodRef "debug") (EVar "__a15"))) (ELit (LString ", mrtoConstantSchemeIdCount = "))) (EApp (EMethodRef "debug") (EVar "__a16"))) (ELit (LString ", mrtoConstantBodyIsFunction = "))) (EApp (EMethodRef "debug") (EVar "__a17"))) (ELit (LString ", mrtoConstantSlotCount = "))) (EApp (EMethodRef "debug") (EVar "__a18"))) (ELit (LString ", mrtoAttributedRowCount = "))) (EApp (EMethodRef "debug") (EVar "__a19"))) (ELit (LString ", mrtoAttributedParamIface = "))) (EApp (EMethodRef "debug") (EVar "__a20"))) (ELit (LString ", mrtoAttributedParamTyparams = "))) (EApp (EMethodRef "debug") (EVar "__a21"))) (ELit (LString ", mrtoNumAnchors = "))) (EApp (EMethodRef "debug") (EVar "__a22"))) (ELit (LString " }"))))))))
(DData Public "CDeclaredPrefix" () ((variant "CDPUnknown" (ConPos)) (variant "CDPLen" (ConPos (TyCon "Int")))) ())
(DData Public "CDeclared" () ((variant "CDeclared" (ConNamed (field "cdSlots" (TyApp (TyCon "List") (TyCon "CSlot"))) (field "cdPrefix" (TyCon "CDeclaredPrefix")) (field "cdArgs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ShadowDicts" () ((variant "ShadowDicts" (ConNamed (field "sdMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "sdIfaces" (TyApp (TyCon "List") (TyCon "IfaceRef"))) (field "sdArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "Predicate" () ((variant "Predicate" (ConNamed (field "iface" (TyCon "IfaceRef")) (field "args" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "Provenance" () ((variant "POperator" (ConPos)) (variant "PNumLit" (ConPos)) (variant "PMethodOcc" (ConPos)) (variant "PCallSlot" (ConPos)) (variant "PSchemeReinst" (ConPos)) (variant "PMethodLevel" (ConPos))) ())
(DData Public "OblProjection" () ((variant "OpProjected" (ConPos)) (variant "OpMethodOcc" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "OpExactReturn" (ConPos (TyCon "MethodReturnRequest"))) (variant "OpNumLit" (ConPos (TyCon "Mono")))) ())
(DData Public "UObligation" () ((variant "UObligation" (ConNamed (field "pred" (TyCon "Predicate")) (field "originId" (TyCon "Int")) (field "prov" (TyCon "Provenance")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "uoScope" (TyCon "ScopeId")) (field "oblProj" (TyCon "OblProjection"))))) ())
(DData Public "AbsorptionEvent" () ((variant "AbsorptionEvent" (ConNamed (field "atom" (TyCon "Atom")) (field "cell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "PendingDictApp" () ((variant "PendingDictApp" (ConNamed (field "pdaRoutesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "pdaEv" (TyCon "EvId")) (field "pdaMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "pdaIfaces" (TyApp (TyCon "List") (TyCon "IfaceRef"))) (field "pdaArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))) (field "pdaEncl" (TyCon "String")) (field "pdaLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "pdaScope" (TyCon "ScopeId")) (field "pdaCallee" (TyCon "String"))))) ())
(DData Public "PendingMethodDict" () ((variant "PendingMethodDict" (ConNamed (field "pmdRoutesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "pmdEv" (TyCon "EvId")) (field "pmdSlots" (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (field "pmdEncl" (TyCon "String")) (field "pmdScope" (TyCon "ScopeId")) (field "pmdInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "CrossRun" () ((variant "CrossRun" (ConNamed (field "universeFunNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "universeMethodDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "universeDataCtors" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))))) (field "universeCtorPop" (TyApp (TyCon "Ref") (TyApp (TyCon "SpellingPop") (TyCon "Scheme")))) (field "universeRecordPop" (TyApp (TyCon "Ref") (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")))) (field "builtinClassesRef" (TyApp (TyCon "Ref") (TyCon "BuiltinClasses"))) (field "crossModuleFunPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "crossModuleFunPredicateSlotsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "crossModuleFunConstraintDeclaredRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix"))))) (field "crossModuleFunConstraintDeclaredQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix"))))) (field "crossModuleMethodPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "crossModuleMethodPredicateSlotsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "coreSchemeObligationsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "crossModuleSchemeOblsQualRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))))))) ())
(DData Public "RecDictApp" () ((variant "RecDictApp" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "String") (TyCon "String") (TyCon "Mono") (TyCon "ScopeId") (TyCon "EvId")))) ())
(DData Public "JoinContext" () ((variant "JoinIf" (ConPos)) (variant "JoinElselessIf" (ConPos)) (variant "JoinList" (ConPos)) (variant "JoinCons" (ConPos)) (variant "JoinArray" (ConPos)) (variant "JoinMatch" (ConPos)) (variant "JoinArgument" (ConPos)) (variant "JoinClause" (ConPos))) ())
(DData Public "GraphMarks" () ((variant "GraphMarks" (ConNamed (field "mGoals" (TyCon "Int")) (field "mNumlit" (TyCon "Int"))))) ())
(DData Public "AssumptionTraceKind" () ((variant "ATDirectPredicate" (ConPos)) (variant "ATLegacyScalar" (ConPos)) (variant "ATSuperclassProjection" (ConPos)) (variant "ATLegacyPredicate" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AssumptionTraceKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ATDirectPredicate") (PCon "ATDirectPredicate")) () (EVar "True")) (arm (PTuple (PCon "ATLegacyScalar") (PCon "ATLegacyScalar")) () (EVar "True")) (arm (PTuple (PCon "ATSuperclassProjection") (PCon "ATSuperclassProjection")) () (EVar "True")) (arm (PTuple (PCon "ATLegacyPredicate") (PCon "ATLegacyPredicate")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AssumptionTraceKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ATDirectPredicate") () (ELit (LString "ATDirectPredicate"))) (arm (PCon "ATLegacyScalar") () (ELit (LString "ATLegacyScalar"))) (arm (PCon "ATSuperclassProjection") () (ELit (LString "ATSuperclassProjection"))) (arm (PCon "ATLegacyPredicate") () (ELit (LString "ATLegacyPredicate")))))))
(DData Public "AssumptionTraceEntry" () ((variant "AssumptionTraceEntry" (ConNamed (field "atGoalScope" (TyCon "ScopeId")) (field "atBinder" (TyCon "EvidenceBinderId")) (field "atKind" (TyCon "AssumptionTraceKind"))))) ())
(DData Public "NumericPredicateTraceStage" () ((variant "NPTProduced" (ConPos)) (variant "NPTChecked" (ConPos)) (variant "NPTReturn" (ConPos)) (variant "NPTArithmetic" (ConPos))) ())
(DImpl true "Eq" ((TyCon "NumericPredicateTraceStage")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NPTProduced") (PCon "NPTProduced")) () (EVar "True")) (arm (PTuple (PCon "NPTChecked") (PCon "NPTChecked")) () (EVar "True")) (arm (PTuple (PCon "NPTReturn") (PCon "NPTReturn")) () (EVar "True")) (arm (PTuple (PCon "NPTArithmetic") (PCon "NPTArithmetic")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NumericPredicateTraceStage")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NPTProduced") () (ELit (LString "NPTProduced"))) (arm (PCon "NPTChecked") () (ELit (LString "NPTChecked"))) (arm (PCon "NPTReturn") () (ELit (LString "NPTReturn"))) (arm (PCon "NPTArithmetic") () (ELit (LString "NPTArithmetic")))))))
(DData Public "NumericPredicateTraceEntry" () ((variant "NumericPredicateTraceEntry" (ConNamed (field "nptStage" (TyCon "NumericPredicateTraceStage")) (field "nptPredicate" (TyCon "ClassPredicate")) (field "nptScope" (TyCon "ScopeId")) (field "nptOrigin" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "nptSelectedInterface" (TyApp (TyCon "Option") (TyCon "IfaceRef"))) (field "nptRoute" (TyApp (TyCon "Option") (TyCon "Route"))) (field "nptPrerequisites" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "MethodReturnTraceStage" () ((variant "MRTProduced" (ConPos)) (variant "MRTChecked" (ConPos)) (variant "MRTStamped" (ConPos))) ())
(DImpl true "Eq" ((TyCon "MethodReturnTraceStage")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MRTProduced") (PCon "MRTProduced")) () (EVar "True")) (arm (PTuple (PCon "MRTChecked") (PCon "MRTChecked")) () (EVar "True")) (arm (PTuple (PCon "MRTStamped") (PCon "MRTStamped")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "MethodReturnTraceStage")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MRTProduced") () (ELit (LString "MRTProduced"))) (arm (PCon "MRTChecked") () (ELit (LString "MRTChecked"))) (arm (PCon "MRTStamped") () (ELit (LString "MRTStamped")))))))
(DData Public "MethodReturnTraceEntry" () ((variant "MethodReturnTraceEntry" (ConNamed (field "mrtStage" (TyCon "MethodReturnTraceStage")) (field "mrtInterface" (TyCon "IfaceRef")) (field "mrtMethod" (TyCon "String")) (field "mrtArguments" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))) (field "mrtScope" (TyCon "ScopeId")) (field "mrtOrigin" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "mrtGoal" (TyApp (TyCon "Option") (TyCon "EvId"))) (field "mrtPublished" (TyApp (TyCon "Option") (TyCon "EvVal"))) (field "mrtQualifiedBody" (TyApp (TyCon "Option") (TyCon "Mono"))) (field "mrtWanted" (TyApp (TyCon "Option") (TyCon "Wanted"))) (field "mrtOutcome" (TyApp (TyCon "Option") (TyCon "SolverOutcome"))) (field "mrtRoute" (TyApp (TyCon "Option") (TyCon "Route"))) (field "mrtPrerequisites" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DData Public "MethodReturnMemoView" () ((variant "MethodReturnMemoView" (ConNamed (field "mrmvInterface" (TyCon "String")) (field "mrmvMethod" (TyCon "String")) (field "mrmvArguments" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))) (field "mrmvOutcome" (TyCon "String")) (field "mrmvPrerequisites" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "mrmvEvidence" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "MethodReturnMemoView")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__a0")) (rf "mrmvMethod" (PVar "__a1")) (rf "mrmvArguments" (PVar "__a2")) (rf "mrmvOutcome" (PVar "__a3")) (rf "mrmvPrerequisites" (PVar "__a4")) (rf "mrmvEvidence" (PVar "__a5"))) false) (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__b0")) (rf "mrmvMethod" (PVar "__b1")) (rf "mrmvArguments" (PVar "__b2")) (rf "mrmvOutcome" (PVar "__b3")) (rf "mrmvPrerequisites" (PVar "__b4")) (rf "mrmvEvidence" (PVar "__b5"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))))))))
(DImpl true "Debug" ((TyCon "MethodReturnMemoView")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodReturnMemoView" ((rf "mrmvInterface" (PVar "__a0")) (rf "mrmvMethod" (PVar "__a1")) (rf "mrmvArguments" (PVar "__a2")) (rf "mrmvOutcome" (PVar "__a3")) (rf "mrmvPrerequisites" (PVar "__a4")) (rf "mrmvEvidence" (PVar "__a5"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodReturnMemoView {")) (ELit (LString " mrmvInterface = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", mrmvMethod = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", mrmvArguments = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", mrmvOutcome = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", mrmvPrerequisites = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString ", mrmvEvidence = "))) (EApp (EMethodRef "debug") (EVar "__a5"))) (ELit (LString " }"))))))))
(DData Public "EvidenceOutcomeKind" () ((variant "EOKGiven" (ConPos)) (variant "EOKInstance" (ConPos)) (variant "EOKLocal" (ConPos)) (variant "EOKScalar" (ConPos)) (variant "EOKNone" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EvidenceOutcomeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EOKGiven") (PCon "EOKGiven")) () (EVar "True")) (arm (PTuple (PCon "EOKInstance") (PCon "EOKInstance")) () (EVar "True")) (arm (PTuple (PCon "EOKLocal") (PCon "EOKLocal")) () (EVar "True")) (arm (PTuple (PCon "EOKScalar") (PCon "EOKScalar")) () (EVar "True")) (arm (PTuple (PCon "EOKNone") (PCon "EOKNone")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvidenceOutcomeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EOKGiven") () (ELit (LString "EOKGiven"))) (arm (PCon "EOKInstance") () (ELit (LString "EOKInstance"))) (arm (PCon "EOKLocal") () (ELit (LString "EOKLocal"))) (arm (PCon "EOKScalar") () (ELit (LString "EOKScalar"))) (arm (PCon "EOKNone") () (ELit (LString "EOKNone")))))))
(DData Public "EvidenceObservationEntry" () ((variant "EvidenceObservationEntry" (ConNamed (field "eoeEv" (TyCon "EvId")) (field "eoeGoalKind" (TyCon "String")) (field "eoeSlot" (TyCon "Int")) (field "eoeArity" (TyCon "Int")) (field "eoePredicate" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoeOutcome" (TyCon "EvidenceOutcomeKind")) (field "eoeGivenBinder" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoeInstanceKey" (TyApp (TyCon "Option") (TyCon "String"))) (field "eoePrerequisites" (TyApp (TyCon "List") (TyCon "String"))) (field "eoeScope" (TyCon "ScopeId"))))) ())
(DData Public "AssumAnswer" () ((variant "SemanticGiven" (ConPos (TyCon "SolverEvidence"))) (variant "LegacyScalar" (ConPos (TyCon "EvidenceBinderId"))) (variant "LegacyPredicate" (ConPos (TyCon "EvidenceBinderId"))) (variant "LegacyProjected" (ConPos (TyCon "EvidenceBinderId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Public "GivenEntry" () ((variant "GivenEntry" (ConNamed (field "geSlot" (TyCon "PredicateSlot")) (field "geBinder" (TyCon "EvidenceBinderId")) (field "geMatch" (TyCon "GivenMatch")) (field "geProvenance" (TyCon "GivenProvenance"))))) ())
(DData Public "GivenProvenance" () ((variant "DirectGiven" (ConPos)) (variant "ProjectedGiven" (ConPos (TyCon "EvidenceBinderId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "GivenProvenance")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DirectGiven") (PCon "DirectGiven")) () (EVar "True")) (arm (PTuple (PCon "ProjectedGiven" (PVar "__a0") (PVar "__a1")) (PCon "ProjectedGiven" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "GivenMatch" () ((variant "GMPredicate" (ConPos)) (variant "GMIdWitnessed" (ConPos))) ())
(DData Public "EvCell" () ((variant "EvCell" (ConNamed (field "ecId" (TyCon "EvId")) (field "ecIface" (TyApp (TyCon "Ref") (TyCon "String"))) (field "ecArity" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (field "ecTag" (TyApp (TyCon "Ref") (TyCon "Route"))) (field "ecImpl" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "ecMeth" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route")))) (field "ecLoc" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Loc")))) (field "ecName" (TyApp (TyCon "Ref") (TyCon "String"))) (field "ecInner" (TyApp (TyCon "Ref") (TyCon "Inner")))))) ())
(DData Public "SiteCell" () ((variant "OpSite" (ConPos (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "LitSite" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "HeadSite" (ConPos (TyApp (TyCon "Ref") (TyCon "String"))))) ())
(DData Public "GraphRun" () ((variant "GraphRun" (ConNamed (field "tyvarCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "effvarCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "ctorExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "patternAuthIdsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "anyExistentialsRef" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "goals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Obligation")))) (field "numlitRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))))) (field "numlitN" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "activeDictVars" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))))) (field "gGiven" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "GivenEntry"))))) (field "moduleRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GraphMarks"))))) (field "stampCtxs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "StampCtx")))) (field "goalsN" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evBase" (TyCon "Int")) (field "evJudged" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "evScopedJudged" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (field "evTable" (TyApp (TyCon "Ref") (TyCon "EvTable"))) (field "evCells" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))))) (field "siteCells" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyTuple (TyCon "EvId") (TyCon "SiteCell")))))) (field "scopeStore" (TyCon "ScopeStore")) (field "localAbs" (TyCon "LocalAbsState")) (field "grants" (TyCon "GrantState")) (field "binderPending" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PendingBinder")))) (field "binderRows" (TyApp (TyCon "Ref") (TyCon "BinderTypeTable"))) (field "liveRoots" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "liveNumRoots" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "liveNumGoals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "UObligation")))) (field "liveGoals" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "LiveGoal"))))))) ())
(DData Public "Lineage" () ((variant "Lineage" (ConNamed (field "lnEvCounter" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "lnLocalAbs" (TyCon "LocalAbsState")) (field "lnGrants" (TyCon "GrantState")) (field "lnTyvarHigh" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "lnEffvarHigh" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "Interners" () ((variant "Interners" (ConNamed (field "lineage" (TyCon "Lineage")) (field "externCatalog" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))))) ())
(DData Public "PendingBinder" () ((variant "PendingBinder" (ConPos (TyCon "BinderId") (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Bool")))) ())
(DData Public "GivenScope" () ((variant "GSPredicateOnly" (ConPos)) (variant "GSImplRequires" (ConPos))) ())
(DData Public "PendingJoin" () ((variant "PendingJoin" (ConNamed (field "pjResult" (TyCon "Mono")) (field "pjValues" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))) (field "pjLevel" (TyCon "Int")) (field "pjContext" (TyCon "JoinContext")) (field "pjCollector" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))))) ())
(DData Public "CheckRunSeed" () ((variant "CheckRunSeed" (ConNamed (field "crsOracle" (TyCon "Oracle")) (field "crsWarnings" (TyApp (TyCon "List") (TyCon "TcDiag")))))) ())
(DData Public "ModuleCtx" () ((variant "ModuleCtx" (ConNamed (field "mcCells" (TyCon "ModuleCells")) (field "mcGraph" (TyCon "GraphCtx")) (field "mcLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "ModuleCells" () ((variant "ModuleCells" (ConNamed (field "currentScope" (TyApp (TyCon "Ref") (TyCon "ScopeCursor"))) (field "admittedOccObls" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "curEffect" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow")))) (field "effectSummaries" (TyApp (TyCon "SummarySolver") (TyCon "ObligationSite"))) (field "pendingJoinsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PendingJoin")))) (field "fileValueFlows" (TyApp (TyCon "Windowed") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")))) (field "fileValueScopes" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono"))) (TyCon "Int"))))) (field "rigidEffvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "rigidAuthvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "effectSitesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Loc"))))))) (field "rowFailureReportedRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "typeErrorKeySetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "escapedExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "openedAuthvarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "indexSubstitutedRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "extendedBindersRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "displayHiddenBindersRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "openedExistentialsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))) (field "openedExistentialsStackRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))) (field "recordByNameRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "RecordInfo")))) (field "fieldOwnersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "dataParamKindsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))) (field "dataParamNameIndexRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "dataParamPolarityRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (field "dataParamRowAtomsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (field "aliasTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))) (field "numLitFromIntAnchorRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow")))) (field "definerShadowNamesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "definerShadowSigsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Ty")))) (field "bodyImplEnvRef" (TyApp (TyCon "Ref") (TyCon "ImplEnv"))) (field "methodAliasEntriesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodEntry")))) (field "methodScopeCtxRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Int"))))) (field "methodScopeMemoRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodScope")))) (field "aliasMethodOriginsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "implObls" (TyApp (TyCon "Windowed") (TyCon "UObligation"))) (field "poisonedVars" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int")))) (field "deferrableVarIds" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "liveMemberMonosRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono")))) (field "quiescentGoalsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "GoalWindow") (TyCon "UObligation"))))) (field "heldLiveGoalsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "GoalWindow") (TyCon "UObligation"))))) (field "determinedRowsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "declaredSigVarIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "tupleCallCandidates" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))) (field "numlitVarLocs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))))) (field "patLitPending" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "patLitDeferred" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "matchChecksDeferred" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "numlitRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "wideLitRanges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "numlitUntainted" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))))) (field "numlitOpLocs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Loc")))) (field "numlitCtxTags" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "JoinContext"))))) (field "localBindRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))) (field "localSchemesOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Scheme"))))) (field "seedSchemesOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (field "funPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))) (field "funPredicateSlotsIdxRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "funConstraintDeclaredRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix"))))) (field "currentImportDefinersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "currentImportOriginsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "String")))) (field "importedSchemeOblsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "obls" (TyApp (TyCon "Windowed") (TyCon "UObligation"))) (field "absorptions" (TyApp (TyCon "Windowed") (TyCon "AbsorptionEvent"))) (field "schemeObligationsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))))) (field "schemeDefIdsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int")))) (field "methodPredicateSlotsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))) (field "currentFn" (TyApp (TyCon "Ref") (TyCon "String"))) (field "currentImplBody" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "methodSiteFns" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Mono"))))) (field "dictAppFns" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))) (field "residualUnivRef" (TyApp (TyCon "Ref") (TyCon "ImplUniverse"))) (field "promotedRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "fieldOwnerModulesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))) (field "fieldOwnerReachRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "typeErrors" (TyApp (TyCon "Windowed") (TyCon "TcDiag"))) (field "typeErrorMsgSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "ambiguitySitesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool")))) (field "ambiguityVarsRef" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "errorsDetected" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "occursCheckFailed" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "currentLevel" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "markingRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ModuleMarking")))) (field "superDeclsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Decl")))) (field "standaloneValuesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "methodDispatchIdxByIdRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))))) (field "matchOracle" (TyApp (TyCon "Ref") (TyCon "Oracle"))) (field "matchWarnings" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "TcDiag")))) (field "sigNameSetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "sigTyMapRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Ty")))) (field "currentModuleRef" (TyApp (TyCon "Ref") (TyCon "String"))) (field "invocationViewRef" (TyApp (TyCon "Ref") (TyCon "InvocationView"))) (field "ownPopsRef" (TyApp (TyCon "Ref") (TyTuple (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")))))))) ())
(DData Public "ReqWalk" () ((variant "ReqWalk" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int"))) (TyCon "Int") (TyCon "WalkMemo")))) ())
(DData Public "WalkMemo" () ((variant "WalkMemo" (ConNamed (field "wmRoutes" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "RouteWalkEntry"))))) (field "wmDischarged" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "wmCuts" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "wmSolved" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SolvedGoalEntry"))))) (field "wmFollowed" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))) (field "wmStopped" (TyApp (TyCon "Ref") (TyCon "Bool")))))) ())
(DData Public "SolvedGoalEntry" () ((variant "SolvedGoalEntry" (ConNamed (field "sgeIface" (TyCon "IfaceRef")) (field "sgeGoals" (TyApp (TyCon "List") (TyCon "Mono"))) (field "sgeResiduals" (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))) ())
(DData Public "RouteWalkEntry" () ((variant "RouteWalkEntry" (ConNamed (field "rweIface" (TyCon "IfaceRef")) (field "rweGoals" (TyApp (TyCon "List") (TyCon "Mono"))) (field "rweRow" (TyCon "ImplRow")) (field "rweEncl" (TyCon "String")) (field "rweScope" (TyCon "ScopeId")) (field "rweRoutes" (TyApp (TyCon "List") (TyCon "Route"))) (field "rweInner" (TyCon "Inner"))))) ())
(DData Public "ReqStep" () ((variant "ReqOn" (ConPos (TyCon "ReqWalk"))) (variant "ReqCycle" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "ReqDeep" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) ())
(DData Public "PublishedInvocationView" () ((variant "PublishedInvocationView" (ConPos (TyApp (TyCon "List") (TyCon "PubScheme")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))) ())
(DData Public "InvocationView" () ((variant "InvocationView" (ConPos (TyApp (TyCon "List") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))) ())
(DData Public "SigVars" () ((variant "SigVars" (ConNamed (field "svRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "svAuths" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))) ())
(DData Public "StandaloneOrigin" () ((variant "LocalStandalone" (ConPos)) (variant "ImportedStandalone" (ConPos))) ())
(DData Public "ValueScheme" () ((variant "ValueScheme" (ConNamed (field "vsScheme" (TyCon "Scheme")) (field "vsDeclared" (TyApp (TyCon "Option") (TyCon "CDeclared")))))) ())
(DData Public "EnvBinding" () ((variant "EnvBinding" (ConNamed (field "ebValue" (TyCon "ValueScheme")) (field "ebMethodRow" (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))) (field "ebStandalone" (TyApp (TyCon "Option") (TyTuple (TyCon "StandaloneOrigin") (TyCon "ValueScheme"))))))) ())
(DData Public "TcEnv" () ((variant "TcEnv" (ConNamed (field "teVars" (TyApp (TyCon "OrdMap") (TyCon "EnvBinding"))) (field "teCtors" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "teAlphaLets" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder")))) (field "teIsLocal" (TyApp (TyCon "OrdMap") (TyCon "Bool"))) (field "teDyn" (TyCon "DynCtx"))))) ())
(DData Public "DoCtx" () ((variant "DoCtx" (ConNamed (field "doLoc" (TyCon "Loc")) (field "doDeferred" (TyCon "Bool")) (field "doReported" (TyApp (TyCon "Ref") (TyCon "Bool")))))) ())
(DData Public "GroupCtx" () ((variant "GroupCtx" (ConNamed (field "gcMonos" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "gcPendingEscapes" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))) ())
(DData Public "DynCtx" () ((variant "DynCtx" (ConNamed (field "dcJoin" (TyApp (TyCon "Option") (TyCon "JoinContext"))) (field "dcNonCovariant" (TyCon "Bool")) (field "dcSuppressRLocalRecord" (TyCon "Bool")) (field "dcSuppressArgStamp" (TyCon "Bool")) (field "dcShadowHeadCtx" (TyCon "Bool")) (field "dcDo" (TyApp (TyCon "Option") (TyCon "DoCtx"))) (field "dcMethodMismatch" (TyApp (TyCon "Option") (TyCon "String"))) (field "dcCallee" (TyApp (TyCon "Option") (TyCon "String"))) (field "dcGroup" (TyApp (TyCon "Option") (TyCon "GroupCtx"))) (field "dcPerformSites" (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Option") (TyCon "Loc"))))))) (field "dcModule" (TyCon "ModuleCtx"))))) ())
(DTypeSig true "dynFor" (TyFun (TyCon "ModuleCtx") (TyCon "DynCtx")))
(DFunDef false "dynFor" ((PVar "mctx")) (ERecordCreate "DynCtx" ((fa "dcJoin" (EVar "None")) (fa "dcNonCovariant" (EVar "False")) (fa "dcSuppressRLocalRecord" (EVar "False")) (fa "dcSuppressArgStamp" (EVar "False")) (fa "dcShadowHeadCtx" (EVar "False")) (fa "dcDo" (EVar "None")) (fa "dcMethodMismatch" (EVar "None")) (fa "dcCallee" (EVar "None")) (fa "dcGroup" (EVar "None")) (fa "dcPerformSites" (EVar "None")) (fa "dcModule" (EVar "mctx")))))
(DData Public "SiteCtx" () ((variant "SiteCtx" (ConNamed (field "sxSite" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "sxInner" (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Inner")))) (field "sxModule" (TyCon "ModuleCtx"))))) ())
(DTypeSig true "siteFor" (TyFun (TyCon "ModuleCtx") (TyCon "SiteCtx")))
(DFunDef false "siteFor" ((PVar "mctx")) (ERecordCreate "SiteCtx" ((fa "sxSite" (EVar "None")) (fa "sxInner" (EVar "None")) (fa "sxModule" (EVar "mctx")))))
(DData Public "LocalAbs" () ((variant "LocalAbs" (ConNamed (field "laScope" (TyCon "ScopeId")) (field "laSlots" (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (field "laParams" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "LocalAbsState" () ((variant "LocalAbsState" (ConNamed (field "lasBinders" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "Option") (TyCon "LocalAbs"))))) (field "lasRecOccs" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EvId") (TyCon "ScopeId")))))) (field "lasNext" (TyApp (TyCon "Ref") (TyTuple (TyCon "String") (TyCon "Int")))) (field "lasMinted" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String")))) (field "lasQuantified" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))) ())
(DData Public "GrantBinder" () ((variant "TopGrantBinder" (ConPos (TyCon "String") (TyCon "String"))) (variant "LocalGrantBinder" (ConPos (TyCon "String"))) (variant "BodyGrantBinder" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Public "GrantOcc" () ((variant "GrantOcc" (ConNamed (field "goCallee" (TyCon "String")) (field "goCells" (TyApp (TyCon "List") (TyCon "Authority"))) (field "goRecIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "goTrailing" (TyApp (TyCon "Option") (TyCon "Int"))) (field "goChain" (TyApp (TyCon "List") (TyCon "GrantBinder"))) (field "goStandalone" (TyCon "Bool"))))) ())
(DData Public "MethodGrant" () ((variant "MethodGrant" (ConNamed (field "mgArity" (TyCon "Int")) (field "mgNames" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "GrantCallee" () ((variant "SourceCallee" (ConPos)) (variant "FileExternCallee" (ConPos)) (variant "NoGrantCallee" (ConPos))) ())
(DData Public "GrantState" () ((variant "GrantState" (ConNamed (field "gsOccs" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "GrantOcc")))) (field "gsGrantOnly" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "gsTopIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))))) (field "gsLocalIds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))))) (field "gsMethods" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "MethodGrant")))) (field "gsBodies" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "GrantBinder")))) (field "gsLastInst" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsLastMethodInst" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsLastStandalone" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))) (field "gsSourceless" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "gsTakers" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "gsFresh" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "gsBounds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "gsValueBounds" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "gsPassingModule" (TyApp (TyCon "Ref") (TyCon "String")))))) ())
(DTypeSig true "grantTopKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "grantTopKey" ((PVar "mid") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig true "setGrantIds" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "Unit"))))
(DFunDef false "setGrantIds" ((PVar "table") (PTuple (PVar "key") (PList))) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EVar "omDelete") (EVar "key")) (EFieldAccess (EVar "table") "value"))))
(DFunDef false "setGrantIds" ((PVar "table") (PTuple (PVar "key") (PVar "ids"))) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ids")) (EFieldAccess (EVar "table") "value"))))
(DTypeSig true "methodGrantKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "methodGrantKey" ((PVar "ifaceWord") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))
(DData Public "CtorFieldConflict" () ((variant "CtorWithholds" (ConPos (TyCon "String"))) (variant "CtorSlotsDiffer" (ConPos (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "Int"))) (variant "CtorTypesDiffer" (ConPos (TyCon "String") (TyCon "Mono") (TyCon "String") (TyCon "Mono")))) ())
(DData Public "BuiltinClass" () ((variant "BNum" (ConPos)) (variant "BEq" (ConPos)) (variant "BOrd" (ConPos)) (variant "BSemigroup" (ConPos))) ())
(DData Public "BuiltinClasses" () ((variant "BuiltinClasses" (ConNamed (field "bcNum" (TyCon "TyConOrigin")) (field "bcEq" (TyCon "TyConOrigin")) (field "bcOrd" (TyCon "TyConOrigin")) (field "bcSemigroup" (TyCon "TyConOrigin")) (field "bcNumPresent" (TyCon "Bool")) (field "bcEqPresent" (TyCon "Bool")) (field "bcOrdPresent" (TyCon "Bool")) (field "bcSemigroupPresent" (TyCon "Bool")) (field "bcPreludeSeeded" (TyCon "Bool"))))) ())
(DData Public "AdmittedAnswer" () ((variant "Selects" (ConPos (TyCon "IfaceRef") (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "SelectsNothing" (ConPos)) (variant "Undecided" (ConPos)) (variant "Unroutable" (ConPos (TyCon "IfaceRef")))) ())
(DData Public "SelectedValueOccurrence" () ((variant "SelectedValueOccurrence" (ConNamed (field "svoScheme" (TyCon "Scheme")) (field "svoInstance" (TyCon "MethodTrackedInstantiation")) (field "svoDicts" (TyCon "ShadowDicts"))))) ())
(DData Public "ExistentialScope" () ((variant "ExistentialScope" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Int")))) ())
(DData Public "RecordSubst" () ((variant "RecordSubst" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))))) ())
(DData Public "NumBoundaryDisposition" () ((variant "NumBoundaryOwnedMember" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedGroup" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedScc" (ConPos (TyCon "Int"))) (variant "NumBoundaryOwnedMethodBody" (ConPos (TyCon "Int")))) ())
(DData Public "NumBoundary" () ((variant "NumBoundary" (ConNamed (field "nbDisposition" (TyCon "NumBoundaryDisposition")) (field "nbMembers" (TyApp (TyCon "List") (TyCon "Mono"))) (field "nbSurvivingIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "nbDefaultObls" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "nbAmbiguityObls" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "nbGuard" (TyCon "NumGuard"))))) ())
(DData Public "NumGuard" () ((variant "NumGuard" (ConNamed (field "ngGoals" (TyApp (TyCon "List") (TyCon "UObligation"))) (field "ngRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ngOuterBelow" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DData Public "ArmedGuard" () ((variant "ArmedGuard" (ConNamed (field "agWindow" (TyCon "GoalWindow")) (field "agRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "agOuterBelow" (TyApp (TyCon "Option") (TyCon "Int"))) (field "agWithheld" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ArgRw" () ((variant "ArgRw" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Bool"))))) ())
(DData Public "AdmittedVerdict" () ((variant "AdDefer" (ConPos)) (variant "AdStandalone" (ConPos)) (variant "AdReject" (ConPos (TyApp (TyCon "List") (TyCon "IfaceRef"))))) ())
(DData Public "MethodTemplateGivenResult" () ((variant "MethodTemplateGivenNone" (ConPos)) (variant "MethodTemplateGivenOne" (ConPos (TyCon "GivenEntry"))) (variant "MethodTemplateGivenMany" (ConPos))) ())
(DData Public "CohImpl" () ((variant "CohImpl" (ConPos (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "MStep" ("k" "g" "s") ((variant "MVar" (ConPos (TyVar "k"))) (variant "MKids" (ConPos (TyApp (TyCon "List") (TyTuple (TyVar "g") (TyVar "s"))))) (variant "MOk" (ConPos)) (variant "MFail" (ConPos))) ())
(DData Public "CohScan" () ((variant "CohScan" (ConPos (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))) ())
(DData Public "CohSweep" () ((variant "CohSweepOwn" (ConPos)) (variant "CohSweepGlobal" (ConPos))) ())
(DData Public "KeyEntry" () ((variant "KeyEntry" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "Ty") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Int")))) ())
(DData Public "Undetermined" () ((variant "KeepNone" (ConPos)) (variant "CountImpls" (ConPos (TyCon "IfaceRef"))) (variant "CommitSuper" (ConPos))) ())
(DData Public "EntailKind" () ((variant "EKReturn" (ConPos (TyCon "Mono") (TyCon "Bool"))) (variant "EKNumReturn" (ConPos (TyCon "ClassPredicate") (TyCon "Mono") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "EKNestedTop" (ConPos (TyCon "IfaceRef") (TyCon "Undetermined") (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Mono")))) (variant "EKArg" (ConPos (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (variant "EKOp" (ConPos (TyCon "Bool") (TyCon "Bool"))) (variant "EKPredicateOp" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "ClassPredicate")))) ())
(DData Public "MethodGrantUse" () ((variant "MethodGrants" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "LeadingGrants" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "NoGrants" (ConPos))) ())
(DData Public "ImplUniverse" () ((variant "ImplUniverse" (ConPos (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))) ())
(DData Public "GoalReach" () ((variant "ReachNone" (ConPos)) (variant "ReachOne" (ConPos (TyCon "ImplRow"))) (variant "ReachMany" (ConPos))) ())
(DData Public "LiveGoal" () ((variant "LiveGoal" (ConNamed (field "lgModule" (TyCon "String")) (field "lgBinding" (TyCon "Int")) (field "lgRigidIds" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "lgWindow" (TyCon "GoalWindow")) (field "lgGoal" (TyCon "UObligation"))))) ())
(DData Public "GoalWindow" () ((variant "GoalWindow" (ConNamed (field "gwGoals" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "UObligation")))) (field "gwByIndex" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "UObligation"))) (field "gwByVar" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))) ())
(DData Public "DeclaringBinder" () ((variant "DeclaredBySignature" (ConPos)) (variant "DeclaredByAnnotation" (ConPos))) ())
(DData Public "SuperGoalEntry" () ((variant "SuperGoalEntry" (ConNamed (field "sgWalk" (TyCon "ReqWalk")) (field "sgIface" (TyCon "IfaceRef")) (field "sgArgs" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "ScopedImplMethod" () ((variant "ScopedImplMethod" (ConNamed (field "simMethod" (TyCon "ImplMethod")) (field "simScope" (TyCon "ScopeId"))))) ())
(DData Public "MethodBodyKind" () ((variant "ImplBody" (ConPos (TyCon "ImplBodySite"))) (variant "DefaultBody" (ConPos))) ())
(DData Public "ImplBodySite" () ((variant "ImplBodySite" (ConNamed (field "ibImplTvMap" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "ibHeadMonos" (TyApp (TyCon "List") (TyCon "Mono"))) (field "ibRequires" (TyApp (TyCon "List") (TyCon "Require"))) (field "ibScope" (TyCon "ScopeId"))))) ())
(DData Public "MethodBodyInstance" () ((variant "MethodBodyInstance" (ConNamed (field "mbiExpected" (TyCon "Mono")) (field "mbiContractForce" (TyCon "EffRow")) (field "mbiCheckedForce" (TyFun (TyCon "Unit") (TyCon "EffRow"))) (field "mbiEffVars" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "mbiSurvivors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mbiNamedVars" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (field "mbiDictSlots" (TyApp (TyCon "List") (TyCon "Int"))) (field "mbiTypeSubst" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))) ())
(DData Public "MethodBodyCheck" () ((variant "MethodBodyCheck" (ConNamed (field "mbcLaunderFlagged" (TyCon "Bool")) (field "mbcEagerIndexed" (TyApp (TyCon "List") (TyCon "String"))) (field "mbcPerformedAt" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "HeadVarRoot" () ((variant "TypeVarRoot" (ConPos (TyCon "Int"))) (variant "RowVarRoot" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "HeadVarRoot")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TypeVarRoot" (PVar "__a0")) (PCon "TypeVarRoot" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "RowVarRoot" (PVar "__a0")) (PCon "RowVarRoot" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ScopedMember" () ((variant "ScopedMember" (ConNamed (field "smName" (TyCon "String")) (field "smMono" (TyCon "Mono")) (field "smOwned" (TyCon "BindingSummary")) (field "smDeclaredRoots" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "smDeclaredAuths" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "smSigned" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "smRecursive" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EnvBinding")))) (field "smForce" (TyApp (TyCon "Option") (TyCon "EffRow"))) (field "smForceBound" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EffRow")))) (field "smScope" (TyCon "ScopeId"))))) ())
(DData Public "ConstraintReg" () ((variant "ConstraintReg" (ConNamed (field "crName" (TyCon "String")) (field "crScope" (TyCon "ScopeId")) (field "crIfaceMonos" (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (field "crArgVecs" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))) ())
(DData Public "ScopedScheme" () ((variant "ScopedScheme" (ConNamed (field "ssName" (TyCon "String")) (field "ssScheme" (TyCon "Scheme")) (field "ssScope" (TyCon "ScopeId"))))) ())
(DData Public "BindingRole" () ((variant "RoleQuantifies" (ConPos)) (variant "RoleMonomorphic" (ConPos)) (variant "RoleDeclared" (ConPos))) ())
(DData Public "ModuleBindings" () ((variant "ModuleBindings" (ConNamed (field "mbSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "mbStandaloneSchemes" (TyApp (TyCon "OrdMap") (TyCon "Scheme")))))) ())
(DData Public "ExportBinding" () ((variant "ExportBinding" (ConNamed (field "xbScheme" (TyCon "Scheme")) (field "xbStandalone" (TyApp (TyCon "Option") (TyCon "Scheme"))) (field "xbExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleSeed" () ((variant "ModuleSeed" (ConNamed (field "msSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "msImportedValues" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "msImportedNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "msImportedExterns" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "PreludePreamble" () ((variant "PreludePreamble" (ConNamed (field "ppEnvAcc" (TyCon "DeclEnvAcc")) (field "ppMangledFunDefs" (TyCon "Bool")) (field "ppMarkFacts" (TyCon "PreludeMarkFacts"))))) ())
(DData Public "GraphOut" () ((variant "GOutDiags" (ConPos)) (variant "GOutTrees" (ConPos))) ())
(DData Public "ModuleServe" ("e") ((variant "ModuleServe" (ConNamed (field "msServed" (TyCon "Int")) (field "msFrozen" (TyCon "Int")) (field "msStep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "ServeStep") (TyVar "e"))))))))) ())
(DData Public "ServeStep" ("e") ((variant "ServeHit" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyVar "e") (TyApp (TyCon "ModuleServe") (TyVar "e")))) (variant "ServeCheck" (ConPos (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyApp (TyCon "ModuleServe") (TyVar "e")))))))))) ())
(DData Public "GraphDrive" () ((variant "GraphDrive" (ConNamed (field "gdPerMod" (TyApp (TyCon "List") (TyCon "ModDiags"))) (field "gdCoreSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "gdCoreContexts" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))) (field "gdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "gdModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "gdResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "gdEvTable" (TyCon "EvTable")) (field "gdDispositions" (TyCon "DispositionTable")) (field "gdBinders" (TyCon "BinderTypeTable")) (field "gdReport" (TyCon "TcReport")) (field "gdGraph" (TyCon "GraphCtx")) (field "gdOutputs" (TyCon "DriveOutputs"))))) ())
(DData Public "ElabFacts" () ((variant "ElabFacts" (ConNamed (field "efManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "efBinders" (TyCon "BinderTypeTable")) (field "efEntryOutcome" (TyCon "EntryOutcome"))))) ())
(DData Public "ElabResult" () ((variant "ElabResult" (ConNamed (field "erCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "erModules" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "erPerModule" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))) (field "erResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "erEvidence" (TyCon "EvTable")) (field "erDispositions" (TyCon "DispositionTable")) (field "erFacts" (TyCon "ElabFacts"))))) ())
(DData Public "MarkCtx" () ((variant "MarkCtx" (ConNamed (field "mcRp" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mcAn" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mcSm" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "SpellCtx" () ((variant "SpellCtx" (ConNamed (field "scTopFns" (TyApp (TyCon "List") (TyCon "String"))) (field "scBare" (TyCon "BareLocals")) (field "scCorePfx" (TyCon "String"))))) ())
(DData Public "BareLocals" () ((variant "BareLocals" (ConNamed (field "blAll" (TyCon "Bool")) (field "blSet" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "StampStep" () ((variant "SSNumlitFloats" (ConPos)) (variant "SSReturnSites" (ConPos)) (variant "SSBinopSites" (ConPos)) (variant "SSUnopSites" (ConPos)) (variant "SSArithSites" (ConPos)) (variant "SSArgStamps" (ConPos)) (variant "SSRLocalSites" (ConPos)) (variant "SSRecDictApps" (ConPos)) (variant "SSDictApps" (ConPos)) (variant "SSMethodDicts" (ConPos))) ())
(DData Public "StampCtx" () ((variant "StampCtx" (ConNamed (field "scModule" (TyCon "String")) (field "scModuleCtx" (TyCon "ModuleCtx")) (field "scRpNames" (TyApp (TyCon "List") (TyCon "String"))) (field "scGoals" (TyApp (TyCon "List") (TyCon "Obligation"))) (field "scNumlits" (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route"))))) (field "scLiveLocs" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "DrainFinding" () ((variant "DrainFinding" (ConNamed (field "dfModule" (TyCon "String")) (field "dfDiag" (TyCon "TcDiag")) (field "dfVerdict" (TyCon "Bool")) (field "dfLive" (TyCon "Bool"))))) ())
(DData Public "MarkSets" () ((variant "MarkSets" (ConNamed (field "msMarkRpNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msMarkSharedNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msGraphShadowNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msArgNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msCoreShadowMap" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "msBareDictNames" (TyApp (TyCon "List") (TyCon "String"))) (field "msUnits" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "GraphPreamble" () ((variant "GraphPreamble" (ConNamed (field "gpRuntimeSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "gpCoreSchemes" (TyCon "ModuleBindings")) (field "gpCorePub" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (field "gpCoreContexts" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))) (field "gpCoreTree" (TyApp (TyCon "List") (TyCon "Decl"))) (field "gpMarkSets" (TyCon "MarkSets")) (field "gpCoreCtx" (TyCon "ModuleCtx"))))) ())
(DData Public "PreludeMarkFacts" () ((variant "PreludeMarkFacts" (ConNamed (field "pmfReturnPos" (TyApp (TyCon "List") (TyCon "String"))) (field "pmfMethodConstraints" (TyApp (TyCon "List") (TyCon "String"))) (field "pmfArgDispatch" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "pmfArgDispatchById" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "pmfConstrainedNames" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ModuleMarking" () ((variant "ModuleMarking" (ConNamed (field "mmCtx" (TyCon "MarkCtx")) (field "mmTop" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "mmDictSet" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit")))) (field "mmUserNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mmExterns" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "PassEvidence" () ((variant "PassEvidence" (ConPos (TyCon "EvIndex") (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "EvVal")))))) ())
(DData Public "PassMethod" () ((variant "PassMethod" (ConPos (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))) ())
(DData Public "Accumulate" () ((variant "AccumulateNone" (ConPos)) (variant "AccumulateBoth" (ConPos))) ())
(DData Public "ModulePlace" () ((variant "LastModule" (ConPos)) (variant "NotLastModule" (ConPos))) ())
(DData Public "FoldPlan" ("e" "acc") ((variant "FoldPlan" (ConNamed (field "fpAccumulate" (TyCon "Accumulate")) (field "fpWorker" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyVar "e") (TyCon "ModuleCtx"))))))))) (field "fpCollect" (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyVar "e") (TyFun (TyVar "acc") (TyVar "acc")))))) (field "fpBaseSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "fpCoreV" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))) ())
