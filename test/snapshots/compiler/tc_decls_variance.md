# META
source_lines=591
stages=DESUGAR,MARK
# SOURCE
-- tc_decls_variance: polarity and variance of declared types: occurrence polarity, polarity joins
-- and the `DeclEnvs` polarity fixpoint, with its dependency order, key index (`tabKeyIndex*`) and
-- public-entry filter, and the recording of a declaration's parameter polarities; it also holds the
-- AST payload accessors it is the lowest caller of (`variantPayload`, `payloadAstTypes`,
-- `fieldTyOf`).
--
-- Spec: EFFECTS section 6.4 (inferred variance, invariant indices), section 6.8 (covariant joins),
-- section 5 (the covariant-position check); HM-CORE section 3 (owed, #2555: unification
-- parameterized on the declaration environment's variance).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_decls_types`,
-- `tc_decls`, `tc_foreign`, `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`,
-- `tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`,
-- `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  Polarity(..), Predicate(..), Windowed(..), DeclEnvModule, ModuleCtx
}
import types.tc_mono.{tyAppSpine}
import types.tc_env.{declEnvVisibleTo, padAnns, tyTabKey}
import types.tc_unify.{polarityAt}
import frontend.ast.{
  ConPayload(..),
  DataVis(..),
  Decl(..),
  Field(..),
  KindAnn(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  Variant(..),
  tabKeyEq,
  tabKeyName,
}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import support.util.{anyList, filterList, listLen, reverseL, zipL}
import list.{indexed, sortOn}
import types.invocation_basis.{paramPolaritiesIn}
import support.scc.{tarjanSCCs}

-- ── #1119 D-2: the VARIANCE seed chain (#1098, #1121) ────────────────────
-- `declEnvSeedChain`'s kind half, one table over: the same ordinal-ascending
-- walk, the same `declEnvVisibleTo`-routed row projection, the same "row [m]'s
-- seed is every row strictly earlier than [m]" stamping under [m]'s module id.
-- Read back by `declEnvSeedDataUniverse` in exactly one `omLookup`.
--
-- Without this, the fix is single-FILE-only and silently so.  `Holder`/`Taker`
-- declared in an imported module and exported ABSTRACTLY never reach the
-- importer's `registerVariants` (`publicDataDecls` drops `VisAbstract`), so the
-- importer's per-run table has no row for them, `paramPolaritiesOf` misses, and
-- `unifyN`'s gate abstains — the widening is rejected in a one-file program and
-- accepted through a module boundary.  Measured on this slice's own fixtures:
-- with the single-file rows of `test/effect_polarity_fixtures/` (do not trust a
-- count here, derive it: `ls -d test/effect_polarity_fixtures/*/ | wc -l`)
-- flipping to REJECT, `write-opaque-export` and `contra-opaque-export` stayed
-- ACCEPT until this chain existed.
--
-- The state is a PAIR -- (accumulator, per-module seed table) -- rather than the
-- table alone, so the chain can be resumed from a prefix instead of restarted.
-- See `DeclEnvAcc`.
export
declEnvPolarityChain : List DeclEnvModule ->
  (List (TabKey, List Polarity), OrdMap (List (TabKey, List Polarity))) ->
  (List (TabKey, List Polarity), OrdMap (List (TabKey, List Polarity)))
declEnvPolarityChain [] s = s
declEnvPolarityChain (m :: rest) (pacc, pm) =
  let entries = declEnvRowPolarityEntries (m.demOrd + 1) m pacc
  declEnvPolarityChain rest (entries ++ pacc, omInsert m.demId pacc pm)

-- The polarity entries of row [m] a reader at ordinal [cur] may see — the exact
-- peer of `declEnvRowKindEntries`, composed from the same two predicates rather
-- than an open-coded `<=`, and using the same `kindPublicDataDecl` projection
-- for the cross-module arm (a param's VARIANCE travels with an abstract export
-- for the same reason its KIND does — #804/#1028: the importer can write the
-- type even though it cannot see the constructors).  [tab] is what has been
-- accumulated so far, threaded so a wrapper composes with what it wraps.
--
-- THE FIXPOINT'S input set is not its export set.  It runs over the WHOLE row: a PUBLIC
-- wrapper over a PRIVATE write/contra-bearing declaration must compose against that
-- declaration's real polarity.  With `data Inner a = MkInner (Ref a)` (private) under
-- `export data Outer a = MkOuter (Inner a)`, a pre-filtered input would leave `Inner` at
-- the lenient `PCo` default and accept the widening `Outer (Unit -> <> Unit)` ⇝ `Outer
-- (Unit -> <Stdout> Unit)` through a module boundary while the identical one-file program
-- correctly rejects it (#2112).  Visibility is a filter on what a row EXPORTS, not on
-- what its own variance computation may SEE — the private decl is part of the public
-- wrapper's meaning whether or not anyone can name it.  So the publicity filter applies
-- to the fixpoint's OUTPUT.  (Filtering the output still matters: a private key is
-- unnameable from outside, so publishing its row would be dead weight in a table every
-- later row composes against.)
declEnvRowPolarityEntries : Int ->
  DeclEnvModule ->
  List (TabKey, List Polarity) ->
  List (TabKey, List Polarity)
declEnvRowPolarityEntries cur m tab
  | declEnvVisibleTo cur m.demOrd False =
    declEnvPolarityEntriesFix tab m.demDecls
  | declEnvVisibleTo cur m.demOrd True =
    polarityEntriesPublicOnly
      m.demDecls
      (declEnvPolarityEntriesFix tab m.demDecls)
  | otherwise = []

-- The OUTPUT half of that split: keep only the entries whose declaration
-- this row actually exports.  The predicate is `kindPublicDataDecl`'s reading
-- of publicity plus the `DTypeAlias` arm `declEnvPolarityEntries` records
-- (#2108) — a peer projection rather than a widening of `kindPublicDataDecl`
-- itself, because that predicate has readers (`declEnvKindEntries`,
-- `declEnvSeedChain`) with no alias arm at all, and adding one there would
-- move an acceptance table.
polarityEntriesPublicOnly : List Decl ->
  List (TabKey, List Polarity) ->
  List (TabKey, List Polarity)
polarityEntriesPublicOnly decls entries =
  let keys = polarityPublicKeys decls
  let index = tabKeyIndex keys
  filterList (e => tabKeyIndexHas index (fst e)) entries

-- The keys of [decls] that leave the module.  Arm for arm with
-- `kindPublicDataDecl`, plus `DTypeAlias`; `DAttrib` unwraps as everywhere else
-- in this file.
polarityPublicKeys : List Decl -> List TabKey
polarityPublicKeys [] = []
polarityPublicKeys ((DAttrib _ d) :: rest) = polarityPublicKeys (d :: rest)
polarityPublicKeys ((DData { dataVis = VisPublic, dataName = n, dataOrigin = o }) :: rest) =
  tyTabKey o n :: polarityPublicKeys rest
polarityPublicKeys ((DData { dataVis = VisAbstract, dataName = n, dataOrigin = o }) :: rest) =
  tyTabKey o n :: polarityPublicKeys rest
polarityPublicKeys ((DNewtype { newtypePub = True, newtypeName = n, newtypeOrigin = o }) :: rest) =
  tyTabKey o n :: polarityPublicKeys rest
polarityPublicKeys ((DTypeAlias { tyAliasPub = True, tyAliasName = n, tyAliasOrigin = o }) :: rest) =
  tyTabKey o n :: polarityPublicKeys rest
polarityPublicKeys (_ :: rest) = polarityPublicKeys rest

-- Membership index over a `TabKey` list, bucketed by the bare name: the probe
-- reads the name already stored in the key (no rendering, no allocation), and
-- `tabKeyEq` decides inside the bucket, so `tabKeyIndexHas (tabKeyIndex ks) k`
-- answers exactly "some `k2` in `ks` has `tabKeyEq k2 k`".
tabKeyIndex : List TabKey -> OrdMap (List TabKey)
tabKeyIndex keys = tabKeyIndexGo keys omEmpty

tabKeyIndexGo : List TabKey -> OrdMap (List TabKey) -> OrdMap (List TabKey)
tabKeyIndexGo [] index = index
tabKeyIndexGo (k :: rest) index =
  let name = tabKeyName k
  let bucket = match omLookup name index
    Some b => b
    None => []
  tabKeyIndexGo rest (omInsert name (k :: bucket) index)

tabKeyIndexHas : OrdMap (List TabKey) -> TabKey -> Bool
tabKeyIndexHas index key = match omLookup (tabKeyName key) index
  None => False
  Some bucket => anyList (k => tabKeyEq k key) bucket

-- ── S0-3: the TRANSITIVE FIXPOINT the single fold above cannot reach ──────
-- `declEnvPolarityEntries` (below) is ONE in-order pass, so a wrapper declared
-- ABOVE the type it wraps composes against the lenient `PCo` default and never
-- tightens.  `data Outer a = MkOuter (Inner a)` written before `data Inner a =
-- MkInner (a -> Int)` was ACCEPTED for a widening the very same program with
-- the two `data` lines SWAPPED correctly rejected — a live, single-file,
-- both-engine-agreeing false accept of the #1098/#1121 laundering shape D-2
-- (#1119) exists to close, reachable by reordering two declarations.  Both the
-- write-channel (`Ref`) and the contravariant-domain shapes reproduced it.
--
-- The fix: re-run the pass over its OWN previous output until nothing moves,
-- starting every declaration in [ds] at "no occurrence yet" (`PPhantom`), the
-- bottom of the order `PPhantom` < {`PCo`, `PContra`} < `PInv`.  Each round
-- starts from `prev ++ base`, so every decl in [ds] reads the previous round's
-- verdict for every OTHER decl in the same scope regardless of declaration
-- order, while the in-pass prepend still lets the fresher in-round value win.
--
-- Sign composition (`polMul`) and the join (`polJoin`) are monotone in that
-- order, and `PPhantom` absorbs under composition, so from the bottom every
-- round can only move an entry UP a lattice of height three: the iteration
-- converges, and to the least fixpoint.  `data A x = MkA (B x -> Int)` over
-- `data B y = MkB (y -> Int)` reads `x` as `PPhantom` on round one (B's slot
-- has no occurrence yet) and `PCo` on round two: two flips, the correct
-- answer, with no round in between that said otherwise.  Starting a
-- not-yet-computed type at the lenient `PCo` instead is what made the old
-- iteration non-monotone, and its cap at `listLen ds + 1` rounds left a flip
-- cycle through several types (`T4 y = TA (y -> Unit) | TB (T1 (y -> Unit))`
-- under T1..T3) reading an invariant slot as covariant (#3512).  The cap
-- below is a bound the monotone iteration cannot reach; were it reached, every
-- entry is published invariant rather than guessed.
declEnvPolarityEntriesFix : List (TabKey, List Polarity) ->
  List Decl ->
  List (TabKey, List Polarity)
declEnvPolarityEntriesFix base ds =
  let ordered = polarityDependencyOrder ds
  let odecls = map snd ordered
  let first = declEnvPolarityEntries base odecls
  let bottom = map (e => (fst e, map (_ => PPhantom) (snd e))) first
  let height = 3 * fold (n e => n + listLen (snd e)) 0 first + 3
  let settled = declEnvPolarityFixGo base odecls height bottom
  map
    (ie => (fst (snd ie), map publishedPolarity (snd (snd ie))))
    (sortOn fst (zipL (map fst ordered) settled))

-- The declarations of [ds] that carry a polarity row, each tagged with its
-- position among them, reordered so a declaration comes after the types it
-- names (a cycle keeps its members together).  A round reads the previous
-- round's rows for everything declared later, so a wrapper chain declared
-- top-down needs one round per link in source order and one in this order.
polarityDependencyOrder : List Decl -> List (Int, Decl)
polarityDependencyOrder ds =
  let named =
    filterList (ide => isSome (polarityDeclInfo (snd ide))) (indexed ds)
  let names = map (ide => fst (polarityDeclHeadAndTys (snd ide))) named
  let known = omFromNames names omEmpty
  let adj =
    fold
      (acc ide =>
        let ht = polarityDeclHeadAndTys (snd ide)
        omInsert
          (fst ht)
          (filterList
              (n => omHasKey n known)
              (fold (a t => polarityTyConNames t a) [] (snd ht))
            ++ optionOr [] (omLookup (fst ht) acc))
          acc)
      omEmpty
      named
  let buckets =
    fold
      (acc ide =>
        let n = fst (polarityDeclHeadAndTys (snd ide))
        omInsert n (ide :: optionOr [] (omLookup n acc)) acc)
      omEmpty
      (reverseL named)
  flatMap
    (n => optionOr [] (omLookup n buckets))
    (flatMap (scc => scc) (tarjanSCCs names adj))

polarityDeclInfo : Decl -> Option (String, List Ty)
polarityDeclInfo (DAttrib _ d) = polarityDeclInfo d
polarityDeclInfo (DData { dataName = n, dataCtors = vs }) =
  Some (n, flatMap (v => payloadAstTypes (variantPayload v)) vs)
polarityDeclInfo (DNewtype { newtypeName = n, newtypeFieldTy = fty }) =
  Some (n, [fty])
polarityDeclInfo (DTypeAlias { tyAliasName = n, tyAliasRhs = rhs }) =
  Some (n, [rhs])
polarityDeclInfo _ = None

polarityDeclHeadAndTys : Decl -> (String, List Ty)
polarityDeclHeadAndTys d = optionOr ("", []) (polarityDeclInfo d)

-- Every type constructor name written in [t], prepended onto [acc].  Only the
-- ORDER of the fixpoint reads this, so a row's contents are skipped.
polarityTyConNames : Ty -> List String -> List String
polarityTyConNames (TyCon { tyConName = n }) acc = n :: acc
polarityTyConNames (TyApp a b) acc =
  polarityTyConNames a (polarityTyConNames b acc)
polarityTyConNames (TyFun a b) acc =
  polarityTyConNames a (polarityTyConNames b acc)
polarityTyConNames (TyTuple ts) acc =
  fold (a t => polarityTyConNames t a) acc ts
polarityTyConNames (TyEffect _ _ t) acc = polarityTyConNames t acc
polarityTyConNames (TyConstrained _ t) acc = polarityTyConNames t acc
polarityTyConNames (TyNamed _ t _) acc = polarityTyConNames t acc
polarityTyConNames (TyQual t _ _) acc = polarityTyConNames t acc
polarityTyConNames _ acc = acc

declEnvPolarityFixGo : List (TabKey, List Polarity) ->
  List Decl ->
  Int ->
  List (TabKey, List Polarity) ->
  List (TabKey, List Polarity)
declEnvPolarityFixGo base ds fuel prev =
  if fuel <= 0 then
    map (e => (fst e, map (_ => PInv) (snd e))) prev
  else
    let next = declEnvPolarityEntries (prev ++ base) ds
    if polarityEntriesEq prev next then
      prev
    else
      declEnvPolarityFixGo base ds (fuel - 1) next

-- A parameter with no occurrence is phantom: nothing about it can be
-- laundered, so the published verdict is the lenient one.
publishedPolarity : Polarity -> Polarity
publishedPolarity PPhantom = PCo
publishedPolarity q = q

-- POSITIONAL, not keyed: the two lists are two rounds over the SAME [ds], so
-- `declEnvPolarityEntries`' decl-order output puts the same declaration at the
-- same index in both.  The key comparison is a cheap corroboration of that
-- invariant, not a lookup.
polarityEntriesEq : List (TabKey, List Polarity) ->
  List (TabKey, List Polarity) ->
  Bool
polarityEntriesEq [] [] = True
polarityEntriesEq ((k1, p1) :: r1) ((k2, p2) :: r2) =
  tabKeyEq k1 k2 && polaritiesEq p1 p2 && polarityEntriesEq r1 r2
polarityEntriesEq _ _ = False

polaritiesEq : List Polarity -> List Polarity -> Bool
polaritiesEq [] [] = True
polaritiesEq (q1 :: r1) (q2 :: r2) = polarityEq q1 q2 && polaritiesEq r1 r2
polaritiesEq _ _ = False

polarityEq : Polarity -> Polarity -> Bool
polarityEq PCo PCo = True
polarityEq PContra PContra = True
polarityEq PInv PInv = True
polarityEq PPhantom PPhantom = True
polarityEq _ _ = False

-- The population half, mirroring `declEnvKindEntries` arm for arm — including
-- its `DAttrib` unwrap.  It is a FOLD, not a `map`: each decl's entry is
-- prepended to the table the NEXT decl composes against, so a wrapper declared
-- after the type it wraps sees it.  A wrapper declared BEFORE reads the lenient
-- `PCo` default — which is why NOTHING calls this directly any more:
-- `declEnvPolarityEntriesFix` above iterates it to a fixpoint so that
-- declaration ORDER stops being observable.
declEnvPolarityEntries : List (TabKey, List Polarity) ->
  List Decl ->
  List (TabKey, List Polarity)
declEnvPolarityEntries _ [] = []
declEnvPolarityEntries tab ((DAttrib _ d) :: rest) =
  declEnvPolarityEntries tab (d :: rest)
declEnvPolarityEntries tab ((DData { dataName = n, dataParams = ps, dataParamKinds = ks, dataCtors = vs, dataOrigin = o }) :: rest) =
  let entry = (tyTabKey o n, inferParamPolarities tab ps ks vs)
  entry :: declEnvPolarityEntries (entry :: tab) rest
declEnvPolarityEntries tab ((DNewtype { newtypeName = n, newtypeParams = ps, newtypeParamKinds = ks, newtypeCtor = con, newtypeFieldTy = fty, newtypeOrigin = o }) :: rest) =
  let entry =
    (tyTabKey o n, inferParamPolarities tab ps ks [Variant con (ConPos [fty])])
  entry :: declEnvPolarityEntries (entry :: tab) rest
-- #2108: A type alias is transparent, so it must carry the channel it names.
-- Falling through to the catch-all below left `type Cell a = Ref a` with no row
-- at all, so `data Box a = MkBox (Cell a)` read `polarityAtOr None _ = PCo` and
-- the whole write channel vanished behind one line of surface sugar: the
-- widening `Box (Unit -> <> Unit)` ⇝ `Box (Unit -> <Stdout> Unit)` was ACCEPTED
-- (and `callBox : Unit -> Unit` printed through the cell) where the alias-free
-- `data Box a = MkBox (Ref a)` correctly rejected it.  Aliases are expanded by
-- `fromAstType*` LATER than this table is built, so the expansion has to happen
-- here: the RHS is exactly the alias's one "field", read against the same [tab]
-- every other arm composes against, which is the alias expanded to whatever
-- depth the fixpoint has already resolved (an alias over an alias settles on a
-- later round, like any other wrapper).
--
-- The entry is recorded under the ALIAS's own key, not its RHS head's, so an
-- occurrence `Cell a` resolves through `paramOccPolarities`' `TyApp` spine arm
-- against `tyTabKey tyAliasOrigin "Cell"` — the same decl-borne identity
-- `DData`/`DNewtype` use, so a same-named alias in another module cannot answer
-- for this one.
declEnvPolarityEntries tab ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasParamKinds = ks, tyAliasRhs = rhs, tyAliasOrigin = o }) :: rest) =
  let entry =
    (tyTabKey o n, inferParamPolarities tab ps ks [Variant n (ConPos [rhs])])
  entry :: declEnvPolarityEntries (entry :: tab) rest
declEnvPolarityEntries tab (_ :: rest) = declEnvPolarityEntries tab rest

-- ── #1119 D-2 (#1098 / #1121): the VARIANCE half of `recordParamKinds` ────
-- Sibling of `recordParamKinds` immediately above, sharing its key (`tyTabKey
-- o name`), its prepend, and therefore its first-match read ordering.  It is a
-- SEPARATE table rather than a second column of the kind table because the two
-- are read at different seams (kinds at elaboration, polarity at unification)
-- and because widening the kind table's row type would move every one of its
-- callers for no gain.
export
recordParamPolarities : ModuleCtx ->
  TyConOrigin ->
  String ->
  List Polarity ->
  Unit
recordParamPolarities mctx o name pols =
  let entry = (tyTabKey o name, map publishedPolarity pols)
  mctx.mcCells.dataParamPolarityRef :=
    entry :: mctx.mcCells.dataParamPolarityRef.value

-- Per-parameter variance, inferred from constructor field occurrences.  Mirrors
-- `inferParamKinds`' shape: one pass over `payloadAstTypes`, positional result.
--
-- ORDER-sensitive by construction, and it under-TIGHTENS ON A MISS.  A
-- `TyApp` spine composes the occurrence's own polarity with the HEAD type's
-- recorded polarity at that slot, so `data Cell a = MkCell (Ref a)` needs
-- `Ref`'s row to already be visible.  A CONCRETE head that is not yet
-- registered — a forward reference, or the type itself, as in `data List a =
-- Nil | Cons a (List a)` — reads `PCo` (`polarityAtOr None`), which is exactly
-- the fully lenient default: it can only fail to tighten, never reject a program.  Inside
-- `declEnvPolarityEntriesFix` no own head misses: every declaration is seeded at `PPhantom`, so a
-- self or forward reference reads "no occurrence yet", the join's unit, and the self-recursive
-- `List` comes out `PCo` by convergence.  The `None` default is left to the single-pass
-- `registerVariants` path.
-- That paragraph scopes to the unregistered-*TyCon*-head miss only, and is
-- Not the abstract-HEAD ARM (#2107).  The two were one sentence until #2107
-- separated them: a head that is a type *parameter* (`data W f a = MkW (f a)`)
-- can never become registered by iterating, because its polarity is not a fact
-- about this declaration at all — it depends on what `f` is instantiated to at
-- each use.  See that arm's own note in `paramOccPolarities` below.
-- The table it composes against is an argument, not a module record's, and that is
-- load-bearing: `declEnvPolarityChain` runs this over the WHOLE import graph
-- while building the cross-module seed, at a point where the per-run ref holds
-- nothing yet.  Reading the ref here would have made cross-module transitivity
-- silently lenient while the single-file path tightened — the split
-- `[WT-multi-module-check]` names.
export
inferParamPolarities : List (TabKey, List Polarity) ->
  List String ->
  List (Option KindAnn) ->
  List Variant ->
  List Polarity
inferParamPolarities tab params anns variants =
  let fieldTys = flatMap (v => payloadAstTypes (variantPayload v)) variants
  map
    (pk => match snd pk
      -- An authority index is invariant by kind (§6.4), whatever its
      -- occurrences: a qualifier or an atom is not a type position this
      -- walk could read a variance off.
      Some (KindAuthority _ _ _ _) => PInv
      _ =>
        joinPolarities
          (flatMap (t => paramOccPolarities tab (fst pk) PCo t) fieldTys))
    (zipL params (padAnns params anns))

export
variantPayload : Variant -> ConPayload
variantPayload (Variant _ payload) = payload

-- Every occurrence of parameter [p] inside [t], each reported at the polarity
-- [pol] the surrounding context gives it.  `TyFun`'s DOMAIN flips (mirroring
-- `argPerformableOccs`' `perf`-flip convention); `TyEffect`/`TyConstrained`/
-- `TyTuple` pass the context through; `TyRow` contributes nothing (a written
-- row in an index slot is #1094's invariance, already enforced by
-- `unifyIndexRow`, and is not this table's business).
paramOccPolarities : List (TabKey, List Polarity) ->
  String ->
  Polarity ->
  Ty ->
  List Polarity
paramOccPolarities _ p pol (TyVar n) = if n == p then [pol] else []
paramOccPolarities _ _ _ (TyCon { tyConName = _ }) = []
paramOccPolarities tab p pol (TyFun a b) =
  paramOccPolarities tab p (polMul pol PContra) a
    ++ paramOccPolarities tab p pol b
paramOccPolarities tab p pol (TyTuple ts) =
  flatMap (paramOccPolarities tab p pol) ts
paramOccPolarities tab p pol (TyEffect _ _ t) = paramOccPolarities tab p pol t
paramOccPolarities tab p pol (TyConstrained _ t) =
  paramOccPolarities tab p pol t
paramOccPolarities _ _ _ (TyRow _ _ _) = []
paramOccPolarities _ _ _ (TyAuth _ _) = []
paramOccPolarities tab p pol (TyNamed _ t _) = paramOccPolarities tab p pol t
paramOccPolarities tab p pol (TyQual t _ _) = paramOccPolarities tab p pol t
paramOccPolarities tab p pol (TyApp a b) = match tyAppSpine (TyApp a b)
  -- OCCURRENCE MINT: same record pattern as
  -- `argPerformableOccs`' spine arm, for the same reason — the head's name and
  -- its acquired identity must be read off one pattern so they cannot drift.
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    paramOccPolaritiesArgs
      tab
      p
      pol
      (paramPolaritiesIn tab (tyTabKey o n))
      0
      args
  -- ── #2107: ABSTRACT HEAD ⇒ INVARIANT, not the lenient `PCo` default ──────
  -- An abstract head — a type PARAMETER of this very declaration, as `f` is in
  -- `data W f a = MkW (f a)` — records nothing anywhere, and unlike an
  -- unregistered `TyCon` head it never will: `f`'s slot polarity is not a
  -- property of `W` at all, it is whatever the head gets INSTANTIATED to at
  -- each use.  `W Ref` needs `PInv`; `W List` would be sound at `PCo`.  The
  -- declaration cannot tell them apart, so it takes the sound side and reports
  -- every occurrence reached through such a head as `PInv`.
  --
  -- THIS IS A deliberate, measured acceptance narrowing — the one place in
  -- this function that can reject a program that used to be accepted.  It is
  -- the same trade `paramVarianceGuard`'s own "this does narrow acceptance
  -- In the sound direction too" note already documents: equality is the only
  -- symmetric sound rule available without direction, and here invariance is
  -- the only sound verdict available without knowing `f`.  Cost, measured:
  -- `data W f a = MkW (f a)` at `f := List` (immutable, covariant) can no
  -- longer widen a closed effect row at `a`, though doing so would be sound.
  -- Benefit: at `f := Ref` it no longer LAUNDERS one (#2107 — a `Unit -> Unit`
  -- reader of a cell someone wrote a `<Stdout>` closure into, silently).
  -- Recovering the sound half needs a DEPENDENT polarity (`f`'s slot resolved
  -- against the mono argument actually applied at that index, at
  -- `paramVarianceGuard`) — a new `Polarity` constructor and a resolution step,
  -- not a change to this arm.
  --
  -- The count is preserved rather than fabricated: `map` over the occurrences
  -- the two sides actually report, so a parameter that does not occur here
  -- still contributes nothing.
  _ =>
    map
      (q => polMul PInv q)
      (paramOccPolarities tab p pol a ++ paramOccPolarities tab p pol b)

paramOccPolaritiesArgs : List (TabKey, List Polarity) ->
  String ->
  Polarity ->
  Option (List Polarity) ->
  Int ->
  List Ty ->
  List Polarity
paramOccPolaritiesArgs _ _ _ _ _ [] = []
paramOccPolaritiesArgs tab p pol headPols i (t :: rest) =
  paramOccPolarities tab p (polMul pol (polarityAtOr headPols i)) t
    ++ paramOccPolaritiesArgs tab p pol headPols (i + 1) rest

-- Sign composition over {+1, -1, 0} ≅ {PCo, PContra, PInv}: commutative, `PCo`
-- is the unit and `PInv` absorbs; `PPhantom`, no occurrence at all, absorbs
-- even `PInv` (an occurrence through a slot nothing fills is no occurrence).
polMul : Polarity -> Polarity -> Polarity
polMul PPhantom _ = PPhantom
polMul _ PPhantom = PPhantom
polMul PInv _ = PInv
polMul _ PInv = PInv
polMul PCo q = q
polMul PContra PCo = PContra
polMul PContra PContra = PCo

-- No occurrence at all is `PPhantom`, the join's unit; a published entry
-- reads it as `PCo` (`publishedPolarity`) — nothing about a phantom parameter
-- can be laundered, so the lenient verdict is the correct one, not a default.
joinPolarities : List Polarity -> Polarity
joinPolarities [] = PPhantom
joinPolarities (q :: rest) = joinPolaritiesGo q rest

joinPolaritiesGo : Polarity -> List Polarity -> Polarity
joinPolaritiesGo acc [] = acc
joinPolaritiesGo PInv _ = PInv
joinPolaritiesGo acc (q :: rest) = joinPolaritiesGo (polJoin acc q) rest

polJoin : Polarity -> Polarity -> Polarity
polJoin PPhantom q = q
polJoin q PPhantom = q
polJoin PCo PCo = PCo
polJoin PContra PContra = PContra
polJoin _ _ = PInv

polarityAtOr : Option (List Polarity) -> Int -> Polarity
polarityAtOr None _ = PCo
polarityAtOr (Some pols) i = polarityAt pols i

export
payloadAstTypes : ConPayload -> List Ty
payloadAstTypes (ConPos tys) = tys
payloadAstTypes (ConNamed fields _) = map fieldTyOf fields

fieldTyOf : Field -> Ty
fieldTyOf (Field _ ty) = ty

-- Prepends, exactly as `recordParamPolarities` does, so the seed layers over
-- whatever the universe/import ladder already put in the ref rather than
-- replacing it.
-- #2112: the fixpoint runs over [allDs]; only the keys declared in [ds] are
-- kept.  When the two lists are the same list nothing is filtered.
--
-- A declaration the table ALREADY answers for is not recomputed.  The
-- cross-module chain (`declEnvRowPolarityEntries`) computed an imported
-- public wrapper's row over its OWN module, private siblings included; here
-- those siblings are out of sight (filtered from the universe), so a recompute
-- could only be more lenient, and in-round it would shadow the chain's row
-- for every own declaration composing against it.  The universe is
-- authoritative for what it holds; this seed adds only what it does not.
export
seedParamPolarityFixpointScoped : ModuleCtx -> List Decl -> List Decl -> Unit
seedParamPolarityFixpointScoped mctx ds allDs =
  let cur = mctx.mcCells.dataParamPolarityRef.value
  -- Index the small side: only the entries of `cur` that match a key of `allDs` matter.
  let allKeyIndex = tabKeyIndex (declPolarityKeys allDs)
  let curIndex =
    tabKeyIndex
      (map fst (filterList (e => tabKeyIndexHas allKeyIndex (fst e)) cur))
  let fresh = filterList (d => not (declHasPolarityEntry curIndex d)) allDs
  let full = declEnvPolarityEntriesFix cur fresh
  let keyIndex = tabKeyIndex (declPolarityKeys ds)
  let kept = filterList (e => tabKeyIndexHas keyIndex (fst e)) full
  mctx.mcCells.dataParamPolarityRef := kept ++ cur

declHasPolarityEntry : OrdMap (List TabKey) -> Decl -> Bool
declHasPolarityEntry index d = match declPolarityKeys [d]
  [] => False
  k :: _ => tabKeyIndexHas index k

-- every key `declEnvPolarityEntries` would record for [ds], public or not —
-- the input-side counterpart of `polarityPublicKeys`.
declPolarityKeys : List Decl -> List TabKey
declPolarityKeys [] = []
declPolarityKeys ((DAttrib _ d) :: rest) = declPolarityKeys (d :: rest)
declPolarityKeys ((DData { dataName = n, dataOrigin = o }) :: rest) =
  tyTabKey o n :: declPolarityKeys rest
declPolarityKeys ((DNewtype { newtypeName = n, newtypeOrigin = o }) :: rest) =
  tyTabKey o n :: declPolarityKeys rest
declPolarityKeys ((DTypeAlias { tyAliasName = n, tyAliasOrigin = o }) :: rest) =
  tyTabKey o n :: declPolarityKeys rest
declPolarityKeys (_ :: rest) = declPolarityKeys rest
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "Polarity" true) (mem "Predicate" true) (mem "Windowed" true) (mem "DeclEnvModule" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tyAppSpine" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declEnvVisibleTo" false) (mem "padAnns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "polarityAt" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "DataVis" true) (mem "Decl" true) (mem "Field" true) (mem "KindAnn" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "tabKeyEq" false) (mem "tabKeyName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "listLen" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "indexed" false) (mem "sortOn" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "paramPolaritiesIn" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DTypeSig true "declEnvPolarityChain" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "declEnvPolarityChain" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvPolarityChain" ((PCons (PVar "m") (PVar "rest")) (PTuple (PVar "pacc") (PVar "pm"))) (EBlock (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "declEnvRowPolarityEntries") (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m")) (EVar "pacc"))) (DoExpr (EApp (EApp (EVar "declEnvPolarityChain") (EVar "rest")) (ETuple (EBinOp "++" (EVar "entries") (EVar "pacc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EVar "pacc")) (EVar "pm")))))))
(DTypeSig false "declEnvRowPolarityEntries" (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity"))))))))
(DFunDef false "declEnvRowPolarityEntries" ((PVar "cur") (PVar "m") (PVar "tab")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "tab")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EApp (EApp (EVar "polarityEntriesPublicOnly") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "tab")) (EFieldAccess (EVar "m") "demDecls"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "polarityEntriesPublicOnly" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "polarityEntriesPublicOnly" ((PVar "decls") (PVar "entries")) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "polarityPublicKeys") (EVar "decls"))) (DoLet false false (PVar "index") (EApp (EVar "tabKeyIndex") (EVar "keys"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EVar "index")) (EApp (EVar "fst") (EVar "e"))))) (EVar "entries")))))
(DTypeSig false "polarityPublicKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "polarityPublicKeys" ((PList)) (EListLit))
(DFunDef false "polarityPublicKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "polarityPublicKeys") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "polarityPublicKeys") (EVar "rest")))
(DTypeSig false "tabKeyIndex" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey")))))
(DFunDef false "tabKeyIndex" ((PVar "keys")) (EApp (EApp (EVar "tabKeyIndexGo") (EVar "keys")) (EVar "omEmpty")))
(DTypeSig false "tabKeyIndexGo" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))))))
(DFunDef false "tabKeyIndexGo" ((PList) (PVar "index")) (EVar "index"))
(DFunDef false "tabKeyIndexGo" ((PCons (PVar "k") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "tabKeyName") (EVar "k"))) (DoLet false false (PVar "bucket") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "index")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "tabKeyIndexGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "k") (EVar "bucket"))) (EVar "index"))))))
(DTypeSig false "tabKeyIndexHas" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "tabKeyIndexHas" ((PVar "index") (PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "tabKeyName") (EVar "key"))) (EVar "index")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "bucket")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "bucket")))))
(DTypeSig false "declEnvPolarityEntriesFix" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "declEnvPolarityEntriesFix" ((PVar "base") (PVar "ds")) (EBlock (DoLet false false (PVar "ordered") (EApp (EVar "polarityDependencyOrder") (EVar "ds"))) (DoLet false false (PVar "odecls") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ordered"))) (DoLet false false (PVar "first") (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "base")) (EVar "odecls"))) (DoLet false false (PVar "bottom") (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "PPhantom"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "first"))) (DoLet false false (PVar "height") (EBinOp "+" (EBinOp "*" (ELit (LInt 3)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "e")) (EBinOp "+" (EVar "n") (EApp (EVar "listLen") (EApp (EVar "snd") (EVar "e")))))) (ELit (LInt 0))) (EVar "first"))) (ELit (LInt 3)))) (DoLet false false (PVar "settled") (EApp (EApp (EApp (EApp (EVar "declEnvPolarityFixGo") (EVar "base")) (EVar "odecls")) (EVar "height")) (EVar "bottom"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "ie")) (ETuple (EApp (EVar "fst") (EApp (EVar "snd") (EVar "ie"))) (EApp (EApp (EVar "map") (EVar "publishedPolarity")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "ie"))))))) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "zipL") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ordered"))) (EVar "settled")))))))
(DTypeSig false "polarityDependencyOrder" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Decl")))))
(DFunDef false "polarityDependencyOrder" ((PVar "ds")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "ide")) (EApp (EVar "isSome") (EApp (EVar "polarityDeclInfo") (EApp (EVar "snd") (EVar "ide")))))) (EApp (EVar "indexed") (EVar "ds")))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "ide")) (EApp (EVar "fst") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide")))))) (EVar "named"))) (DoLet false false (PVar "known") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "ide")) (EBlock (DoLet false false (PVar "ht") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "ht"))) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "known")))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "t")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "a")))) (EListLit)) (EApp (EVar "snd") (EVar "ht")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "ht"))) (EVar "acc"))))) (EVar "acc")))))) (EVar "omEmpty")) (EVar "named"))) (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "ide")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "fst") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide"))))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "ide") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc"))))) (EVar "acc")))))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "named")))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "buckets"))))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "scc")) (EVar "scc"))) (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EVar "adj")))))))
(DTypeSig false "polarityDeclInfo" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "polarityDeclInfo" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "polarityDeclInfo") (EVar "d")))
(DFunDef false "polarityDeclInfo" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "vs")))))
(DFunDef false "polarityDeclInfo" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeFieldTy" (PVar "fty"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EListLit (EVar "fty")))))
(DFunDef false "polarityDeclInfo" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EListLit (EVar "rhs")))))
(DFunDef false "polarityDeclInfo" (PWild) (EVar "None"))
(DTypeSig false "polarityDeclHeadAndTys" (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "polarityDeclHeadAndTys" ((PVar "d")) (EApp (EApp (EVar "optionOr") (ETuple (ELit (LString "")) (EListLit))) (EApp (EVar "polarityDeclInfo") (EVar "d"))))
(DTypeSig false "polarityTyConNames" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "polarityTyConNames" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) (PVar "acc")) (EBinOp "::" (EVar "n") (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "a")) (EApp (EApp (EVar "polarityTyConNames") (EVar "b")) (EVar "acc"))))
(DFunDef false "polarityTyConNames" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "a")) (EApp (EApp (EVar "polarityTyConNames") (EVar "b")) (EVar "acc"))))
(DFunDef false "polarityTyConNames" ((PCon "TyTuple" (PVar "ts")) (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "t")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "a")))) (EVar "acc")) (EVar "ts")))
(DFunDef false "polarityTyConNames" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "declEnvPolarityFixGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "declEnvPolarityFixGo" ((PVar "base") (PVar "ds") (PVar "fuel") (PVar "prev")) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "PInv"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "prev")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "++" (EVar "prev") (EVar "base"))) (EVar "ds"))) (DoExpr (EIf (EApp (EApp (EVar "polarityEntriesEq") (EVar "prev")) (EVar "next")) (EVar "prev") (EApp (EApp (EApp (EApp (EVar "declEnvPolarityFixGo") (EVar "base")) (EVar "ds")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "next")))))))
(DTypeSig false "publishedPolarity" (TyFun (TyCon "Polarity") (TyCon "Polarity")))
(DFunDef false "publishedPolarity" ((PCon "PPhantom")) (EVar "PCo"))
(DFunDef false "publishedPolarity" ((PVar "q")) (EVar "q"))
(DTypeSig false "polarityEntriesEq" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyCon "Bool"))))
(DFunDef false "polarityEntriesEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "polarityEntriesEq" ((PCons (PTuple (PVar "k1") (PVar "p1")) (PVar "r1")) (PCons (PTuple (PVar "k2") (PVar "p2")) (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "tabKeyEq") (EVar "k1")) (EVar "k2")) (EApp (EApp (EVar "polaritiesEq") (EVar "p1")) (EVar "p2"))) (EApp (EApp (EVar "polarityEntriesEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "polarityEntriesEq" (PWild PWild) (EVar "False"))
(DTypeSig false "polaritiesEq" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Bool"))))
(DFunDef false "polaritiesEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "polaritiesEq" ((PCons (PVar "q1") (PVar "r1")) (PCons (PVar "q2") (PVar "r2"))) (EBinOp "&&" (EApp (EApp (EVar "polarityEq") (EVar "q1")) (EVar "q2")) (EApp (EApp (EVar "polaritiesEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "polaritiesEq" (PWild PWild) (EVar "False"))
(DTypeSig false "polarityEq" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Bool"))))
(DFunDef false "polarityEq" ((PCon "PCo") (PCon "PCo")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PContra") (PCon "PContra")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PInv") (PCon "PInv")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PPhantom") (PCon "PPhantom")) (EVar "True"))
(DFunDef false "polarityEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declEnvPolarityEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "declEnvPolarityEntries" (PWild (PList)) (EListLit))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "tab")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "vs")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EVar "vs")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EListLit (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EVar "ConPos") (EListLit (EVar "rhs")))))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "tab")) (EVar "rest")))
(DTypeSig true "recordParamPolarities" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Unit"))))))
(DFunDef false "recordParamPolarities" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "pols")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "publishedPolarity")) (EVar "pols")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value"))))))
(DTypeSig true "inferParamPolarities" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "inferParamPolarities" ((PVar "tab") (PVar "params") (PVar "anns") (PVar "variants")) (EBlock (DoLet false false (PVar "fieldTys") (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "variants"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "pk")) (EMatch (EApp (EVar "snd") (EVar "pk")) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EVar "PInv")) (arm PWild () (EApp (EVar "joinPolarities") (EApp (EApp (EVar "flatMap") (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EApp (EVar "fst") (EVar "pk"))) (EVar "PCo")) (EVar "t")))) (EVar "fieldTys"))))))) (EApp (EApp (EVar "zipL") (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns")))))))
(DTypeSig true "variantPayload" (TyFun (TyCon "Variant") (TyCon "ConPayload")))
(DFunDef false "variantPayload" ((PCon "Variant" PWild (PVar "payload"))) (EVar "payload"))
(DTypeSig false "paramOccPolarities" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "String") (TyFun (TyCon "Polarity") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "paramOccPolarities" (PWild (PVar "p") (PVar "pol") (PCon "TyVar" (PVar "n"))) (EIf (EBinOp "==" (EVar "n") (EVar "p")) (EListLit (EVar "pol")) (EListLit)))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EApp (EApp (EVar "polMul") (EVar "pol")) (EVar "PContra"))) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "b"))))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol"))) (EVar "ts")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "paramOccPolaritiesArgs") (EVar "tab")) (EVar "p")) (EVar "pol")) (EApp (EApp (EVar "paramPolaritiesIn") (EVar "tab")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")))) (ELit (LInt 0))) (EVar "args"))) (arm PWild () (EApp (EApp (EVar "map") (ELam ((PVar "q")) (EApp (EApp (EVar "polMul") (EVar "PInv")) (EVar "q")))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "b")))))))
(DTypeSig false "paramOccPolaritiesArgs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "String") (TyFun (TyCon "Polarity") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "paramOccPolaritiesArgs" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "paramOccPolaritiesArgs" ((PVar "tab") (PVar "p") (PVar "pol") (PVar "headPols") (PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EApp (EApp (EVar "polMul") (EVar "pol")) (EApp (EApp (EVar "polarityAtOr") (EVar "headPols")) (EVar "i")))) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "paramOccPolaritiesArgs") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "headPols")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "polMul" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Polarity"))))
(DFunDef false "polMul" ((PCon "PPhantom") PWild) (EVar "PPhantom"))
(DFunDef false "polMul" (PWild (PCon "PPhantom")) (EVar "PPhantom"))
(DFunDef false "polMul" ((PCon "PInv") PWild) (EVar "PInv"))
(DFunDef false "polMul" (PWild (PCon "PInv")) (EVar "PInv"))
(DFunDef false "polMul" ((PCon "PCo") (PVar "q")) (EVar "q"))
(DFunDef false "polMul" ((PCon "PContra") (PCon "PCo")) (EVar "PContra"))
(DFunDef false "polMul" ((PCon "PContra") (PCon "PContra")) (EVar "PCo"))
(DTypeSig false "joinPolarities" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Polarity")))
(DFunDef false "joinPolarities" ((PList)) (EVar "PPhantom"))
(DFunDef false "joinPolarities" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "joinPolaritiesGo") (EVar "q")) (EVar "rest")))
(DTypeSig false "joinPolaritiesGo" (TyFun (TyCon "Polarity") (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Polarity"))))
(DFunDef false "joinPolaritiesGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinPolaritiesGo" ((PCon "PInv") PWild) (EVar "PInv"))
(DFunDef false "joinPolaritiesGo" ((PVar "acc") (PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "joinPolaritiesGo") (EApp (EApp (EVar "polJoin") (EVar "acc")) (EVar "q"))) (EVar "rest")))
(DTypeSig false "polJoin" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Polarity"))))
(DFunDef false "polJoin" ((PCon "PPhantom") (PVar "q")) (EVar "q"))
(DFunDef false "polJoin" ((PVar "q") (PCon "PPhantom")) (EVar "q"))
(DFunDef false "polJoin" ((PCon "PCo") (PCon "PCo")) (EVar "PCo"))
(DFunDef false "polJoin" ((PCon "PContra") (PCon "PContra")) (EVar "PContra"))
(DFunDef false "polJoin" (PWild PWild) (EVar "PInv"))
(DTypeSig false "polarityAtOr" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyCon "Int") (TyCon "Polarity"))))
(DFunDef false "polarityAtOr" ((PCon "None") PWild) (EVar "PCo"))
(DFunDef false "polarityAtOr" ((PCon "Some" (PVar "pols")) (PVar "i")) (EApp (EApp (EVar "polarityAt") (EVar "pols")) (EVar "i")))
(DTypeSig true "payloadAstTypes" (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "payloadAstTypes" ((PCon "ConPos" (PVar "tys"))) (EVar "tys"))
(DFunDef false "payloadAstTypes" ((PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EVar "map") (EVar "fieldTyOf")) (EVar "fields")))
(DTypeSig false "fieldTyOf" (TyFun (TyCon "Field") (TyCon "Ty")))
(DFunDef false "fieldTyOf" ((PCon "Field" PWild (PVar "ty"))) (EVar "ty"))
(DTypeSig true "seedParamPolarityFixpointScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "seedParamPolarityFixpointScoped" ((PVar "mctx") (PVar "ds") (PVar "allDs")) (EBlock (DoLet false false (PVar "cur") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value")) (DoLet false false (PVar "allKeyIndex") (EApp (EVar "tabKeyIndex") (EApp (EVar "declPolarityKeys") (EVar "allDs")))) (DoLet false false (PVar "curIndex") (EApp (EVar "tabKeyIndex") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EVar "allKeyIndex")) (EApp (EVar "fst") (EVar "e"))))) (EVar "cur"))))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "declHasPolarityEntry") (EVar "curIndex")) (EVar "d"))))) (EVar "allDs"))) (DoLet false false (PVar "full") (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "cur")) (EVar "fresh"))) (DoLet false false (PVar "keyIndex") (EApp (EVar "tabKeyIndex") (EApp (EVar "declPolarityKeys") (EVar "ds")))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EVar "keyIndex")) (EApp (EVar "fst") (EVar "e"))))) (EVar "full"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EBinOp "++" (EVar "kept") (EVar "cur"))))))
(DTypeSig false "declHasPolarityEntry" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declHasPolarityEntry" ((PVar "index") (PVar "d")) (EMatch (EApp (EVar "declPolarityKeys") (EListLit (EVar "d"))) (arm (PList) () (EVar "False")) (arm (PCons (PVar "k") PWild) () (EApp (EApp (EVar "tabKeyIndexHas") (EVar "index")) (EVar "k")))))
(DTypeSig false "declPolarityKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "declPolarityKeys" ((PList)) (EListLit))
(DFunDef false "declPolarityKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "declPolarityKeys") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "declPolarityKeys") (EVar "rest")))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "Polarity" true) (mem "Predicate" true) (mem "Windowed" true) (mem "DeclEnvModule" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tyAppSpine" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declEnvVisibleTo" false) (mem "padAnns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "polarityAt" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "DataVis" true) (mem "Decl" true) (mem "Field" true) (mem "KindAnn" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "tabKeyEq" false) (mem "tabKeyName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "listLen" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "indexed" false) (mem "sortOn" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "paramPolaritiesIn" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DTypeSig true "declEnvPolarityChain" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "declEnvPolarityChain" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvPolarityChain" ((PCons (PVar "m") (PVar "rest")) (PTuple (PVar "pacc") (PVar "pm"))) (EBlock (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "declEnvRowPolarityEntries") (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m")) (EVar "pacc"))) (DoExpr (EApp (EApp (EVar "declEnvPolarityChain") (EVar "rest")) (ETuple (EBinOp "++" (EVar "entries") (EVar "pacc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EVar "pacc")) (EVar "pm")))))))
(DTypeSig false "declEnvRowPolarityEntries" (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity"))))))))
(DFunDef false "declEnvRowPolarityEntries" ((PVar "cur") (PVar "m") (PVar "tab")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "tab")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EApp (EApp (EVar "polarityEntriesPublicOnly") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "tab")) (EFieldAccess (EVar "m") "demDecls"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "polarityEntriesPublicOnly" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "polarityEntriesPublicOnly" ((PVar "decls") (PVar "entries")) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "polarityPublicKeys") (EVar "decls"))) (DoLet false false (PVar "index") (EApp (EVar "tabKeyIndex") (EVar "keys"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EMethodRef "index")) (EApp (EVar "fst") (EVar "e"))))) (EVar "entries")))))
(DTypeSig false "polarityPublicKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "polarityPublicKeys" ((PList)) (EListLit))
(DFunDef false "polarityPublicKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "polarityPublicKeys") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "polarityPublicKeys") (EVar "rest"))))
(DFunDef false "polarityPublicKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "polarityPublicKeys") (EVar "rest")))
(DTypeSig false "tabKeyIndex" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey")))))
(DFunDef false "tabKeyIndex" ((PVar "keys")) (EApp (EApp (EVar "tabKeyIndexGo") (EVar "keys")) (EVar "omEmpty")))
(DTypeSig false "tabKeyIndexGo" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))))))
(DFunDef false "tabKeyIndexGo" ((PList) (PVar "index")) (EMethodRef "index"))
(DFunDef false "tabKeyIndexGo" ((PCons (PVar "k") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "tabKeyName") (EVar "k"))) (DoLet false false (PVar "bucket") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EMethodRef "index")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "tabKeyIndexGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "k") (EVar "bucket"))) (EMethodRef "index"))))))
(DTypeSig false "tabKeyIndexHas" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "tabKeyIndexHas" ((PVar "index") (PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "tabKeyName") (EVar "key"))) (EMethodRef "index")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "bucket")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "bucket")))))
(DTypeSig false "declEnvPolarityEntriesFix" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "declEnvPolarityEntriesFix" ((PVar "base") (PVar "ds")) (EBlock (DoLet false false (PVar "ordered") (EApp (EVar "polarityDependencyOrder") (EVar "ds"))) (DoLet false false (PVar "odecls") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ordered"))) (DoLet false false (PVar "first") (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "base")) (EVar "odecls"))) (DoLet false false (PVar "bottom") (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "PPhantom"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "first"))) (DoLet false false (PVar "height") (EBinOp "+" (EBinOp "*" (ELit (LInt 3)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "e")) (EBinOp "+" (EVar "n") (EApp (EVar "listLen") (EApp (EVar "snd") (EVar "e")))))) (ELit (LInt 0))) (EVar "first"))) (ELit (LInt 3)))) (DoLet false false (PVar "settled") (EApp (EApp (EApp (EApp (EVar "declEnvPolarityFixGo") (EVar "base")) (EVar "odecls")) (EVar "height")) (EVar "bottom"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "ie")) (ETuple (EApp (EVar "fst") (EApp (EVar "snd") (EVar "ie"))) (EApp (EApp (EMethodRef "map") (EVar "publishedPolarity")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "ie"))))))) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "zipL") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ordered"))) (EVar "settled")))))))
(DTypeSig false "polarityDependencyOrder" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Decl")))))
(DFunDef false "polarityDependencyOrder" ((PVar "ds")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "ide")) (EApp (EVar "isSome") (EApp (EVar "polarityDeclInfo") (EApp (EVar "snd") (EVar "ide")))))) (EApp (EVar "indexed") (EVar "ds")))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ide")) (EApp (EVar "fst") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide")))))) (EVar "named"))) (DoLet false false (PVar "known") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "ide")) (EBlock (DoLet false false (PVar "ht") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "ht"))) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "known")))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "t")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "a")))) (EListLit)) (EApp (EVar "snd") (EVar "ht")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "ht"))) (EVar "acc"))))) (EVar "acc")))))) (EVar "omEmpty")) (EVar "named"))) (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "ide")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "fst") (EApp (EVar "polarityDeclHeadAndTys") (EApp (EVar "snd") (EVar "ide"))))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "ide") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc"))))) (EVar "acc")))))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "named")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "buckets"))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "scc")) (EVar "scc"))) (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EVar "adj")))))))
(DTypeSig false "polarityDeclInfo" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "polarityDeclInfo" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "polarityDeclInfo") (EVar "d")))
(DFunDef false "polarityDeclInfo" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "vs")))))
(DFunDef false "polarityDeclInfo" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeFieldTy" (PVar "fty"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EListLit (EVar "fty")))))
(DFunDef false "polarityDeclInfo" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EListLit (EVar "rhs")))))
(DFunDef false "polarityDeclInfo" (PWild) (EVar "None"))
(DTypeSig false "polarityDeclHeadAndTys" (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "polarityDeclHeadAndTys" ((PVar "d")) (EApp (EApp (EVar "optionOr") (ETuple (ELit (LString "")) (EListLit))) (EApp (EVar "polarityDeclInfo") (EVar "d"))))
(DTypeSig false "polarityTyConNames" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "polarityTyConNames" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) (PVar "acc")) (EBinOp "::" (EVar "n") (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "a")) (EApp (EApp (EVar "polarityTyConNames") (EVar "b")) (EVar "acc"))))
(DFunDef false "polarityTyConNames" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "a")) (EApp (EApp (EVar "polarityTyConNames") (EVar "b")) (EVar "acc"))))
(DFunDef false "polarityTyConNames" ((PCon "TyTuple" (PVar "ts")) (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "t")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "a")))) (EVar "acc")) (EVar "ts")))
(DFunDef false "polarityTyConNames" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "acc")) (EApp (EApp (EVar "polarityTyConNames") (EVar "t")) (EVar "acc")))
(DFunDef false "polarityTyConNames" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "declEnvPolarityFixGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "declEnvPolarityFixGo" ((PVar "base") (PVar "ds") (PVar "fuel") (PVar "prev")) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "PInv"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "prev")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "++" (EVar "prev") (EVar "base"))) (EVar "ds"))) (DoExpr (EIf (EApp (EApp (EVar "polarityEntriesEq") (EVar "prev")) (EVar "next")) (EVar "prev") (EApp (EApp (EApp (EApp (EVar "declEnvPolarityFixGo") (EVar "base")) (EVar "ds")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "next")))))))
(DTypeSig false "publishedPolarity" (TyFun (TyCon "Polarity") (TyCon "Polarity")))
(DFunDef false "publishedPolarity" ((PCon "PPhantom")) (EVar "PCo"))
(DFunDef false "publishedPolarity" ((PVar "q")) (EVar "q"))
(DTypeSig false "polarityEntriesEq" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyCon "Bool"))))
(DFunDef false "polarityEntriesEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "polarityEntriesEq" ((PCons (PTuple (PVar "k1") (PVar "p1")) (PVar "r1")) (PCons (PTuple (PVar "k2") (PVar "p2")) (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "tabKeyEq") (EVar "k1")) (EVar "k2")) (EApp (EApp (EVar "polaritiesEq") (EVar "p1")) (EVar "p2"))) (EApp (EApp (EVar "polarityEntriesEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "polarityEntriesEq" (PWild PWild) (EVar "False"))
(DTypeSig false "polaritiesEq" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Bool"))))
(DFunDef false "polaritiesEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "polaritiesEq" ((PCons (PVar "q1") (PVar "r1")) (PCons (PVar "q2") (PVar "r2"))) (EBinOp "&&" (EApp (EApp (EVar "polarityEq") (EVar "q1")) (EVar "q2")) (EApp (EApp (EVar "polaritiesEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "polaritiesEq" (PWild PWild) (EVar "False"))
(DTypeSig false "polarityEq" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Bool"))))
(DFunDef false "polarityEq" ((PCon "PCo") (PCon "PCo")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PContra") (PCon "PContra")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PInv") (PCon "PInv")) (EVar "True"))
(DFunDef false "polarityEq" ((PCon "PPhantom") (PCon "PPhantom")) (EVar "True"))
(DFunDef false "polarityEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declEnvPolarityEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "declEnvPolarityEntries" (PWild (PList)) (EListLit))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "tab")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "vs")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EVar "vs")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EVar "tab")) (EVar "ps")) (EVar "ks")) (EListLit (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EVar "ConPos") (EListLit (EVar "rhs")))))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "declEnvPolarityEntries") (EBinOp "::" (EVar "entry") (EVar "tab"))) (EVar "rest"))))))
(DFunDef false "declEnvPolarityEntries" ((PVar "tab") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvPolarityEntries") (EVar "tab")) (EVar "rest")))
(DTypeSig true "recordParamPolarities" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Unit"))))))
(DFunDef false "recordParamPolarities" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "pols")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "publishedPolarity")) (EVar "pols")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value"))))))
(DTypeSig true "inferParamPolarities" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "inferParamPolarities" ((PVar "tab") (PVar "params") (PVar "anns") (PVar "variants")) (EBlock (DoLet false false (PVar "fieldTys") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "variants"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "pk")) (EMatch (EApp (EVar "snd") (EVar "pk")) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EVar "PInv")) (arm PWild () (EApp (EVar "joinPolarities") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EApp (EVar "fst") (EVar "pk"))) (EVar "PCo")) (EVar "t")))) (EVar "fieldTys"))))))) (EApp (EApp (EVar "zipL") (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns")))))))
(DTypeSig true "variantPayload" (TyFun (TyCon "Variant") (TyCon "ConPayload")))
(DFunDef false "variantPayload" ((PCon "Variant" PWild (PVar "payload"))) (EVar "payload"))
(DTypeSig false "paramOccPolarities" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "String") (TyFun (TyCon "Polarity") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Polarity")))))))
(DFunDef false "paramOccPolarities" (PWild (PVar "p") (PVar "pol") (PCon "TyVar" (PVar "n"))) (EIf (EBinOp "==" (EVar "n") (EVar "p")) (EListLit (EVar "pol")) (EListLit)))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EApp (EApp (EVar "polMul") (EVar "pol")) (EVar "PContra"))) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "b"))))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol"))) (EVar "ts")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "paramOccPolarities" (PWild PWild PWild (PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "t")))
(DFunDef false "paramOccPolarities" ((PVar "tab") (PVar "p") (PVar "pol") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "paramOccPolaritiesArgs") (EVar "tab")) (EVar "p")) (EVar "pol")) (EApp (EApp (EVar "paramPolaritiesIn") (EVar "tab")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")))) (ELit (LInt 0))) (EVar "args"))) (arm PWild () (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (EApp (EApp (EVar "polMul") (EVar "PInv")) (EVar "q")))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "b")))))))
(DTypeSig false "paramOccPolaritiesArgs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "String") (TyFun (TyCon "Polarity") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Polarity")))))))))
(DFunDef false "paramOccPolaritiesArgs" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "paramOccPolaritiesArgs" ((PVar "tab") (PVar "p") (PVar "pol") (PVar "headPols") (PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramOccPolarities") (EVar "tab")) (EVar "p")) (EApp (EApp (EVar "polMul") (EVar "pol")) (EApp (EApp (EVar "polarityAtOr") (EVar "headPols")) (EVar "i")))) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "paramOccPolaritiesArgs") (EVar "tab")) (EVar "p")) (EVar "pol")) (EVar "headPols")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "polMul" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Polarity"))))
(DFunDef false "polMul" ((PCon "PPhantom") PWild) (EVar "PPhantom"))
(DFunDef false "polMul" (PWild (PCon "PPhantom")) (EVar "PPhantom"))
(DFunDef false "polMul" ((PCon "PInv") PWild) (EVar "PInv"))
(DFunDef false "polMul" (PWild (PCon "PInv")) (EVar "PInv"))
(DFunDef false "polMul" ((PCon "PCo") (PVar "q")) (EVar "q"))
(DFunDef false "polMul" ((PCon "PContra") (PCon "PCo")) (EVar "PContra"))
(DFunDef false "polMul" ((PCon "PContra") (PCon "PContra")) (EVar "PCo"))
(DTypeSig false "joinPolarities" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Polarity")))
(DFunDef false "joinPolarities" ((PList)) (EVar "PPhantom"))
(DFunDef false "joinPolarities" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "joinPolaritiesGo") (EVar "q")) (EVar "rest")))
(DTypeSig false "joinPolaritiesGo" (TyFun (TyCon "Polarity") (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyCon "Polarity"))))
(DFunDef false "joinPolaritiesGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinPolaritiesGo" ((PCon "PInv") PWild) (EVar "PInv"))
(DFunDef false "joinPolaritiesGo" ((PVar "acc") (PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "joinPolaritiesGo") (EApp (EApp (EVar "polJoin") (EVar "acc")) (EVar "q"))) (EVar "rest")))
(DTypeSig false "polJoin" (TyFun (TyCon "Polarity") (TyFun (TyCon "Polarity") (TyCon "Polarity"))))
(DFunDef false "polJoin" ((PCon "PPhantom") (PVar "q")) (EVar "q"))
(DFunDef false "polJoin" ((PVar "q") (PCon "PPhantom")) (EVar "q"))
(DFunDef false "polJoin" ((PCon "PCo") (PCon "PCo")) (EVar "PCo"))
(DFunDef false "polJoin" ((PCon "PContra") (PCon "PContra")) (EVar "PContra"))
(DFunDef false "polJoin" (PWild PWild) (EVar "PInv"))
(DTypeSig false "polarityAtOr" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyCon "Int") (TyCon "Polarity"))))
(DFunDef false "polarityAtOr" ((PCon "None") PWild) (EVar "PCo"))
(DFunDef false "polarityAtOr" ((PCon "Some" (PVar "pols")) (PVar "i")) (EApp (EApp (EVar "polarityAt") (EVar "pols")) (EVar "i")))
(DTypeSig true "payloadAstTypes" (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "payloadAstTypes" ((PCon "ConPos" (PVar "tys"))) (EVar "tys"))
(DFunDef false "payloadAstTypes" ((PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EMethodRef "map") (EVar "fieldTyOf")) (EVar "fields")))
(DTypeSig false "fieldTyOf" (TyFun (TyCon "Field") (TyCon "Ty")))
(DFunDef false "fieldTyOf" ((PCon "Field" PWild (PVar "ty"))) (EVar "ty"))
(DTypeSig true "seedParamPolarityFixpointScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "seedParamPolarityFixpointScoped" ((PVar "mctx") (PVar "ds") (PVar "allDs")) (EBlock (DoLet false false (PVar "cur") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value")) (DoLet false false (PVar "allKeyIndex") (EApp (EVar "tabKeyIndex") (EApp (EVar "declPolarityKeys") (EVar "allDs")))) (DoLet false false (PVar "curIndex") (EApp (EVar "tabKeyIndex") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EVar "allKeyIndex")) (EApp (EVar "fst") (EVar "e"))))) (EVar "cur"))))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "declHasPolarityEntry") (EVar "curIndex")) (EVar "d"))))) (EVar "allDs"))) (DoLet false false (PVar "full") (EApp (EApp (EVar "declEnvPolarityEntriesFix") (EVar "cur")) (EVar "fresh"))) (DoLet false false (PVar "keyIndex") (EApp (EVar "tabKeyIndex") (EApp (EVar "declPolarityKeys") (EVar "ds")))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "tabKeyIndexHas") (EVar "keyIndex")) (EApp (EVar "fst") (EVar "e"))))) (EVar "full"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EBinOp "++" (EVar "kept") (EVar "cur"))))))
(DTypeSig false "declHasPolarityEntry" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "TabKey"))) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declHasPolarityEntry" ((PVar "index") (PVar "d")) (EMatch (EApp (EVar "declPolarityKeys") (EListLit (EVar "d"))) (arm (PList) () (EVar "False")) (arm (PCons (PVar "k") PWild) () (EApp (EApp (EVar "tabKeyIndexHas") (EMethodRef "index")) (EVar "k")))))
(DTypeSig false "declPolarityKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "declPolarityKeys" ((PList)) (EListLit))
(DFunDef false "declPolarityKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "declPolarityKeys") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EVar "declPolarityKeys") (EVar "rest"))))
(DFunDef false "declPolarityKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "declPolarityKeys") (EVar "rest")))
