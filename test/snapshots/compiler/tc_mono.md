# META
source_lines=2240
stages=DESUGAR,MARK
# SOURCE
-- tc_mono: operations over `Mono`/`Scheme`, pure except for minting effect-variable ids from the
-- graph-run counter: head inspection, variable ids, substitution, one-way matching and overlap, the
-- builtin tycons, the `Scheme` projections (`schemeIds`, `schemeMono`, `schemeBodyOf`,
-- `schemeAuthIds`), and the signature-slot and obligation-argument readings of a `Mono`
-- (`unrigidSig`, `abstractSlotIds`, `declaredOblArgOk`, `oblArgKey`).
--
-- Spec: HM-CORE section 2 (owed, #2555); DICT section 3 (specificity is matching).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_state`, `tc_env`,
-- `tc_diag`, `tc_diag_text`, `tc_scope`, `tc_unify`, `tc_decls_variance`, `tc_decls_types`, `tc_decls`,
-- `tc_foreign`, `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`,
-- `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`,
-- `tc_global`, `tc_module`.

import frontend.ast.{
  Decl(..),
  EffAtomTy(..),
  Ident(..),
  Lit(..),
  Loc(..),
  Ns(..),
  Pat(..),
  PropParam(..),
  RecPatField(..),
  Require(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  identOriginFold,
  propParamName,
  sameTyConHead,
}
import types.repr.{
  IfaceRef(..),
  Mono(..),
  Scheme(..),
  Tyvar(..),
  lookupAssocI,
  normalize,
  normalizeLink,
  ppGo,
  tupleHeadTagTc,
  tupleSpine,
}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  authIsTop,
  authJoinAll,
  authNorm,
  authSub,
  authvarId,
  authVars,
}
import types.effect_rows.{
  Atom(..),
  EffRow(..),
  Effvar(..),
  atomAuth,
  atomKey,
  atomsNorm,
  effrowNorm,
  effvarId,
  findAtom,
  pureRow,
  rowFlat,
}
import types.tc_types.{
  AbsorptionEvent(..), GoalPayload(..), GraphCtx(..), HeadVarRoot(..),
  MethodReturnRequest(..), MStep(..), Obligation(..), Predicate(..),
  RecordInfo(..), SiteKind(..), Windowed(..)
}
import map as IdMap
import map.{Map(..)}
import support.ordmap.{omEmpty, omFromNames, omHasKey, OrdMap}
import support.util.{
  allList,
  anyList,
  contains,
  eqStr,
  filterList,
  isSome,
  joinWith,
  lenKey,
  listLen,
  minI,
  orElseOpt,
  reverseL,
  zipL,
}
import types.registry.{HeadKey(..), headKeyIdent, headKeyOfCon, headKeyTag}
import types.route_key.{funHeadTag}
import types.invocation_basis.{authorityParamSubst}
import types.solver_contract.{Instantiation(..), Wanted(..)}
import list.{take}

export
effectCells : Mono -> Map Int (Ref Effvar) -> Map Int (Ref Effvar)
effectCells mono cells = match normalize mono
  TFun a row b => effectCells b (effectCells a (effectRowCells row cells))
  TApp a b => effectCells b (effectCells a cells)
  TEff row => effectRowCells row cells
  TQual a _ => effectCells a cells
  TAuth _ => cells
  _ => cells

effectRowCells : EffRow -> Map Int (Ref Effvar) -> Map Int (Ref Effvar)
effectRowCells row cells =
  fold
    (acc cell => match !cell
      EUnbound id _ => IdMap.set id cell acc
      _ => acc)
    cells
    (snd (rowFlat row))

export
cellIdSet : List (Ref Effvar) -> Map Int Unit
cellIdSet cells = cellIdSetGo cells Tip

cellIdSetGo : List (Ref Effvar) -> Map Int Unit -> Map Int Unit
cellIdSetGo [] ids = ids
cellIdSetGo (cell :: cells) ids =
  cellIdSetGo cells (IdMap.set (effvarId cell) () ids)

export
nthArgMono : Int -> Mono -> Option Mono
nthArgMono 0 m = match normalize m
  TFun a _ _ => Some a
  _ => None
nthArgMono n m = match normalize m
  TFun _ _ b => nthArgMono (n - 1) b
  _ => None

export
containsI : Int -> List Int -> Bool
containsI _ [] = False
containsI x (y :: ys) = x == y || containsI x ys

export
invocationHeadKey : Mono -> String
invocationHeadKey h = match headTyconMono h
  Some hk => headKeyTag hk
  None => "?"

-- A constructor's fields at an application's authority arguments: each
-- declared authority parameter is replaced by the argument in its slot.  A
-- type or row argument is left as the declaration's variable; the summary
-- charges it where it lands, by the slot's variance.
export
instantiateFields : GraphCtx -> List Mono -> (List Mono, List Mono) -> List Mono
instantiateFields gctx args (params, fieldTys) =
  let asub = authorityParamSubst params args
  map (substMono gctx [] [] asub) fieldTys

export
isPreludeOrigin : TyConOrigin -> Bool
isPreludeOrigin (OriginModule m) = m == "core"
isPreludeOrigin _ = False

-- The two sides' application heads, when they are same-spelled type
-- constructors of different declarations.
export
headIdConflict : Mono -> Mono -> Option (String, TyConOrigin, TyConOrigin)
headIdConflict a b = tconIdConflict (spineHead a) (spineHead b)

export
spineHead : Mono -> Mono
spineHead t = match normalize t
  TApp f _ => spineHead f
  other => other

-- The FIRST head, in a parallel structural walk of the two monos, whose name
-- agrees while its identity does not.  Parallel and shape-guarded on purpose:
-- the two sides render identically (the caller's precondition), so they have
-- the same shape, and walking them together is what pairs the conflicting head
-- with its counterpart rather than reporting some unrelated head.
export
firstIdConflict : Mono -> Mono -> Option (String, TyConOrigin, TyConOrigin)
firstIdConflict a b = match (normalize a, normalize b)
  (TApp f1 x1, TApp f2 x2) =>
    orElseOpt (firstIdConflict f1 f2) (firstIdConflict x1 x2)
  (TFun d1 _ r1, TFun d2 _ r2) =>
    orElseOpt (firstIdConflict d1 d2) (firstIdConflict r1 r2)
  (x, y) => tconIdConflict x y

-- Two same-spelled type constructors of different declarations: the one
-- place a conflict of identities is read off a pair of heads.
tconIdConflict : Mono -> Mono -> Option (String, TyConOrigin, TyConOrigin)
tconIdConflict a b = match (normalize a, normalize b)
  (TCon n1 o1, TCon n2 o2) =>
    if n1 == n2 && not (sameTyConHead n1 o1 n2 o2) then
      Some (n1, o1, o2)
    else
      None
  _ => None

-- The variables a caller can supply through the published type: every
-- authority an ARGUMENT carries — a qualified slot (`String @κ`), an index
-- (`Handle κ`) or a row (`Unit -> <L κ> Unit`) — at any depth of an arrow's
-- domain.  A result position supplies nothing: `Unit -> Tok κ` would let a
-- caller choose the index of a value that carries no evidence for it.
export
qualifierAuthIds : Mono -> Map Int Unit -> Map Int Unit
qualifierAuthIds t acc = match normalize t
  TFun a _ b => qualifierAuthIds b (authIdsIn a acc)
  TApp a b => qualifierAuthIds b (qualifierAuthIds a acc)
  TQual inner _ => qualifierAuthIds inner acc
  _ => acc

-- Every authority a type mentions, at any depth: qualifiers, indices and the
-- atoms of every row.
export
authIdsIn : Mono -> Map Int Unit -> Map Int Unit
authIdsIn t acc = match normalize t
  TFun a row b => authIdsIn b (authIdsIn a (rowAuthIds row acc))
  TApp a b => authIdsIn b (authIdsIn a acc)
  TEff row => rowAuthIds row acc
  TQual inner q => authIdsIn inner (authTermIds q acc)
  TAuth q => authTermIds q acc
  _ => acc

rowAuthIds : EffRow -> Map Int Unit -> Map Int Unit
rowAuthIds row acc =
  fold (m atom => authTermIds (atomAuth atom) m) acc (fst (rowFlat row))

authTermIds : Authority -> Map Int Unit -> Map Int Unit
authTermIds q acc =
  fold (m cell => IdMap.set (authvarId cell) () m) acc (authVars q)

export
authvarIdOf : (String, Ref Authvar) -> Int
authvarIdOf (_, cell) = authvarId cell

export
effvarIdOf : (String, Ref Effvar) -> Int
effvarIdOf (_, cell) = effvarId cell

export
litType : Lit -> Mono
litType (LInt _) = tconBuiltin "Int"
litType (LFloat _) = tconBuiltin "Float"
litType (LString _) = tconBuiltin "String"
litType (LChar _) = tconBuiltin "Char"
litType (LBool _) = tconBuiltin "Bool"
litType LUnit = tconBuiltin "Unit"
litType (LU64 _ _) = tconBuiltin "U64"
litType (LI64 _ _) = tconBuiltin "I64"

export
foldrFun : List Mono -> Mono -> Mono
foldrFun [] result = result
foldrFun (a :: rest) result = TFun a pureRow (foldrFun rest result)

export
authOrderIn : Mono -> List Int -> List Int
authOrderIn t acc = match normalize t
  TFun a row b => authOrderIn b (authOrderRow row (authOrderIn a acc))
  TApp a b => authOrderIn b (authOrderIn a acc)
  TEff row => authOrderRow row acc
  TQual inner q => authOrderTerm q (authOrderIn inner acc)
  TAuth q => authOrderTerm q acc
  _ => acc

export
authOrderRow : EffRow -> List Int -> List Int
authOrderRow row acc =
  fold (a atom => authOrderTerm (atomAuth atom) a) acc (fst (rowFlat row))

authOrderTerm : Authority -> List Int -> List Int
authOrderTerm q acc =
  fold
    (a cell =>
      let i = authvarId cell
      if containsI i a then a else i :: a)
    acc
    (authVars q)

-- the ids a cross-module argument defers on: the id itself for a bare tyvar, every
-- tyvar leaf for a structured one (#1937), none for a ground one.  There is no
-- scheme-bound-id set on this side of the boundary, so unlike `declaredOblArgId` this
-- cannot filter — `substOblArgs`' fail-closed lookup is what refuses an id the call's
-- instantiation does not carry.
export
xmodOblArgId : Mono -> List Int
xmodOblArgId m = match normalize m
  TVar cell => [tyvarId cell]
  _ => monoTyvarIds m

-- #1937 (structured predicate carry): this walk used to substitute ONLY at a TOP-LEVEL
-- `TVar` and pass anything else through untouched, which is why the admission pair
-- (`declaredOblArgOk`) could not admit a structured argument: `Conv (Wrap a) b` would
-- have carried the DEFINING signature's `a` cell into the caller's goal unsubstituted,
-- the wrong-but-concrete goal its header calls strictly worse than a missing one.  It
-- now recurses through `TApp`/`TFun` and substitutes at every `TVar` LEAF, so
-- `Conv (Wrap a) b` at a call instantiating `a := Char, b := Bool` becomes the goal
-- `Conv (Wrap Char) Bool` — the shape #1937 is about.  A leaf among the entry's own
-- ids [ids] that [subst] does not map still fails CLOSED for the whole predicate,
-- exactly as the top-level arm always did.  A leaf outside [ids] is a variable the
-- scheme does not quantify (`residualMixedPred`), the same at every use, so it is
-- kept as itself.
export
substOblArgs : List Int -> List Mono -> List (Int, Mono) -> Option (List Mono)
substOblArgs _ [] _ = Some []
substOblArgs ids (m :: rest) subst = match substOblArg ids m subst
  None => None
  Some m2 => map (m2 :: _) (substOblArgs ids rest subst)

-- ONE predicate argument under [subst]: every tyvar leaf mapped, structure preserved.
substOblArg : List Int -> Mono -> List (Int, Mono) -> Option Mono
substOblArg ids m subst = match normalize m
  TVar cell => match lookupAssocI (tyvarId cell) subst
    Some m2 => Some m2
    None => if containsI (tyvarId cell) ids then None else Some (TVar cell)
  TQual a q => map (a2 => TQual a2 q) (substOblArg ids a subst)
  TApp a b => match substOblArg ids a subst
    None => None
    Some a2 => map (b2 => TApp a2 b2) (substOblArg ids b subst)
  TFun a eff b => match substOblArg ids a subst
    None => None
    Some a2 => map (b2 => TFun a2 eff b2) (substOblArg ids b subst)
  other => Some other

-- the monos [ids] map to under [subst], in order; None if any id is unmapped.
export
substMonos : List Int -> List (Int, Mono) -> Option (List Mono)
substMonos [] _ = Some []
substMonos (id :: rest) subst = match lookupAssocI id subst
  Some mono => map (mono :: _) (substMonos rest subst)
  None => None

-- the k-th domain of a (possibly curried) function type — `nthFunDomain 0` is the
-- receiver of an index-0 dispatch, which is what every pre-#1815 caller asked for.
export
nthFunDomain : Int -> Mono -> Option Mono
nthFunDomain k m = match normalize m
  TFun a _ r => if k == 0 then Some a else nthFunDomain (k - 1) r
  _ => None

-- peel up to `n` arrow domains off the (normalized) lambda's expected type; those
-- domains are the lambda's expected PARAM types.  Stops early if it is not (yet)
-- an arrow — those params fall back to a fresh var in inferLamChecked, and the
-- trailing `unify ft (TFun xt …)` reconciles them.
export
expectedParamTypes : Mono -> Int -> List Mono
expectedParamTypes _ 0 = []
expectedParamTypes (TFun a _ b) n =
  a :: expectedParamTypes (normalize b) (n - 1)
expectedParamTypes _ _ = []

-- Batch B #6 reframe (2026-07-04): a container-consuming HOF whose next declared
-- parameter is a higher-kinded container `f a` (an unresolved tyvar head applied
-- to an element, i.e. `TApp (TVar …) elem`) is being handed a SCALAR argument —
-- a bare arity-0 type (`String`/`Int`/…) that has no element slot for `f` to
-- bind.  Left to the generic `unify (f a) String` sink it leaks a raw
-- tyvar-application `Type mismatch: a b vs String`.  This detector recognises the
-- shape UPSTREAM (in inferApp, where the callee name + arg loc are still in
-- scope) so the diagnostic can be reframed as container-vs-scalar.  SOUND: a
-- `TApp _ _ ~ TCon n` unification can only ever FAIL — a genuine container arg is
-- itself a `TApp` (`List a`, `Maybe a`, …) and would UNIFY the element, never
-- reaching a mismatch; the reframe therefore never hijacks a legitimate
-- higher-kinded mismatch.  Returns the scalar type's name when it fires.
export
containerParamScalarArg : Mono -> Mono -> Option String
containerParamScalarArg ft xt = match normalize ft
  TFun dom _ _ => match normalize dom
    TApp _ _ => match headTyconNameMono dom
      None => match normalize xt
        TCon n _ => Some n
        -- answer-preserving (#1110): a rigid used to arrive here as `TCon n`
        -- and named itself in the container-vs-scalar reframe.
        TRigid n => Some n
        _ => None
      Some _ => None
    _ => None
  _ => None

-- number of leading `->` arrows in a (normalized) type — its curried arity.
export
funArity : Mono -> Int
funArity m = match normalize m
  TFun _ _ r => 1 + funArity r
  _ => 0

-- True iff [ft]'s first parameter is itself an arity-[n] tuple type — the genuine
-- "the tuple IS the intended single argument" shape (e.g. `f (a, b) c = …`), which
-- must NOT be flagged.  Read on the PRISTINE ft (before inferApp unifies its domain
-- with the tuple arg), so the domain here is the declared param type.
export
domainIsTupleOfArity : Mono -> Int -> Bool
domainIsTupleOfArity ft n = match normalize ft
  TFun dom _ _ => match headTyconNameMono dom
    Some c => c == "__tuple\{intToString n}__"
    None => False
  _ => False

export
isUnshaped : Mono -> Bool
isUnshaped t = match normalize t
  TVar _ => True
  _ => False

-- The record's authority cells, by id: the head's in the result, a
-- constructor binder's in the fields.
export
recordAuthCells : List Int ->
  Mono ->
  List (String, Mono) ->
  Map Int (Ref Authvar)
recordAuthCells [] _ _ = Tip
recordAuthCells _ result fields =
  fold (m f => authCellsIn (snd f) m) (authCellsIn result Tip) fields

export
applyParams : Mono -> List Mono -> Mono
applyParams head [] = head
applyParams head (p :: ps) = applyParams (TApp head p) ps

-- Two monos genuinely CANNOT unify because a tuple spine meets a differing
-- concrete head/arity — used only to pick the readable full-type mismatch
-- message.  A TVar-headed other side returns False (it can still bind).
export
tupleUnifyClash : Mono -> Mono -> Bool
tupleUnifyClash a b = match (tupleSpine a, tupleSpine b)
  (Some xs, Some ys) => listLen xs /= listLen ys
  (Some _, None) => monoSpineHeadIsCon b
  (None, Some _) => monoSpineHeadIsCon a
  (None, None) => False

export
instantiateNamedMonos : GraphCtx ->
  List (String, Mono) ->
  List (Int, Mono) ->
  List (String, Mono)
instantiateNamedMonos gctx [] _ = []
instantiateNamedMonos gctx ((name, mono) :: rest) subst =
  (name, substMono gctx subst [] [] mono)
    :: instantiateNamedMonos gctx rest subst

-- [args] unified with the first `listLen args` of [heads] in a scratch
-- substitution, every variable in [rigidIds] held rigid.
export
headsUnifier : GraphCtx ->
  OrdMap Unit ->
  List Mono ->
  List Mono ->
  Option (Ref (List (Int, Mono)))
headsUnifier gctx rigidIds args allHeads =
  let heads = take (listLen args) allHeads
  let scratch = Ref []
  if listLen heads == listLen args
    && cohOverlapGo scratch (rigidSigPairs gctx rigidIds (zipL args heads)) then
    Some scratch
  else
    None

-- the effect rows on each arrow of a Mono arrow spine, outermost first, down to the
-- non-arrow result (length = the type's arity).
export
allArrowEffs : Mono -> List EffRow
allArrowEffs m = match normalize m
  TFun _ eff b => eff :: allArrowEffs b
  _ => []

export
headVarRootOf : Mono -> Option HeadVarRoot
headVarRootOf m = match normalize m
  TVar cell => Some (TypeVarRoot (tyvarId cell))
  TEff row => match effrowNorm row
    EffRow [] (Some cell) => match !cell
      EUnbound id _ => Some (RowVarRoot id)
      _ => None
    _ => None
  _ => None

export
isUnboundTvar : Mono -> Bool
isUnboundTvar m = match normalize m
  TVar _ => True
  _ => False

-- #837 incr2 (Axis A): the value-restricted arm of the old `isBodyLocalScheme`,
-- kept as a pure STRUCTURAL test.  A monomorphic scheme (`Forall [] []`) is never
-- a genuine interface-method occurrence — every real method quantifies at least
-- its interface parameter — so a mono scheme reaching a `recordImplObligation`
-- guard denotes a value-restricted local (a lambda/pattern var, or a
-- value-restricted simple `let`) and must NOT record a method obligation.  This
-- arm is retained verbatim; the old `(name, schemeIds) ∈ bodyLocalSchemesRef`
-- membership arm (generalized locals) is now the ENV is-local flag
-- (`lookupLocalFlag`, §TcEnv), which is lexically scoped and cannot go stale.
export
isMonoScheme : Scheme -> Bool
isMonoScheme (Forall [] [] [] _ _ _) = True
isMonoScheme _ = False

export
unquantifiedAuthIds : Scheme -> Map Int Unit
unquantifiedAuthIds (Forall _ _ auths residual force mono) =
  fold
    (acc id => IdMap.delete id acc)
    (fold
      (acc r => authTermIds r.arUpper (authTermIds r.arLower acc))
      (authIdsIn mono (rowAuthIds force Tip))
      residual)
    auths

-- collect the TVar ids of those entries in tvs that normalize to a TVar
-- (concrete-grounded entries are skipped — only same-TVar collapses are an error)
export
sigTvarIds : List Mono -> List Int
sigTvarIds [] = []
sigTvarIds (m :: rest) = match normalize m
  TVar cell => tyvarId cell :: sigTvarIds rest
  _ => sigTvarIds rest

-- the scheme-quantified ids an argument defers on: the id itself for a BARE tyvar, and
-- since #1937 every scheme-bound tyvar LEAF of a STRUCTURED one (`Wrap a` ⇒ `a`), in
-- leaf order.  `[]` for a ground argument.  Duplicates are kept, exactly as the all-bare
-- path's `boundTyvarIds` keeps them for `Conv a a`.
export
declaredOblArgId : List Int -> Mono -> List Int
declaredOblArgId boundIds m = match normalize m
  TVar cell if containsI (tyvarId cell) boundIds => [tyvarId cell]
  TVar _ => []
  _ => filterList (id => containsI id boundIds) (monoTyvarIds m)

-- the tyvar ids of [monos], in order, iff EVERY mono is a TVar bound by this scheme;
-- None otherwise (a partial vector is a different predicate — never over-reject).
export
boundTyvarIds : List Int -> List Mono -> Option (List Int)
boundTyvarIds _ [] = Some []
boundTyvarIds boundIds (d :: rest) = match normalize d
  TVar cell if containsI (tyvarId cell) boundIds =>
    map (tyvarId cell :: _) (boundTyvarIds boundIds rest)
  _ => None

export
monosTvarIds : List Int -> List Mono -> List Int
monosTvarIds boundIds monos = flatMap (boundTvarId boundIds) monos

-- [mono] normalizing to a tyvar this scheme generalized → that (constraint var)
-- id; a pinned-concrete or foreign var → none
export
boundTvarId : List Int -> Mono -> List Int
boundTvarId boundIds mono = match normalize mono
  TVar cell => if containsI (tyvarId cell) boundIds then [tyvarId cell] else []
  _ => []

-- A head the LANGUAGE provides, written here as a string literal.  §8 I6.2(a):
-- ONE program-global identity, NOT the identity of whichever module wrote it,
-- or two modules' `(Int, Int)` stop being the same type — silently.  Every name
-- passed here must be in `frontend/resolve.mdk`'s `primitiveTypes`; the gate
-- pins that.
--
-- why that membership is enough — and it is NOT "the `Ty` layer answers from
-- the same list", which is what this comment said first and is false.  The `Ty`
-- layer answers from `tyOriginScope`, a LAST-WINS fold in which the builtin layer
-- has the LOWEST precedence (`frontend/resolve.mdk`) — so membership alone would
-- not stop an own/prelude/import layer from overriding a name this mint still
-- calls builtin.  What actually closes it is that `primitiveTypes` is ALSO
-- refused as a type name: `duplicateErrors`'
-- `reservedClashes "built-in type" primitiveTypes` (unconditionally, whatever
-- `programIsCore` says), so NO module — not even `stdlib/core.mdk` — can
-- declare a TYPE of that name.  `data List a = …`, `data Int = Foo`,
-- `data Ref a = …` each give "'<N>' is a built-in type".  The higher layers are therefore empty at these keys, which is
-- exactly what resolve's own comment means by *"the prelude beats builtins only
-- vacuously (they are disjoint today)"*.
--
-- "A TYPE of that name" is the load-bearing narrowing, and it needs a SECOND
-- leg.  `primitiveTypes` is refused only as a TYPE name, not as an interface's — so an
-- `interface Int a where …` is ACCEPTED (measured: exit 0, no diagnostic).  It
-- cannot reach this key anyway, because interfaces are keyed `iface:<Name>`
-- (`ifaceKey`/`ownIfaceOrigin`) while the builtin layer holds the BARE name, and
-- the two namespaces are disjoint by construction.  In-tree witness:
-- `test/references_fixtures/iface_ty_collide/`.
--
-- so the property is conditional on that rejection.  Relax duplicate-type
-- rejection — resolve's comment already contemplates *"a future prelude `data
-- List`"* — and an occurrence of `List` carries `OriginModule "core"` while this
-- mint still hands out `OriginBuiltin`.  The gate stays GREEN, because it checks
-- MEMBERSHIP, not AGREEMENT.  Whoever relaxes it owes this site.
export
tconBuiltin : String -> Mono
tconBuiltin n = TCon n OriginBuiltin

-- The builtin unsaturated tuple head (`__tupleN__`).  `OriginBuiltin` for the
-- same reason and by the same authority as the parser's own
-- `tyConBuiltin (tupleCtorTyName n)` (`frontend/parser.mdk:2132`) — the tuple
-- heads sit beside `primitiveTypes` in resolve's `builtinTyOrigins`.
export
tconTupleHead : Int -> Mono
tconTupleHead n = TCon (tupleHeadTagTc n) OriginBuiltin

-- A head minted from an identity that was ACQUIRED — read off a `Ty.TyCon`'s
-- `tyConOrigin` (an occurrence resolve stamped) or off a `DData`/`DNewtype`'s
-- decl-layer carrier.  The origin argument comes FIRST so that the call site
-- reads as "from <this identity>, the head <name>" and a swapped pair does not
-- typecheck.
export
tconFrom : TyConOrigin -> String -> Mono
tconFrom o n = TCon n o

-- A head this site genuinely has NO identity source for — the `Ty` that carried
-- one was already projected to a bare `String` frames above, or the name is
-- fabricated by the checker itself.  Exactly two callers, both commented at the
-- call.  Deliberately NOT spelled `tconBuiltin`: these heads are not builtin,
-- and collapsing "no identity available" into "program-global identity" is the
-- empty-string-sentinel defect with a nicer type (§8 I6.3).
export
tconUnresolved : String -> Mono
tconUnresolved n = TCon n OriginUnresolved

-- ── effect variables + rows (Phase 79/146) ────────────────────────────────

export
newEffvarId : GraphCtx -> Unit -> Int
newEffvarId gctx _ =
  let n = gctx.graphRun.effvarCounter.value
  gctx.graphRun.effvarCounter := n + 1
  n

export
effvarLevel : Ref Effvar -> Int
effvarLevel cell = match !cell
  EUnbound _ l => l
  ELink _ _ => 0
  EJoin _ l _ => l
  ESummary _ l _ => l

-- a row whose tail stands for exactly [members]: closed for none, the cell
-- itself for one, a fresh join cell for several.
export
rowOfMembers : GraphCtx -> List Atom -> List (Ref Effvar) -> EffRow
rowOfMembers gctx labels [] = EffRow labels None
rowOfMembers gctx labels [m] = EffRow labels (Some m)
rowOfMembers gctx labels ms = EffRow labels (Some (joinCellOf gctx ms))

export
joinCellOf : GraphCtx -> List (Ref Effvar) -> Ref Effvar
joinCellOf gctx ms = Ref (EJoin (newEffvarId gctx ()) (minLevelOf ms) ms)

export
minLevelOf : List (Ref Effvar) -> Int
minLevelOf [] = 0
minLevelOf [m] = effvarLevel m
minLevelOf (m :: ms) = minI (effvarLevel m) (minLevelOf ms)

-- The row walker is DAG-aware. Type trees are visited once per boundary; maps
-- accumulate roots without quadratic duplicate elimination across a large SCC.
export
effectRoots : Mono -> Map Int Unit -> Map Int Unit
effectRoots t roots = match normalize t
  TFun a row b => effectRoots b (effectRoots a (effectRowRoots row roots))
  TApp a b => effectRoots b (effectRoots a roots)
  TEff row => effectRowRoots row roots
  TQual a _ => effectRoots a roots
  TAuth _ => roots
  _ => roots

export
effectRowRoots : EffRow -> Map Int Unit -> Map Int Unit
effectRowRoots row roots =
  fold
    (acc cell => match !cell
      EUnbound id _ => IdMap.set id () acc
      _ => acc)
    roots
    (snd (rowFlat row))

export
authRowRoots : EffRow -> Map Int Unit -> Map Int Unit
authRowRoots row roots =
  IdMap.foldlWithKey
    (acc id _ => IdMap.set id () acc)
    roots
    (authRowCells row Tip)

-- replace a row's bound tail effvar with its fresh instance from [esub], so each
-- call site of a polymorphic HOF gets its own effect variable
export
substRow : GraphCtx ->
  List (Int, Ref Effvar) ->
  List (Int, Authority) ->
  EffRow ->
  EffRow
substRow gctx esub asub r =
  let (labels, members) = rowFlat r
  rowOfMembers
    gctx
    (substAtoms asub labels)
    (map (m => substMember esub m) members)

substAtoms : List (Int, Authority) -> List Atom -> List Atom
substAtoms [] atoms = atoms
substAtoms asub atoms = map (substAtom asub) atoms

substAtom : List (Int, Authority) -> Atom -> Atom
substAtom asub (Atom l q) = Atom l (substAuth asub q)

-- Replace quantified authority variables by their instantiation; a join
-- rebuilds from its substituted operands so the result stays canonical.
export
substAuth : List (Int, Authority) -> Authority -> Authority
substAuth [] q = q
substAuth asub q = match authNorm q
  AVar cell => optionOr (AVar cell) (lookupAssocI (authvarId cell) asub)
  AJoin ms => authJoinAll (map (substAuth asub) ms)
  AProduct axes =>
    authNorm (AProduct (map (a => (fst a, substAuth asub (snd a))) axes))
  c => c

substMember : List (Int, Ref Effvar) -> Ref Effvar -> Ref Effvar
substMember esub m = match !m
  EUnbound id _ => optionOr m (lookupAssocI id esub)
  _ => m

-- `support/util`'s `anyList` takes a PURE predicate, so it cannot carry the
-- path-compressing (hence effectful) mono predicates below — `numUnimplementableHead`,
-- `headTyconMono`, … all normalize.  Same short-circuiting `||` fold, one
-- effect row wider.  (Medaka has no effect-polymorphic HOFs, so this must be a
-- second definition rather than a reuse of `anyList`.)
export
anyListM : (a -> Bool) -> List a -> Bool
anyListM _ [] = False
anyListM p (x :: xs) = p x || anyListM p xs

-- #1576: the structural node count of a monotype.  Its only consumer is the shrinking
-- test of the `requires` walk measure (`reqWalkEnter`) — it is a termination signal, not
-- a semantic one, so nothing here needs to agree with any other notion of type size.
--
-- Links are followed (`normalize`) so a solved tyvar is measured at what it stands for
-- rather than as one node; an unbound one is a leaf.  An EFFECT ROW counts as a single
-- node (`TFun` ignores its row, `TEff` is a leaf): the shrinking argument is about the
-- TYPE spine a `requires` chain walks down.  Under-counting a CHILD more than its parent —
-- exactly what the effect-row leaf above does — makes a step look shrinking (free), not
-- NON-shrinking; it is over-counting a child that would make a step look non-shrinking,
-- burning fuel and terminating.  Either way the measure stays a well-founded natural, so
-- termination does not depend on which direction the under-count goes.
monoSize : Mono -> Int
monoSize m = match normalize m
  TApp f a => 1 + monoSize f + monoSize a
  TFun a _ r => 1 + monoSize a + monoSize r
  TQual a _ => 1 + monoSize a
  _ => 1

-- A predicate's goal is its whole ARGUMENT VECTOR (§3 `match(IE, C τ̄)`), so the size
-- the shrinking test compares is the vector's, not arg 0's.
export
monoSizes : List Mono -> Int
monoSizes [] = 0
monoSizes (m :: rest) = monoSize m + monoSizes rest

-- Every unbound type variable in [m] is numbered below [tyvars] and every effect
-- variable below [effvars], so neither counter had reached it yet.
export
monoMintedBefore : Int -> Int -> Mono -> Bool
monoMintedBefore tyvars effvars m = match normalize m
  TVar cell => tyvarId cell < tyvars
  TApp a b =>
    monoMintedBefore tyvars effvars a && monoMintedBefore tyvars effvars b
  TFun a r b =>
    monoMintedBefore tyvars effvars a
      && rowMintedBefore effvars r
      && monoMintedBefore tyvars effvars b
  TEff r => rowMintedBefore effvars r
  TQual a _ => monoMintedBefore tyvars effvars a
  _ => True

rowMintedBefore : Int -> EffRow -> Bool
rowMintedBefore effvars r =
  allList (cell => effvarId cell < effvars) (snd (rowFlat r))

export
walkMonosSame : List Mono -> List Mono -> Bool
walkMonosSame [] [] = True
walkMonosSame (a :: arest) (b :: brest) =
  walkMonoSame a b && walkMonosSame arest brest
walkMonosSame _ _ = False

walkMonoSame : Mono -> Mono -> Bool
walkMonoSame x y = match (normalize x, normalize y)
  (TFun a1 r1 b1, TFun a2 r2 b2) =>
    walkMonoSame a1 a2 && rowSame r1 r2 && walkMonoSame b1 b2
  (TApp a1 b1, TApp a2 b2) => walkMonoSame a1 a2 && walkMonoSame b1 b2
  (TEff r1, TEff r2) => rowSame r1 r2
  (TQual t1 q1, TQual t2 q2) => walkMonoSame t1 t2 && authSame q1 q2
  (TAuth q1, TAuth q2) => authSame q1 q2
  (TQual _ _, _) => False
  (_, TQual _ _) => False
  (a, b) => monoSameGiven a b

export
tyvarId : Ref Tyvar -> Int
tyvarId cell = match !cell
  Unbound id _ => id
  Link _ => 0 - 1

-- number of `TApp` nodes in a left spine — the positional index of the argument
-- applied at the node ABOVE it.  `normalize`s at each level for the same reason
-- `headMonoNode` does (a linked head must resolve).
export
monoSpineDepth : Mono -> Int
monoSpineDepth t = match normalize t
  TApp a _ => 1 + monoSpineDepth a
  _ => 0

export
monoIsApp : Mono -> Bool
monoIsApp (TApp _ _) = True
monoIsApp _ = False

export
dedupI : List Int -> List Int
dedupI [] = []
dedupI [x] = [x]
dedupI [x, y] = if x == y then [x] else [x, y]
dedupI xs = reverseL (dedupIGo xs Tip [])

dedupIGo : List Int -> Map Int Unit -> List Int -> List Int
dedupIGo [] _ result = result
dedupIGo (x :: xs) seen result =
  if IdMap.has x seen then
    dedupIGo xs seen result
  else
    dedupIGo xs (IdMap.set x () seen) (x :: result)

-- Every unbound authority cell reachable in a type: the qualifiers and the
-- atoms of every row.
export
authCellsIn : Mono -> Map Int (Ref Authvar) -> Map Int (Ref Authvar)
authCellsIn t acc = match normalize t
  TFun a row b => authCellsIn b (authCellsIn a (authRowCells row acc))
  TApp a b => authCellsIn b (authCellsIn a acc)
  TEff row => authRowCells row acc
  TQual inner q => authCellsIn inner (authTermCells q acc)
  TAuth q => authTermCells q acc
  _ => acc

export
authRowCells : EffRow -> Map Int (Ref Authvar) -> Map Int (Ref Authvar)
authRowCells row acc =
  fold (m atom => authTermCells (atomAuth atom) m) acc (fst (rowFlat row))

authTermCells : Authority -> Map Int (Ref Authvar) -> Map Int (Ref Authvar)
authTermCells q acc =
  fold (m cell => IdMap.set (authvarId cell) cell m) acc (authVars q)

export
authRoots : Mono -> Map Int Unit -> Map Int Unit
authRoots t roots =
  IdMap.foldlWithKey (acc id _ => IdMap.set id () acc) roots (authCellsIn t Tip)

export
substMono : GraphCtx ->
  List (Int, Mono) ->
  List (Int, Ref Effvar) ->
  List (Int, Authority) ->
  Mono ->
  Mono
substMono gctx subst esub asub t = match normalize t
  TVar cell => optionOr (TVar cell) (lookupAssocI (tyvarId cell) subst)
  c@(TCon _ _) => c
  TRigid n => TRigid n
  TApp a b =>
    TApp (substMono gctx subst esub asub a) (substMono gctx subst esub asub b)
  TFun a eff b =>
    TFun
      (substMono gctx subst esub asub a)
      (substRow gctx esub asub eff)
      (substMono gctx subst esub asub b)
  TEff r => TEff (substRow gctx esub asub r)
  TQual inner q =>
    TQual (substMono gctx subst esub asub inner) (substAuth asub q)
  TAuth q => TAuth (substAuth asub q)

export
stripEff : Ty -> Ty
stripEff (TyEffect _ _ t) = t
stripEff t = t

-- ── AST type → mono (for ADT field types / annotations / signatures) ──────
-- free type-variable NAMES in the type map to fresh tyvars (a signature's `a`
-- is a variable, not a TCon)
export
tyVarNames : Ty -> List String
tyVarNames (TyVar n) = [n]
tyVarNames (TyCon { tyConName = _ }) = []
tyVarNames (TyApp a b) = tyVarNames a ++ tyVarNames b
tyVarNames (TyFun a b) = tyVarNames a ++ tyVarNames b
tyVarNames (TyTuple ts) = flatMap tyVarNames ts
tyVarNames (TyEffect _ _ t) = tyVarNames t
tyVarNames (TyConstrained _ t) = tyVarNames t
-- A bare row atom (#997) wraps no inner type, so it carries no ordinary
-- type-variable occurrence (its own tail var, if any, is a row-namespace
-- name captured by `effTailNames`/`rowArgNames`, not this one).
tyVarNames (TyRow _ _ _) = []
tyVarNames (TyAuth _ _) = []
tyVarNames (TyNamed _ t _) = tyVarNames t
tyVarNames (TyQual t _ _) = tyVarNames t

-- un-curry a left-nested TyApp chain into (head, args).  `headTyconTy` only
-- returns the head; this also keeps the spine for kind-directed elaboration.
export
tyAppSpine : Ty -> (Ty, List Ty)
tyAppSpine (TyApp a b) = match tyAppSpine a
  (head, args) => (head, args ++ [b])
tyAppSpine t = (t, [])

export
monoScheme : Mono -> Scheme
monoScheme t = Forall [] [] [] [] pureRow t

export
schemeAuthIds : Scheme -> List Int
schemeAuthIds (Forall _ _ avars _ _ _) = avars

-- The arrows a written type spells, as `core_ir_lower.methodArgTys` counts them.
export
tyArrowCount : Ty -> Int
tyArrowCount (TyConstrained _ t) = tyArrowCount t
tyArrowCount (TyEffect _ _ t) = tyArrowCount t
tyArrowCount (TyFun _ b) = 1 + tyArrowCount b
tyArrowCount _ = 0

export
arrowArity : Mono -> Int
arrowArity t = match normalize t
  TFun _ _ b => 1 + arrowArity b
  TQual inner _ => arrowArity inner
  _ => 0

-- the type a method ultimately returns (strip its argument arrows); the impl is
-- chosen by this type's head tycon (pure : a -> f a → f a; empty : f a → f a)
export
stripArrows : Mono -> Mono
stripArrows (TFun _ _ b) = stripArrows b
stripArrows t = t

-- The module that DECLARED the selected record, read off the result head
-- `registerRecordInfoKeyed` minted from that declaration's own origin — the same
-- end-to-end pairing `recordCandIsReceiverDecl` compares.  `None` is honest
-- absence: the flat/single-file driver stamps no origins, and it mangles
-- nothing either, so there the key already IS the emitted name.
export
recordOwnerModule : RecordInfo -> Option String
recordOwnerModule ri = match headTyconMono (recordResultMono ri)
  None => None
  Some hk => match headKeyIdent hk
    None => None
    Some (Ident _ io _) => identOriginFold None (mid => Some mid) io

export
rowSame : EffRow -> EffRow -> Bool
rowSame r1 r2 =
  let (atoms1, tails1) = rowFlat r1
  let (atoms2, tails2) = rowFlat r2
  map effvarId tails1 == map effvarId tails2
    && atomsSame (atomsNorm atoms1) (atomsNorm atoms2)

atomsSame : List Atom -> List Atom -> Bool
atomsSame [] [] = True
atomsSame (x :: xs) (y :: ys) =
  atomKey x == atomKey y
    && authSame (atomAuth x) (atomAuth y)
    && atomsSame xs ys
atomsSame _ _ = False

-- Equal as far as can be proven now: each within the other.
export
authSame : Authority -> Authority -> Bool
authSame p q = authSub p q && authSub q p

-- The record's RESULT type — the head `registerRecordInfoKeyed` minted from the
-- DECLARATION's origin (`applyParams (tconFrom o typeName) paramVars`), which is why
-- it is the identity to compare against.  Peer of `recordFieldMap` /
-- `recordFieldNames`; deliberately the RAW result, since instantiating fresh param
-- vars cannot change the head `headTyconMono` reads.
export
recordResultMono : RecordInfo -> Mono
recordResultMono (RecordInfo _ _ result _ _) = result

-- The union-find ROOT id of [v]; -1 if it does not normalize to a type variable.
-- NON-ALLOCATING (it reads the root's id rather than rebuilding a `TVar` for it) and
-- PATH-COMPRESSING (it goes through `normalizeLink`, so a walked chain is flattened).
-- PERF: `sameRootId` is applied to EVERY recorded literal on EVERY arithmetic /
-- comparison operand (markNumlitOpTaint and tagLitLocsWithRoot each scan the whole,
-- never-trimmed `numlitVarLocs` list), so an uncompressed chain made this the single
-- hottest symbol in the compiler — 57% of a large-declaration typecheck (issue #115).
-- Tyvar ids come from a counter that starts at 0 (`newTyvarId`), so -1 can never
-- collide with a real id.
export
rootIdOf : Mono -> Int
rootIdOf (TVar cell) = match !cell
  Unbound id _ => id
  Link t => rootVarId (normalizeLink cell t)
rootIdOf _ = 0 - 1

-- The id of an ALREADY-NORMALIZED mono: its root tyvar's id, or -1 if it is not a
-- type variable at all.  (`normalizeLink` never returns a `Link`, so that arm is
-- unreachable; it folds into the not-a-tyvar answer.)
rootVarId : Mono -> Int
rootVarId (TVar cell) = match !cell
  Unbound id _ => id
  Link _ => 0 - 1
rootVarId _ = 0 - 1

-- True iff [v] normalizes to the unbound var [id] (same union-find root).
export
sameRootId : Int -> Mono -> Bool
sameRootId id v = rootIdOf v == id

-- `Bool` as a HEAD, ignoring origin: the prelude's Bool is builtin-origin, but a
-- normalized operand can carry a module origin, and the question here is only which
-- type constructor it is.
export
monoIsBool : Mono -> Bool
monoIsBool (TCon "Bool" _) = True
monoIsBool _ = False

-- the type after peeling [n] arrows off [t] (normalizing at each level), or
-- None when [t] has fewer.
export
resultAfterArrows : Int -> Mono -> Option Mono
resultAfterArrows n t
  | n <= 0 = Some t
  | otherwise = match normalize t
    TFun _ _ b => resultAfterArrows (n - 1) b
    _ => None

-- does [t] contain a type-constructor application whose head records a
-- non-covariant polarity at some applied slot?  The only shapes on which the
-- variance gate can fire, and so the only ones for which the inference order
-- matters (`inferExpected`).  Walks under arrows and applications; an
-- unregistered head, a bare variable, or an index row contributes nothing.
-- does [t] have an arrow anywhere INSIDE a type-constructor argument?  Purely
-- structural — no table — so it is the cheap first filter for `inferExpected`.
export
monoHasArrowInSlot : Mono -> Bool
monoHasArrowInSlot t = match normalize t
  TApp a b => monoHasArrow b || monoHasArrowInSlot a
  TFun a _ b => monoHasArrowInSlot a || monoHasArrowInSlot b
  _ => False

monoHasArrow : Mono -> Bool
monoHasArrow t = match normalize t
  TFun _ _ _ => True
  TApp a b => monoHasArrow a || monoHasArrow b
  _ => False

export
monoIsTyvarId : Mono -> Int -> Bool
monoIsTyvarId m id = match normalize m
  TVar cell => tyvarId cell == id
  _ => False

-- the head type name of the scrutinee, for the matrix's column-0 oracle: a
-- TCon/TApp head gives the type name; a tuple has no TCon head, so it maps to a
-- synthetic per-arity tuple type (mirrors the reference's col0_type).
--
-- ANSWER-PRESERVING CLASSIFICATION, and it is a REQUIRED property rather
-- than a style choice.  `headTyconNameMono` is the gate — it decides `Some` vs
-- `None` on exactly the `Mono` head nodes it decided them on before, so `TFun`
-- stays `None` (#1617, deliberate) and falls through to `columnCtors`, and a
-- rigid head still produces a key that MISSES the table exactly as today's
-- bare `Some n` missed it.  `headTyconMono` is consulted only to UPGRADE a key
-- that is already going to be `Some`, never to change whether it is `Some`.
--
-- Composing the two existing projections is deliberate: they already owe each
-- other an arm for every new `Mono` head node, and a third independent
-- `match headMonoNode` arm set here is one more the next person would forget.
export
matchCol0Type : Mono -> Option TabKey
matchCol0Type ty = match headTyconNameMono ty
  None => None
  Some n => match headTyconMono ty
    Some (HkDecl k) => Some k
    Some (HkRigid _) => Some (TkBare NsType n)
    None => Some (TkBare NsType n)

export
nthTy : Int -> List Ty -> Option Ty
nthTy _ [] = None
nthTy i (t :: rest)
  | i <= 0 = Some t
  | otherwise = nthTy (i - 1) rest

export
collectAuthvarIds : List Mono -> List Int
collectAuthvarIds ((TAuth (AVar cell)) :: rs) =
  authvarId cell :: collectAuthvarIds rs
collectAuthvarIds (_ :: rs) = collectAuthvarIds rs
collectAuthvarIds [] = []

export
collectTyIds : List Mono -> List Int
collectTyIds ((TVar cell) :: rs) = tyvarId cell :: collectTyIds rs
collectTyIds (_ :: rs) = collectTyIds rs
collectTyIds [] = []

export
collectRowEffvarIds : List Mono -> List Int
collectRowEffvarIds ((TEff (EffRow _ (Some cell))) :: rs) =
  effvarId cell :: collectRowEffvarIds rs
collectRowEffvarIds (_ :: rs) = collectRowEffvarIds rs
collectRowEffvarIds [] = []

export
monoTyvarId : Mono -> Int
monoTyvarId (TVar cell) = tyvarId cell
monoTyvarId _ = 0 - 1

export
schemeMono : Scheme -> Mono
schemeMono (Forall _ _ _ _ _ t) = t

export
monoUnboundIds : Mono -> List Int
monoUnboundIds t = match normalize t
  TVar cell => [tyvarId cell]
  TCon _ _ => []
  TRigid _ => []
  TApp a b => monoUnboundIds a ++ monoUnboundIds b
  TFun a _ b => monoUnboundIds a ++ monoUnboundIds b
  TEff _ => []
  TAuth _ => []
  TQual a _ => monoUnboundIds a

-- PLAN.md #11 (locked §0.2): monomorphism-for-Num defaulting.  Before a type [t]
-- is generalized at a let-binding boundary, ground every *ambiguous* tyvar carrying
-- a `Num` constraint to `Int`.  "Ambiguous" = the var is NOT reachable from an
-- ARGUMENT position of [t] (a caller can't fix it).  This stops a bare `n = 1` (or
-- an inner `let z = 2`) from generalizing to `Num a => a` / leaking an unbound
-- `Num a` to eval, while leaving a genuinely polymorphic var live: `sum`'s element
-- var in `t a -> a` is reachable from the argument `t a`, so it stays polymorphic
-- (`sum [1.0,…]` still works); `x : Float; x = 0`'s var is already concrete Float
-- (not a generalizable var), so it is untouched.  A Num-constrained var (alone OR with another class) that is
-- ambiguous is grounded to Int — the literal's `Num`/`fromInt` representation IS
-- Int, so grounding keeps impl selection deterministic.
--
-- SCOPE (#518): "at a let-binding boundary" above is no longer the whole story — an
-- impl method body is ALSO a defaulting boundary (inferImplMethod), for the same
-- reason a let-group is: it is a point past which an ambiguous Num var can never be
-- determined, so leaving it unbound hands an UNGROUNDED RECEIVER to the route
-- resolver, which then silently mis-selects an impl.  It is not a let-group, which is
-- why it needed its own call rather than inheriting one.  It defaults strictly LESS
-- than a let-group does — body-local vars only — because an
-- impl method's vars can ALSO be caller-determined via a method DICT, a channel with
-- no let-group analogue.  This paragraph is the written scope extension; before #518
-- the widening would have existed only as a judgment call in code.
--
-- `monoArgUnboundIds` protects inferred argument channels.  At a top-level SCC,
-- `processSCC` separately protects declared variables, including result-only and nullary
-- variables; a signed member's recursive occurrences instantiate its contract afresh,
-- so an unsigned sibling's copy of such a variable is the sibling's own to default.
-- Lexical binding boundaries require exact level ownership; numeric
-- expected-result propagation and deeper roots reaching the SCC fallback remain separate
-- (#2646).
export
monoArgUnboundIds : Mono -> List Int
monoArgUnboundIds t = match normalize t
  TFun a _ b => monoUnboundIds a ++ monoArgUnboundIds b
  _ => []

export
monoRootIdSet : List Mono -> OrdMap Unit
monoRootIdSet monos =
  omFromNames (map intToString (dedupI (flatMap monoUnboundIds monos))) omEmpty

-- the unbound var ids carried by a dispatch mono WITH a concrete head (`Set _a` →
-- [_a]); a bare-var dispatch (`t0`) anchors nothing.
export
concreteHeadVarIds : Mono -> List Int
concreteHeadVarIds dm = match headTyconMono dm
  Some _ => monoUnboundIds dm
  None => []

export
argMentions : List String -> Ty -> Bool
argMentions typarams ty = anyMember (tyVarNames ty) typarams

export
anyMember : List String -> List String -> Bool
anyMember xs ys = any (x => contains x ys) xs

export
propParamNamesTc : List PropParam -> List String
propParamNamesTc ps = map propParamName ps

-- the variables a pattern binds (local copy; llvm_emit's patVars isn't importable
-- here, and this one also covers PRec field/pun binders).
export
patVarsTc : Pat -> List String
patVarsTc (PVar x _ _) = [x]
patVarsTc (PCon _ args) = patVarsListTc args
patVarsTc (PCons h t) = patVarsTc h ++ patVarsTc t
patVarsTc (PTuple ps) = patVarsListTc ps
patVarsTc (PList ps) = patVarsListTc ps
patVarsTc (PAs x _ _ p) = x :: patVarsTc p
patVarsTc (PRec _ fields _) = flatMap recPatFieldVarsTc fields
patVarsTc _ = []

export
patVarsListTc : List Pat -> List String
patVarsListTc ps = flatMap patVarsTc ps

recPatFieldVarsTc : RecPatField -> List String
recPatFieldVarsTc (RecPatField label _ _ None) = [label]
recPatFieldVarsTc (RecPatField _ _ _ (Some p)) = patVarsTc p

export
nthMono : Int -> List Mono -> Option Mono
nthMono _ [] = None
nthMono k (x :: rest) = if k <= 0 then Some x else nthMono (k - 1) rest

-- impls_overlap: do two impl head-arg lists share a common instance?  Every
-- TVar (fresh per impl, so distinct ids) is a unification wildcard with a shared
-- subst — `(List Int)` vs `(List a)` overlap via a:=Int; `a a` vs `Int Bool`
-- does NOT (resolve binds a:=Int, then Int vs Bool fails), mirroring the oracle.
export
cohOverlap : List Mono -> List Mono -> Bool
cohOverlap xs ys
  | listLen xs == listLen ys = cohOverlapGo (Ref []) (zipL xs ys)
  | otherwise = False

export
cohOverlapGo : Ref (List (Int, Mono)) -> List (Mono, Mono) -> Bool
cohOverlapGo _ [] = True
cohOverlapGo subst ((a, b) :: rest)
  | cohGo subst a b = cohOverlapGo subst rest
  | otherwise = False

-- resolve a mono through the wildcard subst (chasing bound vars)
cohResolve : Ref (List (Int, Mono)) -> Mono -> Mono
cohResolve subst m = match normalize m
  TVar cell => match lookupAssocI (tyvarId cell) !subst
    Some m2 => cohResolve subst m2
    None => TVar cell
  other => other

cohGo : Ref (List (Int, Mono)) -> Mono -> Mono -> Bool
cohGo subst t1 t2 = cohGoR subst (cohResolve subst t1) (cohResolve subst t2)

cohGoR : Ref (List (Int, Mono)) -> Mono -> Mono -> Bool
cohGoR subst (TVar c1) (TVar c2)
  | tyvarId c1 == tyvarId c2 = True
  | otherwise = cohBind subst (tyvarId c1) (TVar c2)
cohGoR subst (TVar c1) t = cohBind subst (tyvarId c1) t
cohGoR subst t (TVar c2) = cohBind subst (tyvarId c2) t
-- #1111 A-2.10: identity-aware, same rule as `unifyN` (`sameTyConHead`).  Two
-- impl heads that merely SPELL the same type no longer overlap, so a coherence
-- conflict is no longer reported between `impl C a.T` and `impl C b.T` — which
-- is the correct answer: they are different types.
cohGoR _ (TCon a oa) (TCon b ob) = sameTyConHead a oa b ob
-- #1110: name equality, exactly as the shared `TCon` arm gave, for the
-- cross-population pairs ONLY — A-2.10 deliberately left these two alone.  A
-- `TRigid` carries no origin at all, so routing them through `sameTyConHead`
-- would compute "no conflict" and answer the same thing; the preserved forgery
-- is #1243 / §8 I6.2(b), a different clause.  not separately probed — armed
-- because the pre-split `TCon` arm answered these pairings with the same
-- `a == b`, and a rigid and a real head CAN share the name `__tupleN__` (see
-- `Mono.TRigid`).  Whether a coherence sweep can actually be reached with such a
-- pair is unmeasured; the arm is answer-preserving either way.  Measured
-- instances of the same forgery are `unifyN` and `matchStep`.
cohGoR _ (TRigid a) (TRigid b) = a == b
cohGoR _ (TCon a _) (TRigid b) = a == b
cohGoR _ (TRigid a) (TCon b _) = a == b
cohGoR subst (TApp f1 a1) (TApp f2 a2) = cohGo subst f1 f2 && cohGo subst a1 a2
cohGoR subst (TFun a1 _ b1) (TFun a2 _ b2) =
  cohGo subst a1 a2 && cohGo subst b1 b2
cohGoR _ (TEff _) (TEff _) = True
cohGoR _ (TAuth _) (TAuth _) = True
-- A qualifier is not part of a head's shape: coherence compares the value
-- types under it.
cohGoR subst (TQual a _) b = cohGo subst a b
cohGoR subst a (TQual b _) = cohGo subst a b
cohGoR _ _ _ = False

-- bind id := m in the wildcard subst and return True
-- A variable never binds to a type that contains it: `t := List t` has no
-- finite solution, so the two sides share no instance, and binding it would
-- send every later comparison through `t` round the cycle forever.
cohBind : Ref (List (Int, Mono)) -> Int -> Mono -> Bool
cohBind subst id m =
  if cohOccurs subst id m then
    False
  else
    subst := (id, m) :: !subst
    True

cohOccurs : Ref (List (Int, Mono)) -> Int -> Mono -> Bool
cohOccurs subst id m = match cohResolve subst m
  TVar cell => tyvarId cell == id
  TApp f a => cohOccurs subst id f || cohOccurs subst id a
  TFun a _ b => cohOccurs subst id a || cohOccurs subst id b
  TQual a _ => cohOccurs subst id a
  _ => False

export
matchOneSided : (g -> s -> MStep k g s) ->
  (k -> k -> Bool) ->
  (s -> s -> Bool) ->
  List (g, s) ->
  List (k, s) ->
  Option (List (k, s))
matchOneSided _ _ _ [] acc = Some acc
matchOneSided step keyEq eqS ((g, s) :: rest) acc = match step g s
  MFail => None
  MOk => matchOneSided step keyEq eqS rest acc
  MKids kids => matchOneSided step keyEq eqS (kids ++ rest) acc
  MVar k => match lookupBy keyEq k acc
    Some prev =>
      if eqS prev s then matchOneSided step keyEq eqS rest acc else None
    None => matchOneSided step keyEq eqS rest ((k, s) :: acc)

-- NB: the comparison parameter must NOT be named `eq` — that is the prelude Eq
-- method, and the marker would rewrite the local reference into a method call,
-- importing a phantom `Eq k` constraint the signature can't discharge.
lookupBy : (k -> k -> Bool) -> k -> List (k, v) -> Option v
lookupBy _ _ [] = None
lookupBy keq k ((k2, v) :: rest) =
  if keq k k2 then Some v else lookupBy keq k rest

-- rigid structural equality (the specific side's vars match only the same id)
export
cohEqMono : Mono -> Mono -> Bool
cohEqMono a b = cohEqR (normalize a) (normalize b)

cohEqR : Mono -> Mono -> Bool
cohEqR (TVar c1) (TVar c2) = tyvarId c1 == tyvarId c2
cohEqR (TCon a oa) (TCon b ob) = sameTyConHead a oa b ob
-- #1110: same shape as the `cohGoR` arms — name equality on the cross-population
-- pairings, which A-2.10 left alone for the reason given there.
-- Cross-population pairs not separately probed; armed because the pre-split `TCon`
-- arm answered them.  Reached from `matchStep`'s consistency check, so it is not
-- independent of the measured `matchStep` case.  See `Mono.TRigid`.
cohEqR (TRigid a) (TRigid b) = a == b
cohEqR (TCon a _) (TRigid b) = a == b
cohEqR (TRigid a) (TCon b _) = a == b
cohEqR (TApp f1 a1) (TApp f2 a2) = cohEqMono f1 f2 && cohEqMono a1 a2
cohEqR (TFun a1 _ b1) (TFun a2 _ b2) = cohEqMono a1 a2 && cohEqMono b1 b2
cohEqR (TEff _) (TEff _) = True
cohEqR (TAuth _) (TAuth _) = True
cohEqR (TQual a _) b = cohEqR (normalize a) b
cohEqR a (TQual b _) = cohEqR a (normalize b)
cohEqR _ _ = False

-- A repeated impl-head variable is one full type.  Coherence and dispatch
-- deliberately ignore rows and authorities when ranking heads; that comparison
-- cannot prove that two bindings of the same variable agree.  Keep type-variable
-- equations in a matcher-local substitution only where the caller already
-- solved them (implHeadSubst).  The one-sided matcher keeps goal variables rigid.
-- Compare the remaining indices without touching the goal's inference cells.
export
matchEqMono : Ref (List (Int, Mono)) -> Mono -> Mono -> Bool
matchEqMono subst a b = matchEqR subst (cohResolve subst a) (cohResolve subst b)

matchEqR : Ref (List (Int, Mono)) -> Mono -> Mono -> Bool
matchEqR _ (TVar c1) (TVar c2) = tyvarId c1 == tyvarId c2
matchEqR _ (TCon a oa) (TCon b ob) = sameTyConHead a oa b ob
matchEqR _ (TRigid a) (TRigid b) = a == b
matchEqR _ (TCon a _) (TRigid b) = a == b
matchEqR _ (TRigid a) (TCon b _) = a == b
matchEqR subst (TApp f1 a1) (TApp f2 a2) =
  matchEqMono subst f1 f2 && matchEqMono subst a1 a2
matchEqR subst (TFun a1 r1 b1) (TFun a2 r2 b2) =
  matchEqMono subst a1 a2 && matchEqRow r1 r2 && matchEqMono subst b1 b2
matchEqR _ (TEff r1) (TEff r2) = matchEqRow r1 r2
matchEqR _ (TAuth q1) (TAuth q2) = matchEqAuth q1 q2
matchEqR subst (TQual a q1) (TQual b q2) =
  matchEqAuth q1 q2 && matchEqMono subst a b
matchEqR subst (TQual a q) b = authIsTop q && matchEqMono subst a b
matchEqR subst a (TQual b q) = authIsTop q && matchEqMono subst a b
matchEqR _ _ _ = False

matchEqAuth : Authority -> Authority -> Bool
matchEqAuth a b = authSub a b && authSub b a

matchEqRow : EffRow -> EffRow -> Bool
matchEqRow a b =
  let (atomsA, tailsA) = rowFlat a
  let (atomsB, tailsB) = rowFlat b
  listLen atomsA == listLen atomsB
    && listLen tailsA == listLen tailsB
    && allList
      (x => match findAtom (atomKey x) atomsB
        Some y => matchEqAuth (atomAuth x) (atomAuth y)
        None => False)
      atomsA
    && allList (x => anyList (y => effvarId x == effvarId y) tailsB) tailsA

-- render two impl head-arg lists against ONE shared naming ctx (so a var shared
-- across both prints identically and distinct vars never collide) — mirrors the
-- oracle's pp_monos_pair.
export
cohPpPair : List Mono -> List Mono -> (String, String)
cohPpPair xs ys =
  let ctx = Ref []
  let cnt = Ref 0
  let s1 = joinWith " " (cohPpEach ctx cnt xs)
  let s2 = joinWith " " (cohPpEach ctx cnt ys)
  (s1, s2)

cohPpEach : Ref (List (Int, String)) -> Ref Int -> List Mono -> List String
cohPpEach ctx cnt ms = map (ppGo ctx cnt 0) ms

-- ── #609: specificity over head VECTORS (DICT-SEMANTICS §3) ─────────────────
-- §3 defines a predicate as a class applied to a VECTOR (`π ::= C τ̄`) and
-- specificity as `I_A ⊑ I_B iff ∃σ. σ(C B̄) = C Ā` — ONE substitution σ matching
-- the WHOLE vector at once, NOT per-argument subsumption.  Per-argument would be a
-- plausible-looking wrong answer: it cannot see that a var bound in two argument
-- positions must receive the SAME type, so `Ix a a` would "subsume" `Ix Int Bool`.
-- Matching one worklist of pairs through matchOneSided is exactly σ: the shared
-- core binds each general-side TyVar once and re-checks (tyStructEq) every later
-- occurrence, so a non-linear pattern is only subsumed by a consistent instance.
-- Direction, as in the superseded scalar `tySubsumes`: is [specifics] an instance of
-- [generals]?  Only the GENERAL side's TyVars act as wildcards; the SPECIFIC side's
-- are rigid and match only the same name.
--
-- n=1 reduction is ALGEBRAIC, not a fixture claim: a KeyEntry's `itys` for a
-- single-param impl is exactly `[hty]` (keyEntryOfRow destructures `tys` as `headTy::_`
-- and stores the SAME `tys` as itys — `keyEntryOf`'s deleted predecessor did the same),
-- and `zipL [g] [s] == [(g, s)]`, so
--     tySubsumesV [g] [s] == matchOneSided tyStep eqStr tyStructEq [(g, s)] []
-- which is the REMOVED `tySubsumes g s` body term for term.  Every single-param
-- decision is therefore unchanged by construction, not by fixture census.  A length
-- mismatch is not a match (no σ can equate vectors of different arity); it is
-- unreachable between two impls of ONE interface, which share that interface's arity.
export
tySubsumesV : List Ty -> List Ty -> Bool
tySubsumesV generals specifics
  | listLen generals /= listLen specifics = False
  | otherwise =
    isSome (matchOneSided tyStep eqStr tyStructEq (zipL generals specifics) [])

-- the two head VECTORS are the SAME pattern up to var renaming (mutual subsumption)
-- — no ordering needed, the candidate trivially covers it.  Supersedes the scalar
-- `tyHeadEq`, which compared arg-0 patterns only.
export
tyHeadEqV : List Ty -> List Ty -> Bool
tyHeadEqV a b = tySubsumesV a b && tySubsumesV b a

-- [a] ⊑ [b] strictly: [b]'s vector subsumes [a]'s but not vice versa.  Supersedes
-- the scalar `tyStrictlyMoreSpecific`.
export
tyStrictlyMoreSpecificV : List Ty -> List Ty -> Bool
tyStrictlyMoreSpecificV a b = tySubsumesV b a && not (tySubsumesV a b)

-- AST-space step: rigid structural, NO normalize (raw AST patterns).  A TyEffect/
-- TyConstrained wrapper on the general side is transparent — recurse into its body
-- with the specific side's own wrappers stripped (stripTyWrap), preserving the old
-- tySubsumeGo behaviour.  Exhaustive over every `Ty` constructor (ast.mdk), so
-- no catch-all — a new constructor must add an arm here, not rely on a
-- wildcard (a hand-maintained count here would rot; see `TyRow`'s own arm
-- below for why: a bare row atom has no wrapped type to recurse into, so it
-- vacuously matches anything in this position).  A type constructor compares by
-- identity (`sameTyConHead`), the rule the use site's `matchStep` and coherence's
-- `cohStep` apply, so a module-local type never matches an imported type it shares a
-- spelling with.
export
tyStep : Ty -> Ty -> MStep String Ty Ty
tyStep (TyVar gn) _ = MVar gn
tyStep (TyCon { tyConName = a, tyConOrigin = oa }) (TyCon { tyConName = b, tyConOrigin = ob }) =
  if sameTyConHead a oa b ob then MOk else MFail
tyStep (TyCon { tyConName = _ }) _ = MFail
tyStep (TyApp f1 a1) (TyApp f2 a2) = MKids [(f1, f2), (a1, a2)]
tyStep (TyApp _ _) _ = MFail
tyStep (TyFun a1 b1) (TyFun a2 b2) = MKids [(a1, a2), (b1, b2)]
tyStep (TyFun _ _) _ = MFail
tyStep (TyTuple ts1) (TyTuple ts2) =
  if listLen ts1 == listLen ts2 then MKids (zipL ts1 ts2) else MFail
tyStep (TyTuple _) _ = MFail
tyStep (TyEffect _ _ t1) s = MKids [(t1, stripTyWrap s)]
tyStep (TyConstrained _ t1) s = MKids [(t1, stripTyWrap s)]
-- Same "rows are transparent" treatment used throughout this specificity
-- engine (a `TyEffect`'s row never participates — only its wrapped type
-- does). A bare row atom has no wrapped type to recurse into, so it
-- vacuously matches anything in this position.
tyStep (TyRow _ _ _) _ = MOk
tyStep (TyAuth _ _) _ = MOk
tyStep (TyNamed _ t1 _) s = MKids [(t1, stripTyWrap s)]
tyStep (TyQual t1 _ _) s = MKids [(t1, stripTyWrap s)]

export
stripTyWrap : Ty -> Ty
stripTyWrap (TyEffect _ _ t) = stripTyWrap t
stripTyWrap (TyConstrained _ t) = stripTyWrap t
stripTyWrap (TyNamed _ t _) = stripTyWrap t
stripTyWrap (TyQual t _ _) = stripTyWrap t
stripTyWrap t = t

-- structural equality of two AST type patterns (rigid; TyVar names must match, type
-- constructors compare by identity as in `tyStep`).
export
tyStructEq : Ty -> Ty -> Bool
tyStructEq (TyCon { tyConName = a, tyConOrigin = oa }) (TyCon { tyConName = b, tyConOrigin = ob }) =
  sameTyConHead a oa b ob
tyStructEq (TyVar a) (TyVar b) = a == b
tyStructEq (TyApp f1 a1) (TyApp f2 a2) = tyStructEq f1 f2 && tyStructEq a1 a2
tyStructEq (TyFun a1 b1) (TyFun a2 b2) = tyStructEq a1 a2 && tyStructEq b1 b2
tyStructEq (TyTuple ts1) (TyTuple ts2) = tyStructEqList ts1 ts2
tyStructEq (TyEffect _ _ t1) (TyEffect _ _ t2) = tyStructEq t1 t2
tyStructEq (TyConstrained _ t1) (TyConstrained _ t2) = tyStructEq t1 t2
tyStructEq _ _ = False

tyStructEqList : List Ty -> List Ty -> Bool
tyStructEqList [] [] = True
tyStructEqList (t1 :: ts1) (t2 :: ts2) =
  tyStructEq t1 t2 && tyStructEqList ts1 ts2
tyStructEqList _ _ = False

-- the head node of an (unelaborated) AST type's left-nested `TyApp` spine.
-- Total (every `Ty` has a head) and ALLOCATION-FREE (it returns a node that
-- already exists).  Both projections below are written against it, so the
-- spine walk is shared and cannot drift between them; what they do NOT share
-- is the classification of that head node, which is the part that differs by
-- construction — see `headTyconMono`'s note on the same split.
--
-- it also peels `TyEffect` — #1618, and the peel is NOT a `TyApp`-spine step.
-- `eval.headTycon` has peeled it since long before this projection existed, so an
-- `impl Sz (<Stdout> Int)` was filed by the DEFINITION side under tag `Int` while
-- this side answered `None` and stamped the route word `__none__`; the emitter
-- then looked `__none__` up, found nothing, and died with `no impl of method 'sz'
-- for type '__none__'` on a program `check` and `run` both accept.  Peeling here
-- makes the two sides name the same tag.  The peel belongs on the NODE walk, not
-- on one classifier, so `headTyconTy` and `headTyconNameTy` cannot disagree about
-- WHICH node they are classifying (they are only allowed to disagree about how).
--
-- It also peels `TyConstrained`.  Peeling a constraint yields a headless
-- body only for `Eq a => a`; for `Eq a => Int` the peeled body is a `TyCon`.
-- `eval.headTycon` peels `TyConstrained`, so without the peel here the HEADED
-- case splits the two sides: the definition side files `impl Sz (Eq a => Int)`
-- under tag `Int` while this side answers `None` and stamps `__none__`, and
-- `medaka build` dies with `no impl of method 'sz' for type '__none__'` on a
-- program `check` accepts and `run` answers correctly.
--
-- The HEADLESS body is unaffected and must stay that way: peeling
-- `Eq a => a` still lands on a `TyVar`, every arm below still falls through to
-- `_ => None`, and `impl Sz (Eq a => a)` remains a fully-general headless impl.
-- The peel does not decide headedness — it only stops the WRAPPER from hiding a
-- head that is there.  That is why the arm is on this NODE walk rather than in
-- one classifier: `headTyconTy` and `headTyconNameTy` must not disagree about
-- WHICH node they are classifying.
--
-- It is the dispatch walk: the `TyEffect` peel and `headTyconTy`'s `TyFun` arm make
-- the impl side name the tag the goal side already keys (#1617/#1618).  No
-- acceptance question reads it.  The instances an undetermined goal can reach are
-- counted by `goalCandidates`, which unifies every head shape with the goal, both at
-- a boundary's verdict and in `routeUndeterminedTop`.
headTyNode : Ty -> Ty
headTyNode (TyApp a _) = headTyNode a
headTyNode (TyEffect _ _ t) = headTyNode t
headTyNode (TyConstrained _ t) = headTyNode t
headTyNode t = t

-- The `TyApp`-spine-only head walk: `headTyNode` without the `TyEffect` and
-- `TyConstrained` peels, so a qualified head reads as the qualifier it is
-- (`rowCountsFor`).
export
headTySpineNode : Ty -> Ty
headTySpineNode (TyApp a _) = headTySpineNode a
headTySpineNode t = t

-- the head type constructor of an (unelaborated) AST type, as the IMPL-SIDE
-- dispatch key — Stage A-2 unit A-2.2 (#1111).  The result was `Option String`
-- until this unit, which threw away the `tyConOrigin` Stage A-1 put on the very
-- node this matches; `HeadKey` (`types/registry.mdk`) carries it, and its
-- doc-comment derives why `None` had to keep meaning exactly what it meant
-- before ("no head type constructor at all") rather than absorbing "a head with
-- no identity yet".
--
-- `TyTuple` is the one arm with no node to read an origin off: the head it
-- names is the synthetic `__tupleN__` tag, which the LANGUAGE provides.
-- `OriginBuiltin` is therefore the same answer, by the same authority, as the
-- two mints that build such a head — `tconTupleHead` above and the parser's own
-- `tyConBuiltin (tupleCtorTyName n)` (`frontend/parser.mdk`).  It is also what
-- keeps the impl side and the goal side agreeing on tuple heads, the invariant
-- the `ImplUniverse` comment above already relies on.
--
-- THE `TyFun` ARM IS #1617's FIX, and `OriginBuiltin` is the same answer by
-- the same authority as `TyTuple`'s: the arrow constructor is provided by the
-- LANGUAGE, not by a declaration.  Before it, two arrow-headed impls of one
-- interface both fell through to `None`, landed in the headless bucket, and —
-- because `goalHeadCon` answered `None` too — `ieSelectRowByMethod` selected
-- NOTHING, so the site was stamped `RNone` and the emitter fell back to arg-tag
-- dispatch over a receiver (a closure) that carries no cell tag.  See
-- `route_key.funHeadTag` for why ONE tag is enough here where tuples needed one
-- per arity.
--
-- #1630 added no arm here, and that is the point.  A constrained head is not
-- a new KIND of head — `Eq a => Int` is an `Int` head behind a wrapper — so the
-- fix is a peel on `headTyNode`, and every arm below classifies the peeled node
-- unchanged.  If you are tempted to add a `TyConstrained` arm here, the shape
-- you want is already handled; adding one would only let this projection and
-- `headTyconNameTy` disagree about which node they classify.
export
headTyconTy : Ty -> Option HeadKey
headTyconTy t = match headTyNode t
  TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
  TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
  TyFun _ _ => Some (headKeyOfCon OriginBuiltin funHeadTag)
  _ => None

-- Merge two name→mono substs; on a key collision keep whichever value has a
-- concrete head tycon (so the grounded element wins over a free result var).
export
mergeSubstPreferConcrete : List (String, Mono) ->
  List (String, Mono) ->
  List (String, Mono)
mergeSubstPreferConcrete acc [] = acc
mergeSubstPreferConcrete acc ((k, v) :: rest) =
  mergeSubstPreferConcrete (mergeOne acc k v) rest

export
mergeOne : List (String, Mono) -> String -> Mono -> List (String, Mono)
mergeOne [] k v = [(k, v)]
mergeOne ((k2, v2) :: rest) k v
  | k2 == k = (k2, preferConcrete v2 v) :: rest
  | otherwise = (k2, v2) :: mergeOne rest k v

preferConcrete : Mono -> Mono -> Mono
preferConcrete a b = match headTyconMono a
  Some _ => a
  None => b

-- match an impl-head type PATTERN against a concrete mono, binding the impl's
-- type-variable names to monos (single-level: the pattern's args are bare vars).
-- #156 S1 / Fork B: matchTyMono is now a CONSISTENCY-ENFORCING frontend of the
-- shared matchOneSided core (specific side = Mono, so the consistency equality is
-- matchEqMono).  The old body combined element substs with `xs ++ ys` and NEVER
-- checked a var bound twice, so a non-linear impl head (`Get (Box a) a`) could
-- "match" `Get (Box Int) Bool` (binding a↦Int AND a↦Bool) even though NO
-- substitution exists — violating §3 `inst`'s "φ a most-general MATCHER" premise
-- and letting findImplEntryGo (iface=="") select the wrong impl's requires.  Now
-- a↦Int, a↦Bool fails matchEqMono ⇒ None (no false match); a CONSISTENT non-linear
-- head (`Get (Box Int) Int`, a↦Int twice) still matches (the live canary in
-- test/eval_typed_fixtures/return_only_param_dispatch.mdk).  The recovered subst
-- is consumed only by key-lookup (fromAstType / paramMonoOf), so dropping the
-- redundant duplicate binding is byte-identical for every previously-accepted
-- match.
export
matchTyMono : Ty -> Mono -> Option (List (String, Mono))
matchTyMono headTy resultMono =
  let subst = Ref []
  matchOneSided matchStep eqStr (matchEqMono subst) [(headTy, resultMono)] []

-- #609: the §3 matching judgement over a head VECTOR —
--     match(IE, C τ̄) = { I | ∃φ. φ(head(I)) = C τ̄ }
-- ONE most-general matcher φ for the whole vector, so a var appearing in several
-- argument positions must receive the same mono (matchOneSided's matchEqMono
-- consistency check, the same one matchTyMono relies on).  n=1 reduces to
-- matchTyMono term for term: `zipL [t] [m] == [(t, m)]`.
matchTyMonos : List Ty -> List Mono -> Option (List (String, Mono))
matchTyMonos pats goals
  | listLen pats /= listLen goals = None
  | otherwise =
    let subst = Ref []
    matchOneSided matchStep eqStr (matchEqMono subst) (zipL pats goals) []

-- Does an impl whose head vector is [itys] (arg-0 pattern [hty]) match the goal
-- vector [goals]?  When the caller recovered the interface's FULL param monos the
-- two vectors line up and we match ALL of them under one φ (§3).  When it could
-- not — a scalar-only caller passes the singleton [m] — the lengths disagree for a
-- multi-param impl and we fall back to matching the arg-0 pattern alone, which is
-- byte-identical to the pre-#609 scan.  For a single-param impl the lengths always
-- agree (both 1) and `matchTyMonos [hty] [m] == matchTyMono hty m`, so the
-- single-param path never takes the fallback and never changes.
export
entryHeadMatches : Ty -> List Ty -> List Mono -> Bool
entryHeadMatches hty itys goals
  | listLen itys == listLen goals = isSome (matchTyMonos itys goals)
  | otherwise = match goals
    g :: _ => isSome (matchTyMono hty g)
    [] => False

-- AST-head-vs-Mono step: destructure the AST head pattern, normalizing the Mono
-- side at each level.  TyVar binds the WHOLE mono at that position.
--  • TyTuple: a tuple impl head (`(a, b)`) matches a same-arity tuple mono (Native
--    Gap C) — one element-var subst per position; mismatched arity ⇒ MFail.
--  • TyFun: recover typaram bindings from BOTH argument and result positions (used
--    by ifaceParamMonos); effect rows ignored (row-blind), result wrapper stripped.
--  • TyEffect/TyConstrained wrappers on the head are transparent.
export
matchStep : Ty -> Mono -> MStep String Ty Mono
matchStep (TyVar n) _ = MVar n
matchStep (TyCon { tyConName = n, tyConOrigin = o }) m = match peelQual m
  -- #1111 A-2.10: the IMPL-HEAD-vs-GOAL match reads identity too, by the same
  -- `sameTyConHead` rule `unifyN` uses.  This is the dispatch half: `impl C a.T`
  -- no longer matches a goal whose head is `b.T`.  It does NOT make dispatch
  -- identity-KEYED — `ImplBuckets`/`obUniv*` are still spelling-keyed (#1274,
  -- `dispHeadTab`); this narrows the candidates a bucket's scan accepts, which
  -- is why the two can be landed in either order.
  TCon n2 o2 => if sameTyConHead n o n2 o2 then MOk else MFail
  -- #1110 ANSWER-PRESERVING, and it really does fire — the twin of `tupleSpine`'s
  -- rigid arm.  A real head is uppercase-initial OR one of the four reserved
  -- `__tupleN__` tags (`tupleCtorTyName`, `compiler/frontend/parser.mdk:2137-2141`,
  -- minted via `tyConBuiltin` at `:2131`), and `__tupleN__` is ALSO a legal rigid
  -- spelling: `identStartLower` (`compiler/frontend/lexer.mdk:1638`) admits a
  -- leading `_`, so `data Bad = Bad __tuple2__` binds a type PARAMETER and both
  -- rigid producers can mint `TRigid "__tuple2__"`.  Measured: without this arm
  -- `impl Q (,)` stops matching such a goal and a program that checked clean before
  -- the split becomes `No impl of Q for (,)` — a real answer change.
  --
  -- The pre-split answer this restores is a FORGERY: a rigid variable is not the
  -- builtin tuple head, and letting it match one is exactly the identity confusion
  -- DICT-SEMANTICS §8 I6.2(b) records as OWED-#1110.  Preserved deliberately —
  -- this PR is the carrier step; changing answers is the follow-on.
  TRigid n2 => if n == n2 then MOk else MFail
  _ => MFail
matchStep (TyApp a b) m = match peelQual m
  TApp ma mb => MKids [(a, ma), (b, mb)]
  _ => MFail
matchStep (TyTuple ts) m = match tupleSpine m
  Some ms => if listLen ts == listLen ms then MKids (zipL ts ms) else MFail
  _ => MFail
matchStep (TyFun a b) m = match peelQual m
  TFun ma _ mb => MKids [(a, ma), (stripEff b, mb)]
  _ => MFail
matchStep (TyEffect _ _ t) m = MKids [(t, m)]
matchStep (TyConstrained _ t) m = MKids [(t, m)]
-- A row written in an `Effect` slot (`f (e | e2) b`) matches any effect row, as the
-- rows an arrow carries do: a row is not a dispatch position, so it binds nothing.
matchStep (TyRow _ _ _) m = match peelQual m
  TEff _ => MOk
  _ => MFail
matchStep _ _ = MFail

-- the tyvar in [t] whose id is [id], if any (mirrors the reference's
-- find_tvar_in_mono): recovers the enclosing constraint var the body unified into
-- the recursive call's type
export
findTvarInMono : Mono -> Int -> Option Mono
findTvarInMono t id = findTvarN (normalize t) id

findTvarN : Mono -> Int -> Option Mono
findTvarN (TVar cell) id = if tyvarId cell == id then Some (TVar cell) else None
findTvarN (TCon _ _) _ = None
-- #1110: a rigid is not a unification variable, so it holds no tyvar id —
-- same `None` the shared `TCon` arm gave.
findTvarN (TRigid _) _ = None
findTvarN (TApp a b) id = firstTvar a b id
findTvarN (TFun a _ b) id = firstTvar a b id
-- An effect row is reachable here as a KRow type-application argument
-- (`TApp con (TEff row)`); a value-level tyvar id is never inside an effect row
-- (its tail is an effvar, a separate namespace), so the answer is None.
findTvarN (TEff _) _ = None
findTvarN (TAuth _) _ = None
findTvarN (TQual a _) id = findTvarInMono a id

firstTvar : Mono -> Mono -> Int -> Option Mono
firstTvar a b id = match findTvarInMono a id
  Some m => Some m
  None => findTvarInMono b id

-- the head node of a left-spine `TApp`, normalizing at each level (the head may
-- be a TVar linked to a concrete type after unification — normalize follows only
-- the top link, so recurse through normalize).  Total (every `Mono` has a head)
-- and ALLOCATION-FREE (it returns a node that already exists).
export
headMonoNode : Mono -> Mono
headMonoNode t = match normalize t
  TApp a _ => headMonoNode a
  TQual a _ => headMonoNode a
  other => other

-- The value type under a qualifier (normalized); a plain type is itself.
export
peelQual : Mono -> Mono
peelQual t = match normalize t
  TQual a _ => peelQual a
  other => other

-- the head type constructor as the GOAL-SIDE dispatch key — Stage A-2 unit
-- A-2.2 (#1111).  The result was `Option String` until this unit, which threw
-- away the `TyConOrigin` Stage A-1 put on the `TCon` this matches; `HeadKey`
-- (`types/registry.mdk`) carries it, and its doc-comment derives why `None` had
-- to keep meaning exactly what it meant before ("no head type constructor at
-- all") rather than absorbing "a head with no identity yet".
--
-- it is not the only `Mono` HEAD PROJECTION — but it IS now the only `Mono`
-- one on a dispatch path.  A-2.2 left a third, `monoHeadCon`, `Option String`
-- and carrying its own copy of the same I6.1 forgery; A-2.2b DELETED it,
-- pointed `goalHeadCon` (hence `KeyBuckets`' goal side) and the three
-- `implExistsForHead` receiver sites at this function, and moved its name-only
-- consumers to `headTyconNameMono` below.
--
-- "the surviving pair" is ambiguous and this comment means one of them.  The
-- pair meant HERE is the SOURCE-TYPE pair — this and `headTyconNameMono`, the
-- two `Mono` projections, which owe each other the invariant that they classify
-- the same head nodes.  `monoHeadCon`'s obituary above names the other, the
-- SIDE pair (`headTyconTy` impl / `headTyconMono` goal).  Neither is "the" pair
-- and neither is a count of the projections in this file: that is four, and the
-- derivation that can actually discover a fifth is in the obituary.
--
-- this is the first site in this file that reads A `Mono.TCon` ORIGIN, which
-- is why `test/typecheck_compiler_source.sh`'s `Mono.TCon` mint ratchet carries
-- this line: its discriminator is a `_` in the origin slot, so a pattern that
-- BINDS the origin is the false positive its own remedy predicts ("a pattern
-- that legitimately BINDS the origin is the expected first false positive; list
-- it, and the list stays the audit").  Nothing is CONSTRUCTED here.
export
headTyconMono : Mono -> Option HeadKey
headTyconMono t = match headMonoNode t
  TCon n o => Some (headKeyOfCon o n)
  -- ANSWER-preserving, not correct — the twin of `headTyconNameMono`'s arm,
  -- and the load-bearing one: this is the GOAL-side dispatch key (#1110,
  -- DICT-SEMANTICS §8 I6.1).  A rigid variable has no head type constructor, so
  -- handing its parameter name out as a bucket key is the residual violation the
  -- split makes visible.  It reproduced today's answer byte-for-byte and is left
  -- alone deliberately; changing it is the follow-on semantics PR.
  --
  -- A-2.2 does NOT give it one: `HkRigid` is the inhabitant that says "this is
  -- not a declaration", so the widening carries the violation forward VISIBLY
  -- instead of minting the identity §8 I6.1 forbids.  The answer is unchanged —
  -- `headKeyName (HkRigid n) == n`, exactly the `Some n` this arm gave before.
  TRigid n => Some (HkRigid n)
  -- #1617, the GOAL half of the same bite — and it MUST land with
  -- `headTyconTy`'s `TyFun` arm, never alone.  This is the projection
  -- `goalHeadCon` reads, so it is what decides which bucket
  -- `ieSelectRowByMethod`/`ieSelectRowByIface` search; fixing only the impl side
  -- would file the arrow-headed impls into a bucket no goal ever keys, i.e.
  -- would move them from "mis-bucketed" to "unreachable".
  TFun _ _ _ => Some (headKeyOfCon OriginBuiltin funHeadTag)
  _ => None

-- The NOMINAL head projection: the name of the declared type constructor, or the
-- rigid, at the head.  It answers a different question from `headTyconMono`, which is
-- CONSTRUCTED (can an instance head key, select or reduce this type?): an arrow is a
-- constructed head (`headTyconMono` keys it `__fun__`) but names no declaration, so it
-- is `None` here by definition.  `inferApp` depends on that `None` (an arrow callee is
-- applied, not reported as a non-function); a reader asking whether a goal is decidable
-- or reducible asks CONSTRUCTED and calls `headTyconMono` (`allConcreteHeads`,
-- `anyConcreteHead`).  Allocates one `Some`.  The GOAL-side half of the Stage A-2 ledger
-- is what this prints, a command, never a number copied down here:
--
--   grep -nw headTyconNameMono compiler/types/typecheck.mdk \
--     | grep -vE '^[0-9]+:[[:space:]]*--' \
--     | grep -vE '^[0-9]+:headTyconNameMono'
--
-- Both filters are load-bearing, for the reason `headTyconNameTy` above
-- gives: the unfiltered command also prints the comments and the definition.
--
-- Deliberately NOT `map headKeyName (headTyconMono t)` — see the same note on
-- `headTyconNameTy` above for why the three duplicated arms are the cheaper of
-- the two prices.  The invariant they owe: these arms and `headTyconMono`'s must
-- classify the same NOMINAL head nodes (`TCon`, `TRigid`), so a new nominal `Mono`
-- head constructor is owed an arm in both (both fall through `_ => None`, the wildcard
-- hazard `AGENTS.md` names; audit them as a set).  `headTyconMono`'s `TFun` arm has no
-- twin here because an arrow is constructed but not nominal.
export
headTyconNameMono : Mono -> Option String
headTyconNameMono t = match headMonoNode t
  TCon n _ => Some n
  TRigid n => Some n
  _ => None

-- An n-tuple TYPE is a saturated left-spine TApp over the synthetic nullary
-- constructor `TCon (tupleHeadTagTc n)` — the constructor NAME string IS the
-- existing `__tupleN__` dispatch tag, so tag/eval parity is automatic and no
-- `Mono.TTuple` constructor is needed.  (Surface `Ty.TyTuple` is unchanged.)
export
tupleMono : List Mono -> Mono
tupleMono ts = tupleSpineOf (tconTupleHead (listLen ts)) ts

export
tupleSpineOf : Mono -> List Mono -> Mono
tupleSpineOf acc [] = acc
tupleSpineOf acc (t :: rest) = tupleSpineOf (TApp acc t) rest

export
findTvarInMonos : List Mono -> Int -> Option Mono
findTvarInMonos [] _ = None
findTvarInMonos (m :: rest) i = match findTvarInMono m i
  Some t => Some t
  None => findTvarInMonos rest i

-- [m] with every variable the scratch substitution binds replaced, deeply.
export
cohApply : Ref (List (Int, Mono)) -> Mono -> Mono
cohApply subst m = match cohResolve subst m
  TApp a b => TApp (cohApply subst a) (cohApply subst b)
  TFun a eff b => TFun (cohApply subst a) eff (cohApply subst b)
  TQual a q => TQual (cohApply subst a) q
  other => other

-- A name no type or type variable can spell, standing in for a signature variable.
export
sigStandIn : Ref Tyvar -> String
sigStandIn cell = "%sig\{intToString (tyvarId cell)}"

export
sigCellsOf : OrdMap Unit -> List (Ref Tyvar) -> List (Ref Tyvar)
sigCellsOf sigIds cells =
  filterList (c => omHasKey (intToString (tyvarId c)) sigIds) cells

-- Each signature variable among [cells], bound to its rigid stand-in.
export
sigRigidBindings : OrdMap Unit -> List (Ref Tyvar) -> List (Int, Mono)
sigRigidBindings sigIds cells =
  map (c => (tyvarId c, TRigid (sigStandIn c))) (sigCellsOf sigIds cells)

-- [pairs] with every signature variable replaced by its rigid stand-in.
export
rigidSigPairs : GraphCtx ->
  OrdMap Unit ->
  List (Mono, Mono) ->
  List (Mono, Mono)
rigidSigPairs gctx sigIds pairs =
  let cells = flatMap (p => monoVarCells (fst p) ++ monoVarCells (snd p)) pairs
  match sigRigidBindings sigIds cells
    [] => pairs
    toRigid =>
      map
        (p => (
          substMono gctx toRigid [] [] (fst p),
          substMono gctx toRigid [] [] (snd p),
        ))
        pairs

export
monoVarCells : Mono -> List (Ref Tyvar)
monoVarCells t = match normalize t
  TVar cell => [cell]
  TApp a b => monoVarCells a ++ monoVarCells b
  TFun a _ b => monoVarCells a ++ monoVarCells b
  TQual a _ => monoVarCells a
  _ => []

export
spineHeadMono : Mono -> Mono
spineHeadMono t = match peelQual t
  TApp f _ => spineHeadMono f
  other => other

export
locEq : Loc -> Loc -> Bool
locEq (Loc f1 a1 b1 c1 d1) (Loc f2 a2 b2 c2 d2) =
  f1 == f2 && a1 == a2 && b1 == b2 && c1 == c2 && d1 == d2

-- strip leading `=>` constraints / effect rows so the walk aligns the method's
-- value type with the occurrence mono.
export
stripTyConstraints : Ty -> Ty
stripTyConstraints (TyConstrained _ t) = stripTyConstraints t
stripTyConstraints (TyEffect _ _ t) = stripTyConstraints t
stripTyConstraints t = t

-- Every dispatch mono has a constructed head (no remaining bare `TVar` at the head): the
-- oracle's is_concrete gate, restricted to the head.  A constructed head with free args
-- (`Maybe a`, `Int -> b`) still uniquely picks the impl, and it never becomes a variable
-- later, so a goal this answers `True` for is decidable now.  An arrow is constructed:
-- arrow-headed impls exist (#1617), so a ground arrow goal is selected like any other, and
-- the selected impl's `requires` are walked by `checkNestedReqs`.
export
allConcreteHeads : List Mono -> Bool
allConcreteHeads [] = True
allConcreteHeads (m :: rest) = isSome (headTyconMono m) && allConcreteHeads rest

-- every row cell's id reachable in a head type — `impl I (Async e)` carries
-- its `e` as a `TEff` argument of the head application.
export
monoIndexEffvarIds : Mono -> List Int
monoIndexEffvarIds m = match normalize m
  TApp a b => monoIndexEffvarIds a ++ monoIndexEffvarIds b
  TFun a r b => monoIndexEffvarIds a ++ rowTailId r ++ monoIndexEffvarIds b
  TEff r => rowTailId r
  TQual a _ => monoIndexEffvarIds a
  TAuth _ => []
  _ => []

-- every unbound tail id the row reaches — a join contributes each member.
export
rowTailId : EffRow -> List Int
rowTailId row = map effvarId (snd (rowFlat row))

-- structural equality of two monos that may contain RIGID tyvars, compared by tyvar
-- IDENTITY.  Deliberately NOT unification: a given must match a goal only when it IS
-- that goal, never by binding the given's variables.
export
monoSameGiven : Mono -> Mono -> Bool
monoSameGiven a b = match peelQual a
  TVar c1 => match peelQual b
    TVar c2 => tyvarId c1 == tyvarId c2
    _ => False
  -- #1111 A-2.10 on the `TCon`/`TCon` pairing (`sameTyConHead`): an in-scope
  -- dict given for `C a.T` no longer answers a goal `C b.T`.  Cross-population
  -- pairs left name-only and not separately probed — armed because the pre-split
  -- arm answered them (`__tupleN__`; see `Mono.TRigid`), and a rigid carries no
  -- origin, so routing them through `sameTyConHead` would answer the same.
  TCon x ox => match peelQual b
    TCon y oy => sameTyConHead x ox y oy
    TRigid y => x == y
    _ => False
  TRigid x => match peelQual b
    TRigid y => x == y
    TCon y _ => x == y
    _ => False
  TApp a1 b1 => match peelQual b
    TApp a2 b2 => monoSameGiven a1 a2 && monoSameGiven b1 b2
    _ => False
  TFun a1 _ b1 => match peelQual b
    TFun a2 _ b2 => monoSameGiven a1 a2 && monoSameGiven b1 b2
    _ => False
  -- an authority index is erased at dispatch: one instance covers every
  -- index of its head (`checkImplHeadIndices`), as coherence's `cohEqR`
  -- already answers
  TAuth _ => match peelQual b
    TAuth _ => True
    _ => False
  -- an effect row is erased the same way: coherence equates every row
  -- (`cohEqR`, `cohStep`), so instance resolution cannot tell two rows apart
  -- and a given must not either
  TEff _ => match peelQual b
    TEff _ => True
    _ => False
  _ => False

-- #1956: the answer to "when are two predicate argument vectors the same predicate?" —
-- pointwise structural identity: equal length, and `monoSameGiven` at every position, in
-- order.  Deliberately NOT unification and deliberately NOT lead-argument-only: the first
-- would let a given bind the goal's variables (the whole reason `monoSameGiven` exists),
-- the second is #1956 itself.  Length is compared by the pattern arms, not by `listLen`,
-- so a prefix can never pass for the whole vector.
export
monoVecSameGiven : List Mono -> List Mono -> Bool
monoVecSameGiven [] [] = True
monoVecSameGiven (a :: arest) (b :: brest) =
  monoSameGiven a b && monoVecSameGiven arest brest
monoVecSameGiven _ _ = False

-- the tyvar ids in a (normalized) mono — single var for a bare constraint arg
export
monoTyvarIds : Mono -> List Int
monoTyvarIds m = match normalize m
  TVar cell => [tyvarId cell]
  TApp a b => monoTyvarIds a ++ monoTyvarIds b
  TFun a _ b => monoTyvarIds a ++ monoTyvarIds b
  TQual a _ => monoTyvarIds a
  _ => []

-- peel up to [n] arrow domains off [t], normalizing at each level.  A signature
-- with fewer arrows than the clause has params stops early and returns fewer
-- domains (the mismatch then surfaces at the per-clause `unify v arrow`).
export
peelArrows : Int -> Mono -> List Mono
peelArrows n t
  | n <= 0 = []
  | otherwise = match normalize t
    TFun a _ b => a :: peelArrows (n - 1) b
    _ => []

-- True iff [m] normalizes to an unbound tyvar (also the spine head of `m a`).
export
isBareTyvarMono : Mono -> Bool
isBareTyvarMono m = match normalize m
  TVar _ => True
  _ => False

-- does this goal vector contain NO type variable at all?  Deliberately stricter than
-- `isEmptyL (flatMap monoUnboundIds args)`, whose `TRigid _ => []` arm reports a
-- DECLARED context's skolemized variables as if they were ground — which is #1939
-- shape (1) verbatim, so reusing it here would have left half the issue standing.
-- Same structural walk otherwise; `TCon` is a LEAF (`TCon String TyConOrigin`, no
-- argument list — application is `TApp`).
export
monoVectorClosed : List Mono -> Bool
monoVectorClosed args = allList monoClosed args

export
monoClosed : Mono -> Bool
monoClosed t = match normalize t
  TVar _ => False
  TRigid _ => False
  TCon _ _ => True
  TApp a b => monoClosed a && monoClosed b
  TFun a _ b => monoClosed a && monoClosed b
  TEff _ => True
  TAuth _ => True
  TQual a _ => monoClosed a

export
schemeBodyOf : Scheme -> Mono
schemeBodyOf (Forall _ _ _ _ _ body) = body

-- is this argument's dispatch head a real type CONSTRUCTOR?  `headTyconMono`'s
-- `TRigid n => Some (HkRigid n)` arm is DICT-SEMANTICS §8 I6.1's known forgery — a type
-- PARAMETER name handed out as a dispatch key, preserved deliberately for answer
-- parity — and `HkRigid` exists precisely so a reader can tell the two apart.  This is
-- such a reader: a rigid head means the goal is not open in the way an open world can
-- close, it is a variable nothing will ever ground, and it must keep rejecting.
export
monoHeadIsDecl : Mono -> Bool
monoHeadIsDecl m = match headTyconMono m
  Some (HkRigid _) => False
  Some _ => True
  None => False

-- does at least ONE argument carry a constructed head (a type constructor, a rigid or an
-- arrow)?  The per-argument twin of `allConcreteHeads`: `False` means the whole vector is
-- head-free, hence terminal for
-- §3 reduction (nothing to match an impl head against).  See `residualPredsOf` for why
-- the vector test must be ANY and not ALL — issue 1560.  It asks whether a goal posed
-- at a binder, an impl body or a super instance's context is the binder's own
-- predicate; whether a super goal is a selection is decided by what answers it
-- (`goalAnsweredBy`), not by this.
export
anyConcreteHead : List Mono -> Bool
anyConcreteHead args = anyListM (m => isSome (headTyconMono m)) args

export
schemeIds : Scheme -> List Int
schemeIds (Forall ids _ _ _ _ _) = ids

export
findTvName : Int -> List (String, Mono) -> Option String
findTvName _ [] = None
findTvName id ((n, mono) :: rest) = match normalize mono
  TVar cell => if tyvarId cell == id then Some n else findTvName id rest
  _ => findTvName id rest

monoSpineHeadIsCon : Mono -> Bool
monoSpineHeadIsCon m = match peelQual m
  TApp a _ => monoSpineHeadIsCon a
  TCon _ _ => True
  -- The compatibility probe still treats a rigid head as concrete (#1110).
  TRigid _ => True
  _ => False

-- [t] with the rigid stand-in of each of [sigCells] replaced by that variable.
export
unrigidSig : List (Ref Tyvar) -> Mono -> Mono
unrigidSig sigCells t = match normalize t
  TRigid n => match filterList (c => sigStandIn c == n) sigCells
    c :: _ => TVar c
    [] => TRigid n
  TApp a b => TApp (unrigidSig sigCells a) (unrigidSig sigCells b)
  TFun a eff b => TFun (unrigidSig sigCells a) eff (unrigidSig sigCells b)
  TQual a q => TQual (unrigidSig sigCells a) q
  other => other

-- the ids of [monos] that are still ABSTRACT type variables, in order.  The filter
-- `declaredPredicateSlots` keeps a slot by, factored so that the slot's existence and
-- its argument vector are decided by one test (a disagreement desynchronizes a
-- slot's `psBoundIds` from its `psArgs` in `funPredicateSlotsRef`).
export
abstractSlotIds : List Mono -> List Int
abstractSlotIds [] = []
abstractSlotIds (mono :: rest) = match normalize mono
  TVar cell => tyvarId cell :: abstractSlotIds rest
  _ => abstractSlotIds rest

-- #1937: a STRUCTURED argument whose free ids are ALL scheme-bound now carries too.
-- The clause this replaces required a structured argument to be GROUND, because
-- `substOblArgs` substituted only at a top-level `TVar` and would have carried the
-- signature's own tyvar cell into the caller's goal.  That walk is now structural, so
-- the instantiation this admission promises is one the channel can actually perform;
-- the two halves are a single change (admitting without it substitutes to a
-- wrong-but-CONCRETE goal, strictly worse than the missing one it replaces).  An
-- UNBOUND tyvar anywhere in the argument is still refused — it has no id to defer on.
export
declaredOblArgOk : (Int -> Bool) -> Mono -> Bool
declaredOblArgOk isBound m = match normalize m
  TVar cell => isBound (tyvarId cell)
  _ => allList isBound (monoTyvarIds m)

-- S-nonlead-arg-identity (#1904): ONE predicate-argument position, rendered as a
-- PREFIX-FREE PREORDER of the normalized mono, so the key REALISES the sprint's settled
-- notion of "same predicate" — pointwise `monoSameGiven` over the vector — rather than a
-- weaker local one.  Every arm below mirrors an arm of `monoSameGiven`:
--   * `TVar` keys on the tyvar's IDENTITY, not on its mere presence.  This is the whole
--     fix: the old encoding keyed EVERY tyvar position as the constant "*", so
--     `(Ix a b c, Ix a c b)` rendered `Ix|*,*,*` twice and `dedupSlotVecs` collapsed two
--     predicates into ONE dict slot (#1904, S0: `ix n x y + ix n y x` summed 333+333
--     instead of 333+111).  `vecOblKey` survived that only because `voIds` carries every
--     position's id in a SECOND component; `cslotVecKey` composes `cslotKey`, which
--     carries the LEAD id alone (`csId`), so it had no per-position id anywhere.
--   * `TCon`/`TRigid` fold to the same rendering because `monoSameGiven` equates them by
--     name across those two constructors.
--   * `TApp`/`TFun` recurse structurally, so the key sees the SPINE, not just the head —
--     `Ix (Pair a b) (Pair c d)` and `Ix (Pair a c) (Pair b d)` are now distinct, where a
--     head-name-plus-flattened-ids encoding (`xmodOblArgId`'s shape) would tie.
--   * `TEff` and `TAuth` (the remaining arms) key as the constant "*", realising
--     `monoSameGiven`'s erasure: it equates any two effect rows, and any two authorities.
-- One deliberate residual under-split: TYCON ORIGIN is dropped (name only, as
-- `headTyconNameMono` always did).  It cannot be folded into a key string at all:
-- `sameTyConHead`'s absent-origin arm is non-transitive, so no string equivalence can
-- realise it.
-- Injectivity: each arm emits a self-delimiting tag — "v"+digits+"." , "c"+`lenKey`, and
-- the fixed-arity "a"/"f" — so a preorder walk parses back uniquely and the joined vector
-- key is injective over the vector.
-- Raw tyvar ids in A KEY STRING: safe HERE, and not by an "ids are unique" claim.
-- `cslotKey` already folds the raw lead `csId` into this same key, and the non-lead ids
-- come from the SAME predicate occurrence in the SAME signature, normalized together.
-- Both `dedupSlotVecs` call sites compare keys only WITHIN one binding's slot list
-- (a call's declared slots, `setFunConstraintEntry`'s declared prefix) and
-- `vecOblKey`'s `voIds` are equally raw — so this adds no exposure the lead id did not
-- already carry.  The G4 hazard at `registerPredGiven` is about `activeDictVars`, which
-- no key here consults.
export
oblArgKey : Mono -> String
oblArgKey m = match normalize m
  TVar cell => "v\{intToString (tyvarId cell)}."
  TCon name _ => "c\{lenKey name}"
  TRigid name => "c\{lenKey name}"
  TApp a b => "a\{oblArgKey a}\{oblArgKey b}"
  TFun a _ b => "f\{oblArgKey a}\{oblArgKey b}"
  TQual a _ => oblArgKey a
  _ => "*"

-- test-only observation: declarations whose only callers are tests and probes.

export
exactReturnRequestOfGoal : Obligation -> Option MethodReturnRequest
exactReturnRequestOfGoal goal = match goal.oPayload
  GPSite _ _ (SKExactReturn _ request) => Some request
  _ => None

-- every super slot in a `requires` chain carries the SAME id; represent the slot by it.
export
firstOrZero : List Int -> Int
firstOrZero [] = 0
firstOrZero (x :: _) = x

export
allMethodParamsMentioned : List String -> Ty -> Bool
allMethodParamsMentioned [] _ = True
allMethodParamsMentioned (param :: rest) ty =
  argMentions [param] (stripTyConstraints ty)
    && allMethodParamsMentioned rest ty

-- Impl decls paired with their `requires` (implHeadsOf drops reqs; this keeps them).
export
implDeclsWithReqs : List Decl -> List (IfaceRef, List Ty, List Require)
implDeclsWithReqs prog = flatMap implDeclWithReqs prog

implDeclWithReqs : Decl -> List (IfaceRef, List Ty, List Require)
implDeclWithReqs (DAttrib _ d) = implDeclWithReqs d
implDeclWithReqs (DImpl { iface, tys, reqs, implOrigin, ... }) =
  [(IfaceRef { irName = iface, irOrigin = implOrigin }, tys, reqs)]
implDeclWithReqs _ = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "Ident" true) (mem "Lit" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true) (mem "Require" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "identOriginFold" false) (mem "propParamName" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "normalizeLink" false) (mem "ppGo" false) (mem "tupleHeadTagTc" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authIsTop" false) (mem "authJoinAll" false) (mem "authNorm" false) (mem "authSub" false) (mem "authvarId" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomsNorm" false) (mem "effrowNorm" false) (mem "effvarId" false) (mem "findAtom" false) (mem "pureRow" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "HeadVarRoot" true) (mem "MethodReturnRequest" true) (mem "MStep" true) (mem "Obligation" true) (mem "Predicate" true) (mem "RecordInfo" true) (mem "SiteKind" true) (mem "Windowed" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "eqStr" false) (mem "filterList" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "minI" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyIdent" false) (mem "headKeyOfCon" false) (mem "headKeyTag" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "funHeadTag" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "authorityParamSubst" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true) (mem "Wanted" true))))
(DUse false (UseGroup ("list") ((mem "take" false))))
(DTypeSig true "effectCells" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "effectCells" ((PVar "mono") (PVar "cells")) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "effectCells") (EVar "b")) (EApp (EApp (EVar "effectCells") (EVar "a")) (EApp (EApp (EVar "effectRowCells") (EVar "row")) (EVar "cells"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "effectCells") (EVar "b")) (EApp (EApp (EVar "effectCells") (EVar "a")) (EVar "cells")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "effectRowCells") (EVar "row")) (EVar "cells"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "effectCells") (EVar "a")) (EVar "cells"))) (arm (PCon "TAuth" PWild) () (EVar "cells")) (arm PWild () (EVar "cells"))))
(DTypeSig false "effectRowCells" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "effectRowCells" ((PVar "row") (PVar "cells")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "cell")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "cells")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "cellIdSet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "cellIdSet" ((PVar "cells")) (EApp (EApp (EVar "cellIdSetGo") (EVar "cells")) (EVar "Tip")))
(DTypeSig false "cellIdSetGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "cellIdSetGo" ((PList) (PVar "ids")) (EVar "ids"))
(DFunDef false "cellIdSetGo" ((PCons (PVar "cell") (PVar "cells")) (PVar "ids")) (EApp (EApp (EVar "cellIdSetGo") (EVar "cells")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "effvarId") (EVar "cell"))) (ELit LUnit)) (EVar "ids"))))
(DTypeSig true "nthArgMono" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthArgMono" ((PLit (LInt 0)) (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "a") PWild PWild) () (EApp (EVar "Some") (EVar "a"))) (arm PWild () (EVar "None"))))
(DFunDef false "nthArgMono" ((PVar "n") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EApp (EApp (EVar "nthArgMono") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b"))) (arm PWild () (EVar "None"))))
(DTypeSig true "containsI" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "containsI" (PWild (PList)) (EVar "False"))
(DFunDef false "containsI" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "containsI") (EVar "x")) (EVar "ys"))))
(DTypeSig true "invocationHeadKey" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "invocationHeadKey" ((PVar "h")) (EMatch (EApp (EVar "headTyconMono") (EVar "h")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (ELit (LString "?")))))
(DTypeSig true "instantiateFields" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "instantiateFields" ((PVar "gctx") (PVar "args") (PTuple (PVar "params") (PVar "fieldTys"))) (EBlock (DoLet false false (PVar "asub") (EApp (EApp (EVar "authorityParamSubst") (EVar "params")) (EVar "args"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EListLit)) (EListLit)) (EVar "asub"))) (EVar "fieldTys")))))
(DTypeSig true "isPreludeOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))
(DFunDef false "isPreludeOrigin" ((PCon "OriginModule" (PVar "m"))) (EBinOp "==" (EVar "m") (ELit (LString "core"))))
(DFunDef false "isPreludeOrigin" (PWild) (EVar "False"))
(DTypeSig true "headIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "headIdConflict" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "tconIdConflict") (EApp (EVar "spineHead") (EVar "a"))) (EApp (EVar "spineHead") (EVar "b"))))
(DTypeSig true "spineHead" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "spineHead" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "firstIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "firstIdConflict" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))) (arm (PTuple (PCon "TApp" (PVar "f1") (PVar "x1")) (PCon "TApp" (PVar "f2") (PVar "x2"))) () (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "firstIdConflict") (EVar "f1")) (EVar "f2"))) (EApp (EApp (EVar "firstIdConflict") (EVar "x1")) (EVar "x2")))) (arm (PTuple (PCon "TFun" (PVar "d1") PWild (PVar "r1")) (PCon "TFun" (PVar "d2") PWild (PVar "r2"))) () (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "firstIdConflict") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EVar "firstIdConflict") (EVar "r1")) (EVar "r2")))) (arm (PTuple (PVar "x") (PVar "y")) () (EApp (EApp (EVar "tconIdConflict") (EVar "x")) (EVar "y")))))
(DTypeSig false "tconIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "tconIdConflict" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))) (arm (PTuple (PCon "TCon" (PVar "n1") (PVar "o1")) (PCon "TCon" (PVar "n2") (PVar "o2"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n1")) (EVar "o1")) (EVar "n2")) (EVar "o2")))) (EApp (EVar "Some") (ETuple (EVar "n1") (EVar "o1") (EVar "o2"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig true "qualifierAuthIds" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "qualifierAuthIds" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "b")) (EApp (EApp (EVar "qualifierAuthIds") (EVar "a")) (EVar "acc")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "inner")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authIdsIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authIdsIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authIdsIn") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EApp (EApp (EVar "rowAuthIds") (EVar "row")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authIdsIn") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "rowAuthIds") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authIdsIn") (EVar "inner")) (EApp (EApp (EVar "authTermIds") (EVar "q")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authTermIds") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig false "rowAuthIds" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "rowAuthIds" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "atom")) (EApp (EApp (EVar "authTermIds") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "m")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authTermIds" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authTermIds" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "authvarIdOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Int")))
(DFunDef false "authvarIdOf" ((PTuple PWild (PVar "cell"))) (EApp (EVar "authvarId") (EVar "cell")))
(DTypeSig true "effvarIdOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Int")))
(DFunDef false "effvarIdOf" ((PTuple PWild (PVar "cell"))) (EApp (EVar "effvarId") (EVar "cell")))
(DTypeSig true "litType" (TyFun (TyCon "Lit") (TyCon "Mono")))
(DFunDef false "litType" ((PCon "LInt" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DFunDef false "litType" ((PCon "LFloat" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Float"))))
(DFunDef false "litType" ((PCon "LString" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "String"))))
(DFunDef false "litType" ((PCon "LChar" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Char"))))
(DFunDef false "litType" ((PCon "LBool" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DFunDef false "litType" ((PCon "LUnit")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))
(DFunDef false "litType" ((PCon "LU64" PWild PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "U64"))))
(DFunDef false "litType" ((PCon "LI64" PWild PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "I64"))))
(DTypeSig true "foldrFun" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "foldrFun" ((PList) (PVar "result")) (EVar "result"))
(DFunDef false "foldrFun" ((PCons (PVar "a") (PVar "rest")) (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "a")) (EVar "pureRow")) (EApp (EApp (EVar "foldrFun") (EVar "rest")) (EVar "result"))))
(DTypeSig true "authOrderIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authOrderIn") (EVar "b")) (EApp (EApp (EVar "authOrderRow") (EVar "row")) (EApp (EApp (EVar "authOrderIn") (EVar "a")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authOrderIn") (EVar "b")) (EApp (EApp (EVar "authOrderIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "authOrderRow") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authOrderTerm") (EVar "q")) (EApp (EApp (EVar "authOrderIn") (EVar "inner")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authOrderTerm") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authOrderRow" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderRow" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "atom")) (EApp (EApp (EVar "authOrderTerm") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "a")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authOrderTerm" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderTerm" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "cell")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "authvarId") (EVar "cell"))) (DoExpr (EIf (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "a")) (EVar "a") (EBinOp "::" (EVar "i") (EVar "a"))))))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "xmodOblArgId" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "xmodOblArgId" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm PWild () (EApp (EVar "monoTyvarIds") (EVar "m")))))
(DTypeSig true "substOblArgs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "substOblArgs" (PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "substOblArgs" ((PVar "ids") (PCons (PVar "m") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "m")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "m2") (EVar "_s")))) (EApp (EApp (EApp (EVar "substOblArgs") (EVar "ids")) (EVar "rest")) (EVar "subst"))))))
(DTypeSig false "substOblArg" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "substOblArg" ((PVar "ids") (PVar "m") (PVar "subst")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "subst")) (arm (PCon "Some" (PVar "m2")) () (EApp (EVar "Some") (EVar "m2"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "ids")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "TVar") (EVar "cell"))))))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EVar "map") (ELam ((PVar "a2")) (EApp (EApp (EVar "TQual") (EVar "a2")) (EVar "q")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "a2")) () (EApp (EApp (EVar "map") (ELam ((PVar "b2")) (EApp (EApp (EVar "TApp") (EVar "a2")) (EVar "b2")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "b")) (EVar "subst")))))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "a2")) () (EApp (EApp (EVar "map") (ELam ((PVar "b2")) (EApp (EApp (EApp (EVar "TFun") (EVar "a2")) (EVar "eff")) (EVar "b2")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "b")) (EVar "subst")))))) (arm (PVar "other") () (EApp (EVar "Some") (EVar "other")))))
(DTypeSig true "substMonos" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "substMonos" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "substMonos" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" (PVar "mono")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "mono") (EVar "_s")))) (EApp (EApp (EVar "substMonos") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "nthFunDomain" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthFunDomain" ((PVar "k") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "a") PWild (PVar "r")) () (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "a")) (EApp (EApp (EVar "nthFunDomain") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "r")))) (arm PWild () (EVar "None"))))
(DTypeSig true "expectedParamTypes" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "expectedParamTypes" (PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "expectedParamTypes" ((PCon "TFun" (PVar "a") PWild (PVar "b")) (PVar "n")) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "expectedParamTypes") (EApp (EVar "normalize") (EVar "b"))) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DFunDef false "expectedParamTypes" (PWild PWild) (EListLit))
(DTypeSig true "containerParamScalarArg" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "containerParamScalarArg" ((PVar "ft") (PVar "xt")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") PWild PWild) () (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TApp" PWild PWild) () (EMatch (EApp (EVar "headTyconNameMono") (EVar "dom")) (arm (PCon "None") () (EMatch (EApp (EVar "normalize") (EVar "xt")) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None")))) (arm (PCon "Some" PWild) () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "funArity" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "funArity" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild PWild (PVar "r")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "funArity") (EVar "r")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "domainIsTupleOfArity" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "domainIsTupleOfArity" ((PVar "ft") (PVar "n")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") PWild PWild) () (EMatch (EApp (EVar "headTyconNameMono") (EVar "dom")) (arm (PCon "Some" (PVar "c")) () (EBinOp "==" (EVar "c") (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "__"))))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "isUnshaped" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isUnshaped" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "recordAuthCells" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "recordAuthCells" ((PList) PWild PWild) (EVar "Tip"))
(DFunDef false "recordAuthCells" (PWild (PVar "result") (PVar "fields")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "f")) (EApp (EApp (EVar "authCellsIn") (EApp (EVar "snd") (EVar "f"))) (EVar "m")))) (EApp (EApp (EVar "authCellsIn") (EVar "result")) (EVar "Tip"))) (EVar "fields")))
(DTypeSig true "applyParams" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "applyParams" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyParams" ((PVar "head") (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "TApp") (EVar "head")) (EVar "p"))) (EVar "ps")))
(DTypeSig true "tupleUnifyClash" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "tupleUnifyClash" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "tupleSpine") (EVar "a")) (EApp (EVar "tupleSpine") (EVar "b"))) (arm (PTuple (PCon "Some" (PVar "xs")) (PCon "Some" (PVar "ys"))) () (EBinOp "/=" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys")))) (arm (PTuple (PCon "Some" PWild) (PCon "None")) () (EApp (EVar "monoSpineHeadIsCon") (EVar "b"))) (arm (PTuple (PCon "None") (PCon "Some" PWild)) () (EApp (EVar "monoSpineHeadIsCon") (EVar "a"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "False"))))
(DTypeSig true "instantiateNamedMonos" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "instantiateNamedMonos" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "instantiateNamedMonos" ((PVar "gctx") (PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest")) (PVar "subst")) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit)) (EVar "mono"))) (EApp (EApp (EApp (EVar "instantiateNamedMonos") (EVar "gctx")) (EVar "rest")) (EVar "subst"))))
(DTypeSig true "headsUnifier" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "headsUnifier" ((PVar "gctx") (PVar "rigidIds") (PVar "args") (PVar "allHeads")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "take") (EApp (EVar "listLen") (EVar "args"))) (EVar "allHeads"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "heads")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EApp (EApp (EApp (EVar "rigidSigPairs") (EVar "gctx")) (EVar "rigidIds")) (EApp (EApp (EVar "zipL") (EVar "args")) (EVar "heads"))))) (EApp (EVar "Some") (EVar "scratch")) (EVar "None")))))
(DTypeSig true "allArrowEffs" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "EffRow"))))
(DFunDef false "allArrowEffs" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "eff") (PVar "b")) () (EBinOp "::" (EVar "eff") (EApp (EVar "allArrowEffs") (EVar "b")))) (arm PWild () (EListLit))))
(DTypeSig true "headVarRootOf" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "HeadVarRoot"))))
(DFunDef false "headVarRootOf" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "Some") (EApp (EVar "TypeVarRoot") (EApp (EVar "tyvarId") (EVar "cell"))))) (arm (PCon "TEff" (PVar "row")) () (EMatch (EApp (EVar "effrowNorm") (EVar "row")) (arm (PCon "EffRow" (PList) (PCon "Some" (PVar "cell"))) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EVar "Some") (EApp (EVar "RowVarRoot") (EVar "id")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "isUnboundTvar" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isUnboundTvar" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "isMonoScheme" (TyFun (TyCon "Scheme") (TyCon "Bool")))
(DFunDef false "isMonoScheme" ((PCon "Forall" (PList) (PList) (PList) PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMonoScheme" (PWild) (EVar "False"))
(DTypeSig true "unquantifiedAuthIds" (TyFun (TyCon "Scheme") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "unquantifiedAuthIds" ((PCon "Forall" PWild PWild (PVar "auths") (PVar "residual") (PVar "force") (PVar "mono"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "id")) (EApp (EApp (EVar "IdMap.delete") (EVar "id")) (EVar "acc")))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "r")) (EApp (EApp (EVar "authTermIds") (EFieldAccess (EVar "r") "arUpper")) (EApp (EApp (EVar "authTermIds") (EFieldAccess (EVar "r") "arLower")) (EVar "acc"))))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EApp (EApp (EVar "rowAuthIds") (EVar "force")) (EVar "Tip")))) (EVar "residual"))) (EVar "auths")))
(DTypeSig true "sigTvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "sigTvarIds" ((PList)) (EListLit))
(DFunDef false "sigTvarIds" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "sigTvarIds") (EVar "rest")))) (arm PWild () (EApp (EVar "sigTvarIds") (EVar "rest")))))
(DTypeSig true "declaredOblArgId" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "declaredOblArgId" ((PVar "boundIds") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) ((GBool (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")))) (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TVar" PWild) () (EListLit)) (arm PWild () (EApp (EApp (EVar "filterList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "boundIds")))) (EApp (EVar "monoTyvarIds") (EVar "m"))))))
(DTypeSig true "boundTyvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "boundTyvarIds" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "boundTyvarIds" ((PVar "boundIds") (PCons (PVar "d") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "d")) (arm (PCon "TVar" (PVar "cell")) ((GBool (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "_s")))) (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "rest")))) (arm PWild () (EVar "None"))))
(DTypeSig true "monosTvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "monosTvarIds" ((PVar "boundIds") (PVar "monos")) (EApp (EApp (EVar "flatMap") (EApp (EVar "boundTvarId") (EVar "boundIds"))) (EVar "monos")))
(DTypeSig true "boundTvarId" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "boundTvarId" ((PVar "boundIds") (PVar "mono")) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")) (EListLit (EApp (EVar "tyvarId") (EVar "cell"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig true "tconBuiltin" (TyFun (TyCon "String") (TyCon "Mono")))
(DFunDef false "tconBuiltin" ((PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "OriginBuiltin")))
(DTypeSig true "tconTupleHead" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "tconTupleHead" ((PVar "n")) (EApp (EApp (EVar "TCon") (EApp (EVar "tupleHeadTagTc") (EVar "n"))) (EVar "OriginBuiltin")))
(DTypeSig true "tconFrom" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "tconFrom" ((PVar "o") (PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "o")))
(DTypeSig true "tconUnresolved" (TyFun (TyCon "String") (TyCon "Mono")))
(DFunDef false "tconUnresolved" ((PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "OriginUnresolved")))
(DTypeSig true "newEffvarId" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "newEffvarId" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EVar "n"))))
(DTypeSig true "effvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "effvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild (PVar "l")) () (EVar "l")) (arm (PCon "ELink" PWild PWild) () (ELit (LInt 0))) (arm (PCon "EJoin" PWild (PVar "l") PWild) () (EVar "l")) (arm (PCon "ESummary" PWild (PVar "l") PWild) () (EVar "l"))))
(DTypeSig true "rowOfMembers" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "EffRow")))))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PList)) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None")))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PList (PVar "m"))) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EVar "m"))))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PVar "ms")) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EApp (EApp (EVar "joinCellOf") (EVar "gctx")) (EVar "ms")))))
(DTypeSig true "joinCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "joinCellOf" ((PVar "gctx") (PVar "ms")) (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "EJoin") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EApp (EVar "minLevelOf") (EVar "ms"))) (EVar "ms"))))
(DTypeSig true "minLevelOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Int")))
(DFunDef false "minLevelOf" ((PList)) (ELit (LInt 0)))
(DFunDef false "minLevelOf" ((PList (PVar "m"))) (EApp (EVar "effvarLevel") (EVar "m")))
(DFunDef false "minLevelOf" ((PCons (PVar "m") (PVar "ms"))) (EApp (EApp (EVar "minI") (EApp (EVar "effvarLevel") (EVar "m"))) (EApp (EVar "minLevelOf") (EVar "ms"))))
(DTypeSig true "effectRoots" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "effectRoots" ((PVar "t") (PVar "roots")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "effectRoots") (EVar "b")) (EApp (EApp (EVar "effectRoots") (EVar "a")) (EApp (EApp (EVar "effectRowRoots") (EVar "row")) (EVar "roots"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "effectRoots") (EVar "b")) (EApp (EApp (EVar "effectRoots") (EVar "a")) (EVar "roots")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "effectRowRoots") (EVar "row")) (EVar "roots"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "effectRoots") (EVar "a")) (EVar "roots"))) (arm (PCon "TAuth" PWild) () (EVar "roots")) (arm PWild () (EVar "roots"))))
(DTypeSig true "effectRowRoots" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "effectRowRoots" ((PVar "row") (PVar "roots")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "roots")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "authRowRoots" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authRowRoots" ((PVar "row") (PVar "roots")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "Tip"))))
(DTypeSig true "substRow" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "EffRow") (TyCon "EffRow"))))))
(DFunDef false "substRow" ((PVar "gctx") (PVar "esub") (PVar "asub") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "labels") (PVar "members")) (EApp (EVar "rowFlat") (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "rowOfMembers") (EVar "gctx")) (EApp (EApp (EVar "substAtoms") (EVar "asub")) (EVar "labels"))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "substMember") (EVar "esub")) (EVar "m")))) (EVar "members"))))))
(DTypeSig false "substAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "substAtoms" ((PList) (PVar "atoms")) (EVar "atoms"))
(DFunDef false "substAtoms" ((PVar "asub") (PVar "atoms")) (EApp (EApp (EVar "map") (EApp (EVar "substAtom") (EVar "asub"))) (EVar "atoms")))
(DTypeSig false "substAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Atom") (TyCon "Atom"))))
(DFunDef false "substAtom" ((PVar "asub") (PCon "Atom" (PVar "l") (PVar "q"))) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q"))))
(DTypeSig true "substAuth" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "substAuth" ((PList) (PVar "q")) (EVar "q"))
(DFunDef false "substAuth" ((PVar "asub") (PVar "q")) (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AVar" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (EApp (EVar "AVar") (EVar "cell"))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "asub")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EApp (EVar "substAuth") (EVar "asub"))) (EVar "ms")))) (arm (PCon "AProduct" (PVar "axes")) () (EApp (EVar "authNorm") (EApp (EVar "AProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))) (arm (PVar "c") () (EVar "c"))))
(DTypeSig false "substMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "substMember" ((PVar "esub") (PVar "m")) (EMatch (EUnOp "!" (EVar "m")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EVar "optionOr") (EVar "m")) (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "esub")))) (arm PWild () (EVar "m"))))
(DTypeSig true "anyListM" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyListM" (PWild (PList)) (EVar "False"))
(DFunDef false "anyListM" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyListM") (EVar "p")) (EVar "xs"))))
(DTypeSig false "monoSize" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoSize" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TApp" (PVar "f") (PVar "a")) () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "f"))) (EApp (EVar "monoSize") (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "r")) () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "a"))) (EApp (EVar "monoSize") (EVar "r")))) (arm (PCon "TQual" (PVar "a") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "a")))) (arm PWild () (ELit (LInt 1)))))
(DTypeSig true "monoSizes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int")))
(DFunDef false "monoSizes" ((PList)) (ELit (LInt 0)))
(DFunDef false "monoSizes" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "+" (EApp (EVar "monoSize") (EVar "m")) (EApp (EVar "monoSizes") (EVar "rest"))))
(DTypeSig true "monoMintedBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "monoMintedBefore" ((PVar "tyvars") (PVar "effvars") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "<" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "tyvars"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a")) (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a")) (EApp (EApp (EVar "rowMintedBefore") (EVar "effvars")) (EVar "r"))) (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "rowMintedBefore") (EVar "effvars")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a"))) (arm PWild () (EVar "True"))))
(DTypeSig false "rowMintedBefore" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowMintedBefore" ((PVar "effvars") (PVar "r")) (EApp (EApp (EVar "allList") (ELam ((PVar "cell")) (EBinOp "<" (EApp (EVar "effvarId") (EVar "cell")) (EVar "effvars")))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "r")))))
(DTypeSig true "walkMonosSame" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "walkMonosSame" ((PList) (PList)) (EVar "True"))
(DFunDef false "walkMonosSame" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "walkMonosSame") (EVar "arest")) (EVar "brest"))))
(DFunDef false "walkMonosSame" (PWild PWild) (EVar "False"))
(DTypeSig false "walkMonoSame" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "walkMonoSame" ((PVar "x") (PVar "y")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "x")) (EApp (EVar "normalize") (EVar "y"))) (arm (PTuple (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EVar "walkMonoSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "walkMonoSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) () (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (arm (PTuple (PCon "TQual" (PVar "t1") (PVar "q1")) (PCon "TQual" (PVar "t2") (PVar "q2"))) () (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2")))) (arm (PTuple (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) () (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2"))) (arm (PTuple (PCon "TQual" PWild PWild) PWild) () (EVar "False")) (arm (PTuple PWild (PCon "TQual" PWild PWild)) () (EVar "False")) (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")))))
(DTypeSig true "tyvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Int")))
(DFunDef false "tyvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" PWild) () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DTypeSig true "monoSpineDepth" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoSpineDepth" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSpineDepth") (EVar "a")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "monoIsApp" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoIsApp" ((PCon "TApp" PWild PWild)) (EVar "True"))
(DFunDef false "monoIsApp" (PWild) (EVar "False"))
(DTypeSig true "dedupI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "dedupI" ((PList)) (EListLit))
(DFunDef false "dedupI" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dedupI" ((PList (PVar "x") (PVar "y"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EListLit (EVar "x")) (EListLit (EVar "x") (EVar "y"))))
(DFunDef false "dedupI" ((PVar "xs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EVar "Tip")) (EListLit))))
(DTypeSig false "dedupIGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "dedupIGo" ((PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "dedupIGo" ((PCons (PVar "x") (PVar "xs")) (PVar "seen") (PVar "result")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "x")) (EVar "seen")) (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EVar "seen")) (EVar "result")) (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "x") (EVar "result")))))
(DTypeSig true "authCellsIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authCellsIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authCellsIn") (EVar "b")) (EApp (EApp (EVar "authCellsIn") (EVar "a")) (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authCellsIn") (EVar "b")) (EApp (EApp (EVar "authCellsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authCellsIn") (EVar "inner")) (EApp (EApp (EVar "authTermCells") (EVar "q")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authTermCells") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authRowCells" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authRowCells" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "atom")) (EApp (EApp (EVar "authTermCells") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "m")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authTermCells" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authTermCells" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "cell")) (EVar "m")))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "authRoots" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authRoots" ((PVar "t") (PVar "roots")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip"))))
(DTypeSig true "substMono" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "substMono" ((PVar "gctx") (PVar "subst") (PVar "esub") (PVar "asub") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (EApp (EVar "TVar") (EVar "cell"))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "subst")))) (arm (PAs "c" (PCon "TCon" PWild PWild)) () (EVar "c")) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "TRigid") (EVar "n"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "a"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "substRow") (EVar "gctx")) (EVar "esub")) (EVar "asub")) (EVar "eff"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EVar "TEff") (EApp (EApp (EApp (EApp (EVar "substRow") (EVar "gctx")) (EVar "esub")) (EVar "asub")) (EVar "r")))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "inner"))) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EVar "TAuth") (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q"))))))
(DTypeSig true "stripEff" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripEff" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EVar "t"))
(DFunDef false "stripEff" ((PVar "t")) (EVar "t"))
(DTypeSig true "tyVarNames" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarNames" ((PCon "TyVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "tyVarNames" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "a")) (EApp (EVar "tyVarNames") (EVar "b"))))
(DFunDef false "tyVarNames" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "a")) (EApp (EVar "tyVarNames") (EVar "b"))))
(DFunDef false "tyVarNames" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "ts")))
(DFunDef false "tyVarNames" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyVarNames") (EVar "t")))
(DTypeSig true "tyAppSpine" (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "tyAppSpine" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EVar "a")) (arm (PTuple (PVar "head") (PVar "args")) () (ETuple (EVar "head") (EBinOp "++" (EVar "args") (EListLit (EVar "b")))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (ETuple (EVar "t") (EListLit)))
(DTypeSig true "monoScheme" (TyFun (TyCon "Mono") (TyCon "Scheme")))
(DFunDef false "monoScheme" ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EVar "t")))
(DTypeSig true "schemeAuthIds" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "schemeAuthIds" ((PCon "Forall" PWild PWild (PVar "avars") PWild PWild PWild)) (EVar "avars"))
(DTypeSig true "tyArrowCount" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "tyArrowCount" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyArrowCount") (EVar "t")))
(DFunDef false "tyArrowCount" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyArrowCount") (EVar "t")))
(DFunDef false "tyArrowCount" ((PCon "TyFun" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "tyArrowCount") (EVar "b"))))
(DFunDef false "tyArrowCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "arrowArity" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "arrowArity" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "arrowArity") (EVar "b")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "arrowArity") (EVar "inner"))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "stripArrows" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "stripArrows" ((PCon "TFun" PWild PWild (PVar "b"))) (EApp (EVar "stripArrows") (EVar "b")))
(DFunDef false "stripArrows" ((PVar "t")) (EVar "t"))
(DTypeSig true "recordOwnerModule" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "recordOwnerModule" ((PVar "ri")) (EMatch (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hk")) () (EMatch (EApp (EVar "headKeyIdent") (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "Ident" PWild (PVar "io") PWild)) () (EApp (EApp (EApp (EVar "identOriginFold") (EVar "None")) (ELam ((PVar "mid")) (EApp (EVar "Some") (EVar "mid")))) (EVar "io")))))))
(DTypeSig true "rowSame" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowSame" ((PVar "r1") (PVar "r2")) (EBlock (DoLet false false (PTuple (PVar "atoms1") (PVar "tails1")) (EApp (EVar "rowFlat") (EVar "r1"))) (DoLet false false (PTuple (PVar "atoms2") (PVar "tails2")) (EApp (EVar "rowFlat") (EVar "r2"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "map") (EVar "effvarId")) (EVar "tails1")) (EApp (EApp (EVar "map") (EVar "effvarId")) (EVar "tails2"))) (EApp (EApp (EVar "atomsSame") (EApp (EVar "atomsNorm") (EVar "atoms1"))) (EApp (EVar "atomsNorm") (EVar "atoms2")))))))
(DTypeSig false "atomsSame" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Bool"))))
(DFunDef false "atomsSame" ((PList) (PList)) (EVar "True"))
(DFunDef false "atomsSame" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "atomKey") (EVar "y"))) (EApp (EApp (EVar "authSame") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EApp (EApp (EVar "atomsSame") (EVar "xs")) (EVar "ys"))))
(DFunDef false "atomsSame" (PWild PWild) (EVar "False"))
(DTypeSig true "authSame" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSame" ((PVar "p") (PVar "q")) (EBinOp "&&" (EApp (EApp (EVar "authSub") (EVar "p")) (EVar "q")) (EApp (EApp (EVar "authSub") (EVar "q")) (EVar "p"))))
(DTypeSig true "recordResultMono" (TyFun (TyCon "RecordInfo") (TyCon "Mono")))
(DFunDef false "recordResultMono" ((PCon "RecordInfo" PWild PWild (PVar "result") PWild PWild)) (EVar "result"))
(DTypeSig true "rootIdOf" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "rootIdOf" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" (PVar "t")) () (EApp (EVar "rootVarId") (EApp (EApp (EVar "normalizeLink") (EVar "cell")) (EVar "t"))))))
(DFunDef false "rootIdOf" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig false "rootVarId" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "rootVarId" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" PWild) () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DFunDef false "rootVarId" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "sameRootId" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "sameRootId" ((PVar "id") (PVar "v")) (EBinOp "==" (EApp (EVar "rootIdOf") (EVar "v")) (EVar "id")))
(DTypeSig true "monoIsBool" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoIsBool" ((PCon "TCon" (PLit (LString "Bool")) PWild)) (EVar "True"))
(DFunDef false "monoIsBool" (PWild) (EVar "False"))
(DTypeSig true "resultAfterArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "resultAfterArrows" ((PVar "n") (PVar "t")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "t")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EApp (EApp (EVar "resultAfterArrows") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "monoHasArrowInSlot" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHasArrowInSlot" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrow") (EVar "b")) (EApp (EVar "monoHasArrowInSlot") (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrowInSlot") (EVar "a")) (EApp (EVar "monoHasArrowInSlot") (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig false "monoHasArrow" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHasArrow" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild PWild) () (EVar "True")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrow") (EVar "a")) (EApp (EVar "monoHasArrow") (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig true "monoIsTyvarId" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "monoIsTyvarId" ((PVar "m") (PVar "id")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm PWild () (EVar "False"))))
(DTypeSig true "matchCol0Type" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "matchCol0Type" ((PVar "ty")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "ty")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "headTyconMono") (EVar "ty")) (arm (PCon "Some" (PCon "HkDecl" (PVar "k"))) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "Some" (PCon "HkRigid" PWild)) () (EApp (EVar "Some") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "n"))))))))
(DTypeSig true "nthTy" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "nthTy" (PWild (PList)) (EVar "None"))
(DFunDef false "nthTy" ((PVar "i") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "t")) (EIf (EVar "otherwise") (EApp (EApp (EVar "nthTy") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "collectAuthvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectAuthvarIds" ((PCons (PCon "TAuth" (PCon "AVar" (PVar "cell"))) (PVar "rs"))) (EBinOp "::" (EApp (EVar "authvarId") (EVar "cell")) (EApp (EVar "collectAuthvarIds") (EVar "rs"))))
(DFunDef false "collectAuthvarIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectAuthvarIds") (EVar "rs")))
(DFunDef false "collectAuthvarIds" ((PList)) (EListLit))
(DTypeSig true "collectTyIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectTyIds" ((PCons (PCon "TVar" (PVar "cell")) (PVar "rs"))) (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "collectTyIds") (EVar "rs"))))
(DFunDef false "collectTyIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectTyIds") (EVar "rs")))
(DFunDef false "collectTyIds" ((PList)) (EListLit))
(DTypeSig true "collectRowEffvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectRowEffvarIds" ((PCons (PCon "TEff" (PCon "EffRow" PWild (PCon "Some" (PVar "cell")))) (PVar "rs"))) (EBinOp "::" (EApp (EVar "effvarId") (EVar "cell")) (EApp (EVar "collectRowEffvarIds") (EVar "rs"))))
(DFunDef false "collectRowEffvarIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectRowEffvarIds") (EVar "rs")))
(DFunDef false "collectRowEffvarIds" ((PList)) (EListLit))
(DTypeSig true "monoTyvarId" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoTyvarId" ((PCon "TVar" (PVar "cell"))) (EApp (EVar "tyvarId") (EVar "cell")))
(DFunDef false "monoTyvarId" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "schemeMono" (TyFun (TyCon "Scheme") (TyCon "Mono")))
(DFunDef false "schemeMono" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig true "monoUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoUnboundIds" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoUnboundIds") (EVar "a")))))
(DTypeSig true "monoArgUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoArgUnboundIds" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoArgUnboundIds") (EVar "b")))) (arm PWild () (EListLit))))
(DTypeSig true "monoRootIdSet" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "monoRootIdSet" ((PVar "monos")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "monos"))))) (EVar "omEmpty")))
(DTypeSig true "concreteHeadVarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "concreteHeadVarIds" ((PVar "dm")) (EMatch (EApp (EVar "headTyconMono") (EVar "dm")) (arm (PCon "Some" PWild) () (EApp (EVar "monoUnboundIds") (EVar "dm"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "argMentions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "argMentions" ((PVar "typarams") (PVar "ty")) (EApp (EApp (EVar "anyMember") (EApp (EVar "tyVarNames") (EVar "ty"))) (EVar "typarams")))
(DTypeSig true "anyMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyMember" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "any") (ELam ((PVar "x")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")))) (EVar "xs")))
(DTypeSig true "propParamNamesTc" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesTc" ((PVar "ps")) (EApp (EApp (EVar "map") (EVar "propParamName")) (EVar "ps")))
(DTypeSig true "patVarsTc" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsTc" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsTc" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListTc") (EVar "args")))
(DFunDef false "patVarsTc" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsTc") (EVar "h")) (EApp (EVar "patVarsTc") (EVar "t"))))
(DFunDef false "patVarsTc" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListTc") (EVar "ps")))
(DFunDef false "patVarsTc" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListTc") (EVar "ps")))
(DFunDef false "patVarsTc" ((PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsTc") (EVar "p"))))
(DFunDef false "patVarsTc" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldVarsTc")) (EVar "fields")))
(DFunDef false "patVarsTc" (PWild) (EListLit))
(DTypeSig true "patVarsListTc" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListTc" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patVarsTc")) (EVar "ps")))
(DTypeSig false "recPatFieldVarsTc" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsTc" ((PCon "RecPatField" (PVar "label") PWild PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsTc" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsTc") (EVar "p")))
(DTypeSig true "nthMono" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthMono" (PWild (PList)) (EVar "None"))
(DFunDef false "nthMono" ((PVar "k") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "x")) (EApp (EApp (EVar "nthMono") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "cohOverlap" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohOverlap" ((PVar "xs") (PVar "ys")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys"))) (EApp (EApp (EVar "cohOverlapGo") (EApp (EVar "Ref") (EListLit))) (EApp (EApp (EVar "zipL") (EVar "xs")) (EVar "ys"))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cohOverlapGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "cohOverlapGo" (PWild (PList)) (EVar "True"))
(DFunDef false "cohOverlapGo" ((PVar "subst") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")) (EApp (EApp (EVar "cohOverlapGo") (EVar "subst")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohResolve" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "cohResolve" ((PVar "subst") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EUnOp "!" (EVar "subst"))) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m2"))) (arm (PCon "None") () (EApp (EVar "TVar") (EVar "cell"))))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "cohGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohGo" ((PVar "subst") (PVar "t1") (PVar "t2")) (EApp (EApp (EApp (EVar "cohGoR") (EVar "subst")) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "t1"))) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "t2"))))
(DTypeSig false "cohGoR" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c1"))) (EApp (EVar "TVar") (EVar "c2"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TVar" (PVar "c1")) (PVar "t")) (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c1"))) (EVar "t")))
(DFunDef false "cohGoR" ((PVar "subst") (PVar "t") (PCon "TVar" (PVar "c2"))) (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c2"))) (EVar "t")))
(DFunDef false "cohGoR" (PWild (PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "cohGoR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" (PWild (PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a1")) (EVar "a2"))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TFun" (PVar "a1") PWild (PVar "b1")) (PCon "TFun" (PVar "a2") PWild (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "b1")) (EVar "b2"))))
(DFunDef false "cohGoR" (PWild (PCon "TEff" PWild) (PCon "TEff" PWild)) (EVar "True"))
(DFunDef false "cohGoR" (PWild (PCon "TAuth" PWild) (PCon "TAuth" PWild)) (EVar "True"))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")))
(DFunDef false "cohGoR" ((PVar "subst") (PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")))
(DFunDef false "cohGoR" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "cohBind" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohBind" ((PVar "subst") (PVar "id") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "m")) (EVar "False") (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "subst")) (EBinOp "::" (ETuple (EVar "id") (EVar "m")) (EUnOp "!" (EVar "subst"))))) (DoExpr (EVar "True")))))
(DTypeSig false "cohOccurs" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohOccurs" ((PVar "subst") (PVar "id") (PVar "m")) (EMatch (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm (PCon "TApp" (PVar "f") (PVar "a")) () (EBinOp "||" (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "f")) (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a")) (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a"))) (arm PWild () (EVar "False"))))
(DTypeSig true "matchOneSided" (TyFun (TyFun (TyVar "g") (TyFun (TyVar "s") (TyApp (TyApp (TyApp (TyCon "MStep") (TyVar "k")) (TyVar "g")) (TyVar "s")))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "k") (TyCon "Bool"))) (TyFun (TyFun (TyVar "s") (TyFun (TyVar "s") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "g") (TyVar "s"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "s"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "s"))))))))))
(DFunDef false "matchOneSided" (PWild PWild PWild (PList) (PVar "acc")) (EApp (EVar "Some") (EVar "acc")))
(DFunDef false "matchOneSided" ((PVar "step") (PVar "keyEq") (PVar "eqS") (PCons (PTuple (PVar "g") (PVar "s")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "step") (EVar "g")) (EVar "s")) (arm (PCon "MFail") () (EVar "None")) (arm (PCon "MOk") () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EVar "acc"))) (arm (PCon "MKids" (PVar "kids")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EBinOp "++" (EVar "kids") (EVar "rest"))) (EVar "acc"))) (arm (PCon "MVar" (PVar "k")) () (EMatch (EApp (EApp (EApp (EVar "lookupBy") (EVar "keyEq")) (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PVar "prev")) () (EIf (EApp (EApp (EVar "eqS") (EVar "prev")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EVar "acc")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "s")) (EVar "acc"))))))))
(DTypeSig false "lookupBy" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "k") (TyCon "Bool"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "lookupBy" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupBy" ((PVar "keq") (PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "keq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EApp (EVar "lookupBy") (EVar "keq")) (EVar "k")) (EVar "rest"))))
(DTypeSig true "cohEqMono" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "cohEqMono" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "cohEqR") (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "cohEqR" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "cohEqR" ((PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))))
(DFunDef false "cohEqR" ((PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "cohEqR" ((PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EVar "cohEqMono") (EVar "f1")) (EVar "f2")) (EApp (EApp (EVar "cohEqMono") (EVar "a1")) (EVar "a2"))))
(DFunDef false "cohEqR" ((PCon "TFun" (PVar "a1") PWild (PVar "b1")) (PCon "TFun" (PVar "a2") PWild (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EVar "cohEqMono") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "cohEqMono") (EVar "b1")) (EVar "b2"))))
(DFunDef false "cohEqR" ((PCon "TEff" PWild) (PCon "TEff" PWild)) (EVar "True"))
(DFunDef false "cohEqR" ((PCon "TAuth" PWild) (PCon "TAuth" PWild)) (EVar "True"))
(DFunDef false "cohEqR" ((PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EVar "cohEqR") (EApp (EVar "normalize") (EVar "a"))) (EVar "b")))
(DFunDef false "cohEqR" ((PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EVar "cohEqR") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "cohEqR" (PWild PWild) (EVar "False"))
(DTypeSig true "matchEqMono" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "matchEqMono" ((PVar "subst") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "matchEqR") (EVar "subst")) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "b"))))
(DTypeSig false "matchEqR" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "matchEqR" (PWild (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))))
(DFunDef false "matchEqR" (PWild (PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "matchEqR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" (PWild (PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a1")) (EVar "a2"))))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "matchEqRow") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "b1")) (EVar "b2"))))
(DFunDef false "matchEqR" (PWild (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) (EApp (EApp (EVar "matchEqRow") (EVar "r1")) (EVar "r2")))
(DFunDef false "matchEqR" (PWild (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) (EApp (EApp (EVar "matchEqAuth") (EVar "q1")) (EVar "q2")))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TQual" (PVar "a") (PVar "q1")) (PCon "TQual" (PVar "b") (PVar "q2"))) (EBinOp "&&" (EApp (EApp (EVar "matchEqAuth") (EVar "q1")) (EVar "q2")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TQual" (PVar "a") (PVar "q")) (PVar "b")) (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "q")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" ((PVar "subst") (PVar "a") (PCon "TQual" (PVar "b") (PVar "q"))) (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "q")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "matchEqAuth" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "matchEqAuth" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "authSub") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "authSub") (EVar "b")) (EVar "a"))))
(DTypeSig false "matchEqRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "matchEqRow" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "atomsA") (PVar "tailsA")) (EApp (EVar "rowFlat") (EVar "a"))) (DoLet false false (PTuple (PVar "atomsB") (PVar "tailsB")) (EApp (EVar "rowFlat") (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "atomsA")) (EApp (EVar "listLen") (EVar "atomsB"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "tailsA")) (EApp (EVar "listLen") (EVar "tailsB")))) (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "atomsB")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EVar "matchEqAuth") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (arm (PCon "None") () (EVar "False"))))) (EVar "atomsA"))) (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EApp (EApp (EVar "anyList") (ELam ((PVar "y")) (EBinOp "==" (EApp (EVar "effvarId") (EVar "x")) (EApp (EVar "effvarId") (EVar "y"))))) (EVar "tailsB")))) (EVar "tailsA"))))))
(DTypeSig true "cohPpPair" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cohPpPair" ((PVar "xs") (PVar "ys")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "s1") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "cohPpEach") (EVar "ctx")) (EVar "cnt")) (EVar "xs")))) (DoLet false false (PVar "s2") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "cohPpEach") (EVar "ctx")) (EVar "cnt")) (EVar "ys")))) (DoExpr (ETuple (EVar "s1") (EVar "s2")))))
(DTypeSig false "cohPpEach" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "cohPpEach" ((PVar "ctx") (PVar "cnt") (PVar "ms")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0)))) (EVar "ms")))
(DTypeSig true "tySubsumesV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tySubsumesV" ((PVar "generals") (PVar "specifics")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "generals")) (EApp (EVar "listLen") (EVar "specifics"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "tyStep")) (EVar "eqStr")) (EVar "tyStructEq")) (EApp (EApp (EVar "zipL") (EVar "generals")) (EVar "specifics"))) (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tyHeadEqV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyHeadEqV" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "tySubsumesV") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "tySubsumesV") (EVar "b")) (EVar "a"))))
(DTypeSig true "tyStrictlyMoreSpecificV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyStrictlyMoreSpecificV" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "tySubsumesV") (EVar "b")) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "tySubsumesV") (EVar "a")) (EVar "b")))))
(DTypeSig true "tyStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Ty")))))
(DFunDef false "tyStep" ((PCon "TyVar" (PVar "gn")) PWild) (EApp (EVar "MVar") (EVar "gn")))
(DFunDef false "tyStep" ((PRec "TyCon" ((rf "tyConName" (PVar "a")) (rf "tyConOrigin" (PVar "oa"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "b")) (rf "tyConOrigin" (PVar "ob"))) false)) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (EVar "MOk") (EVar "MFail")))
(DFunDef false "tyStep" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyApp" (PVar "f1") (PVar "a1")) (PCon "TyApp" (PVar "f2") (PVar "a2"))) (EApp (EVar "MKids") (EListLit (ETuple (EVar "f1") (EVar "f2")) (ETuple (EVar "a1") (EVar "a2")))))
(DFunDef false "tyStep" ((PCon "TyApp" PWild PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) (EApp (EVar "MKids") (EListLit (ETuple (EVar "a1") (EVar "a2")) (ETuple (EVar "b1") (EVar "b2")))))
(DFunDef false "tyStep" ((PCon "TyFun" PWild PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyTuple" (PVar "ts1")) (PCon "TyTuple" (PVar "ts2"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "ts1")) (EApp (EVar "listLen") (EVar "ts2"))) (EApp (EVar "MKids") (EApp (EApp (EVar "zipL") (EVar "ts1")) (EVar "ts2"))) (EVar "MFail")))
(DFunDef false "tyStep" ((PCon "TyTuple" PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyEffect" PWild PWild (PVar "t1")) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyConstrained" PWild (PVar "t1")) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyRow" PWild PWild PWild) PWild) (EVar "MOk"))
(DFunDef false "tyStep" ((PCon "TyAuth" PWild PWild) PWild) (EVar "MOk"))
(DFunDef false "tyStep" ((PCon "TyNamed" PWild (PVar "t1") PWild) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyQual" (PVar "t1") PWild PWild) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DTypeSig true "stripTyWrap" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTyWrap" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PVar "t")) (EVar "t"))
(DTypeSig true "tyStructEq" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyStructEq" ((PRec "TyCon" ((rf "tyConName" (PVar "a")) (rf "tyConOrigin" (PVar "oa"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "b")) (rf "tyConOrigin" (PVar "ob"))) false)) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "tyStructEq" ((PCon "TyVar" (PVar "a")) (PCon "TyVar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "tyStructEq" ((PCon "TyApp" (PVar "f1") (PVar "a1")) (PCon "TyApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "f1")) (EVar "f2")) (EApp (EApp (EVar "tyStructEq") (EVar "a1")) (EVar "a2"))))
(DFunDef false "tyStructEq" ((PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "tyStructEq") (EVar "b1")) (EVar "b2"))))
(DFunDef false "tyStructEq" ((PCon "TyTuple" (PVar "ts1")) (PCon "TyTuple" (PVar "ts2"))) (EApp (EApp (EVar "tyStructEqList") (EVar "ts1")) (EVar "ts2")))
(DFunDef false "tyStructEq" ((PCon "TyEffect" PWild PWild (PVar "t1")) (PCon "TyEffect" PWild PWild (PVar "t2"))) (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")))
(DFunDef false "tyStructEq" ((PCon "TyConstrained" PWild (PVar "t1")) (PCon "TyConstrained" PWild (PVar "t2"))) (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")))
(DFunDef false "tyStructEq" (PWild PWild) (EVar "False"))
(DTypeSig false "tyStructEqList" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyStructEqList" ((PList) (PList)) (EVar "True"))
(DFunDef false "tyStructEqList" ((PCons (PVar "t1") (PVar "ts1")) (PCons (PVar "t2") (PVar "ts2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "tyStructEqList") (EVar "ts1")) (EVar "ts2"))))
(DFunDef false "tyStructEqList" (PWild PWild) (EVar "False"))
(DTypeSig false "headTyNode" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "headTyNode" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTyNode") (EVar "a")))
(DFunDef false "headTyNode" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTyNode") (EVar "t")))
(DFunDef false "headTyNode" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTyNode") (EVar "t")))
(DFunDef false "headTyNode" ((PVar "t")) (EVar "t"))
(DTypeSig true "headTySpineNode" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "headTySpineNode" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTySpineNode") (EVar "a")))
(DFunDef false "headTySpineNode" ((PVar "t")) (EVar "t"))
(DTypeSig true "headTyconTy" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "headTyconTy" ((PVar "t")) (EMatch (EApp (EVar "headTyNode") (EVar "t")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "o")) (EVar "n")))) (arm (PCon "TyTuple" (PVar "ts")) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "ts")))))) (arm (PCon "TyFun" PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EVar "funHeadTag")))) (arm PWild () (EVar "None"))))
(DTypeSig true "mergeSubstPreferConcrete" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "mergeSubstPreferConcrete" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "mergeSubstPreferConcrete" ((PVar "acc") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EApp (EApp (EVar "mergeSubstPreferConcrete") (EApp (EApp (EApp (EVar "mergeOne") (EVar "acc")) (EVar "k")) (EVar "v"))) (EVar "rest")))
(DTypeSig true "mergeOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "mergeOne" ((PList) (PVar "k") (PVar "v")) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "mergeOne" ((PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest")) (PVar "k") (PVar "v")) (EIf (EBinOp "==" (EVar "k2") (EVar "k")) (EBinOp "::" (ETuple (EVar "k2") (EApp (EApp (EVar "preferConcrete") (EVar "v2")) (EVar "v"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EApp (EApp (EApp (EVar "mergeOne") (EVar "rest")) (EVar "k")) (EVar "v"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preferConcrete" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "preferConcrete" ((PVar "a") (PVar "b")) (EMatch (EApp (EVar "headTyconMono") (EVar "a")) (arm (PCon "Some" PWild) () (EVar "a")) (arm (PCon "None") () (EVar "b"))))
(DTypeSig true "matchTyMono" (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "matchTyMono" ((PVar "headTy") (PVar "resultMono")) (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EListLit (ETuple (EVar "headTy") (EVar "resultMono")))) (EListLit)))))
(DTypeSig false "matchTyMonos" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "matchTyMonos" ((PVar "pats") (PVar "goals")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "goals"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EApp (EApp (EVar "zipL") (EVar "pats")) (EVar "goals"))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "entryHeadMatches" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "entryHeadMatches" ((PVar "hty") (PVar "itys") (PVar "goals")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "itys")) (EApp (EVar "listLen") (EVar "goals"))) (EApp (EVar "isSome") (EApp (EApp (EVar "matchTyMonos") (EVar "itys")) (EVar "goals"))) (EIf (EVar "otherwise") (EMatch (EVar "goals") (arm (PCons (PVar "g") PWild) () (EApp (EVar "isSome") (EApp (EApp (EVar "matchTyMono") (EVar "hty")) (EVar "g")))) (arm (PList) () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "matchStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Mono")))))
(DFunDef false "matchStep" ((PCon "TyVar" (PVar "n")) PWild) (EApp (EVar "MVar") (EVar "n")))
(DFunDef false "matchStep" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TCon" (PVar "n2") (PVar "o2")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (EVar "n2")) (EVar "o2")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TRigid" (PVar "n2")) () (EIf (EBinOp "==" (EVar "n") (EVar "n2")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "ma") (PVar "mb")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a") (EVar "ma")) (ETuple (EVar "b") (EVar "mb"))))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyTuple" (PVar "ts")) (PVar "m")) (EMatch (EApp (EVar "tupleSpine") (EVar "m")) (arm (PCon "Some" (PVar "ms")) () (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "ts")) (EApp (EVar "listLen") (EVar "ms"))) (EApp (EVar "MKids") (EApp (EApp (EVar "zipL") (EVar "ts")) (EVar "ms"))) (EVar "MFail"))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TFun" (PVar "ma") PWild (PVar "mb")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a") (EVar "ma")) (ETuple (EApp (EVar "stripEff") (EVar "b")) (EVar "mb"))))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "m")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t") (EVar "m")))))
(DFunDef false "matchStep" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "m")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t") (EVar "m")))))
(DFunDef false "matchStep" ((PCon "TyRow" PWild PWild PWild) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TEff" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" (PWild PWild) (EVar "MFail"))
(DTypeSig true "findTvarInMono" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarInMono" ((PVar "t") (PVar "id")) (EApp (EApp (EVar "findTvarN") (EApp (EVar "normalize") (EVar "t"))) (EVar "id")))
(DTypeSig false "findTvarN" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarN" ((PCon "TVar" (PVar "cell")) (PVar "id")) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id")) (EApp (EVar "Some") (EApp (EVar "TVar") (EVar "cell"))) (EVar "None")))
(DFunDef false "findTvarN" ((PCon "TCon" PWild PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TRigid" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TApp" (PVar "a") (PVar "b")) (PVar "id")) (EApp (EApp (EApp (EVar "firstTvar") (EVar "a")) (EVar "b")) (EVar "id")))
(DFunDef false "findTvarN" ((PCon "TFun" (PVar "a") PWild (PVar "b")) (PVar "id")) (EApp (EApp (EApp (EVar "firstTvar") (EVar "a")) (EVar "b")) (EVar "id")))
(DFunDef false "findTvarN" ((PCon "TEff" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TAuth" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TQual" (PVar "a") PWild) (PVar "id")) (EApp (EApp (EVar "findTvarInMono") (EVar "a")) (EVar "id")))
(DTypeSig false "firstTvar" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "firstTvar" ((PVar "a") (PVar "b") (PVar "id")) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "a")) (EVar "id")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Some") (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "findTvarInMono") (EVar "b")) (EVar "id")))))
(DTypeSig true "headMonoNode" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "headMonoNode" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "headMonoNode") (EVar "a"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "headMonoNode") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "peelQual" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "peelQual" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "peelQual") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "headTyconMono" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "headTyconMono" ((PVar "t")) (EMatch (EApp (EVar "headMonoNode") (EVar "t")) (arm (PCon "TCon" (PVar "n") (PVar "o")) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "o")) (EVar "n")))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EApp (EVar "HkRigid") (EVar "n")))) (arm (PCon "TFun" PWild PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EVar "funHeadTag")))) (arm PWild () (EVar "None"))))
(DTypeSig true "headTyconNameMono" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconNameMono" ((PVar "t")) (EMatch (EApp (EVar "headMonoNode") (EVar "t")) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig true "tupleMono" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono")))
(DFunDef false "tupleMono" ((PVar "ts")) (EApp (EApp (EVar "tupleSpineOf") (EApp (EVar "tconTupleHead") (EApp (EVar "listLen") (EVar "ts")))) (EVar "ts")))
(DTypeSig true "tupleSpineOf" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "tupleSpineOf" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "tupleSpineOf" ((PVar "acc") (PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "tupleSpineOf") (EApp (EApp (EVar "TApp") (EVar "acc")) (EVar "t"))) (EVar "rest")))
(DTypeSig true "findTvarInMonos" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarInMonos" ((PList) PWild) (EVar "None"))
(DFunDef false "findTvarInMonos" ((PCons (PVar "m") (PVar "rest")) (PVar "i")) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "m")) (EVar "i")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "findTvarInMonos") (EVar "rest")) (EVar "i")))))
(DTypeSig true "cohApply" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "cohApply" ((PVar "subst") (PVar "m")) (EMatch (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EVar "eff")) (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EVar "q"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "sigStandIn" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "String")))
(DFunDef false "sigStandIn" ((PVar "cell")) (EBinOp "++" (EBinOp "++" (ELit (LString "%sig")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "cell"))))) (ELit (LString ""))))
(DTypeSig true "sigCellsOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))))))
(DFunDef false "sigCellsOf" ((PVar "sigIds") (PVar "cells")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "c")))) (EVar "sigIds")))) (EVar "cells")))
(DTypeSig true "sigRigidBindings" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))
(DFunDef false "sigRigidBindings" ((PVar "sigIds") (PVar "cells")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EApp (EVar "TRigid") (EApp (EVar "sigStandIn") (EVar "c")))))) (EApp (EApp (EVar "sigCellsOf") (EVar "sigIds")) (EVar "cells"))))
(DTypeSig true "rigidSigPairs" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "rigidSigPairs" ((PVar "gctx") (PVar "sigIds") (PVar "pairs")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EBinOp "++" (EApp (EVar "monoVarCells") (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "monoVarCells") (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs"))) (DoExpr (EMatch (EApp (EApp (EVar "sigRigidBindings") (EVar "sigIds")) (EVar "cells")) (arm (PList) () (EVar "pairs")) (arm (PVar "toRigid") () (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "toRigid")) (EListLit)) (EListLit)) (EApp (EVar "fst") (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "toRigid")) (EListLit)) (EListLit)) (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs")))))))
(DTypeSig true "monoVarCells" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar")))))
(DFunDef false "monoVarCells" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EVar "cell"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoVarCells") (EVar "a")) (EApp (EVar "monoVarCells") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoVarCells") (EVar "a")) (EApp (EVar "monoVarCells") (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoVarCells") (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "spineHeadMono" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "spineHeadMono" ((PVar "t")) (EMatch (EApp (EVar "peelQual") (EVar "t")) (arm (PCon "TApp" (PVar "f") PWild) () (EApp (EVar "spineHeadMono") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "locEq" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "locEq" ((PCon "Loc" (PVar "f1") (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PCon "Loc" (PVar "f2") (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f1") (EVar "f2")) (EBinOp "==" (EVar "a1") (EVar "a2"))) (EBinOp "==" (EVar "b1") (EVar "b2"))) (EBinOp "==" (EVar "c1") (EVar "c2"))) (EBinOp "==" (EVar "d1") (EVar "d2"))))
(DTypeSig true "stripTyConstraints" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTyConstraints" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripTyConstraints") (EVar "t")))
(DFunDef false "stripTyConstraints" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripTyConstraints") (EVar "t")))
(DFunDef false "stripTyConstraints" ((PVar "t")) (EVar "t"))
(DTypeSig true "allConcreteHeads" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "allConcreteHeads" ((PList)) (EVar "True"))
(DFunDef false "allConcreteHeads" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "m"))) (EApp (EVar "allConcreteHeads") (EVar "rest"))))
(DTypeSig true "monoIndexEffvarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoIndexEffvarIds" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoIndexEffvarIds") (EVar "a")) (EApp (EVar "monoIndexEffvarIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EApp (EVar "monoIndexEffvarIds") (EVar "a")) (EApp (EVar "rowTailId") (EVar "r"))) (EApp (EVar "monoIndexEffvarIds") (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EVar "rowTailId") (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoIndexEffvarIds") (EVar "a"))) (arm (PCon "TAuth" PWild) () (EListLit)) (arm PWild () (EListLit))))
(DTypeSig true "rowTailId" (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "rowTailId" ((PVar "row")) (EApp (EApp (EVar "map") (EVar "effvarId")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "monoSameGiven" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoSameGiven" ((PVar "a") (PVar "b")) (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TVar" (PVar "c1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TVar" (PVar "c2")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2")))) (arm PWild () (EVar "False")))) (arm (PCon "TCon" (PVar "x") (PVar "ox")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TCon" (PVar "y") (PVar "oy")) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "x")) (EVar "ox")) (EVar "y")) (EVar "oy"))) (arm (PCon "TRigid" (PVar "y")) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False")))) (arm (PCon "TRigid" (PVar "x")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TRigid" (PVar "y")) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm (PCon "TCon" (PVar "y") PWild) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False")))) (arm (PCon "TApp" (PVar "a1") (PVar "b1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TApp" (PVar "a2") (PVar "b2")) () (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "monoSameGiven") (EVar "b1")) (EVar "b2")))) (arm PWild () (EVar "False")))) (arm (PCon "TFun" (PVar "a1") PWild (PVar "b1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TFun" (PVar "a2") PWild (PVar "b2")) () (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "monoSameGiven") (EVar "b1")) (EVar "b2")))) (arm PWild () (EVar "False")))) (arm (PCon "TAuth" PWild) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TAuth" PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "TEff" PWild) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TEff" PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "monoVecSameGiven" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "monoVecSameGiven" ((PList) (PList)) (EVar "True"))
(DFunDef false "monoVecSameGiven" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "arest")) (EVar "brest"))))
(DFunDef false "monoVecSameGiven" (PWild PWild) (EVar "False"))
(DTypeSig true "monoTyvarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoTyvarIds" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoTyvarIds") (EVar "a")) (EApp (EVar "monoTyvarIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoTyvarIds") (EVar "a")) (EApp (EVar "monoTyvarIds") (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoTyvarIds") (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "peelArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "peelArrows" ((PVar "n") (PVar "t")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "::" (EVar "a") (EApp (EApp (EVar "peelArrows") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b")))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isBareTyvarMono" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isBareTyvarMono" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "monoVectorClosed" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "monoVectorClosed" ((PVar "args")) (EApp (EApp (EVar "allList") (EVar "monoClosed")) (EVar "args")))
(DTypeSig true "monoClosed" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoClosed" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EVar "False")) (arm (PCon "TRigid" PWild) () (EVar "False")) (arm (PCon "TCon" PWild PWild) () (EVar "True")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "&&" (EApp (EVar "monoClosed") (EVar "a")) (EApp (EVar "monoClosed") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "&&" (EApp (EVar "monoClosed") (EVar "a")) (EApp (EVar "monoClosed") (EVar "b")))) (arm (PCon "TEff" PWild) () (EVar "True")) (arm (PCon "TAuth" PWild) () (EVar "True")) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoClosed") (EVar "a")))))
(DTypeSig true "schemeBodyOf" (TyFun (TyCon "Scheme") (TyCon "Mono")))
(DFunDef false "schemeBodyOf" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (EVar "body"))
(DTypeSig true "monoHeadIsDecl" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHeadIsDecl" ((PVar "m")) (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PCon "HkRigid" PWild)) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "anyConcreteHead" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "anyConcreteHead" ((PVar "args")) (EApp (EApp (EVar "anyListM") (ELam ((PVar "m")) (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "m"))))) (EVar "args")))
(DTypeSig true "schemeIds" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "schemeIds" ((PCon "Forall" (PVar "ids") PWild PWild PWild PWild PWild)) (EVar "ids"))
(DTypeSig true "findTvName" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "findTvName" (PWild (PList)) (EVar "None"))
(DFunDef false "findTvName" ((PVar "id") (PCons (PTuple (PVar "n") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id")) (EApp (EVar "Some") (EVar "n")) (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "rest")))))
(DTypeSig false "monoSpineHeadIsCon" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoSpineHeadIsCon" ((PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "monoSpineHeadIsCon") (EVar "a"))) (arm (PCon "TCon" PWild PWild) () (EVar "True")) (arm (PCon "TRigid" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "unrigidSig" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "unrigidSig" ((PVar "sigCells") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TRigid" (PVar "n")) () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "sigStandIn") (EVar "c")) (EVar "n")))) (EVar "sigCells")) (arm (PCons (PVar "c") PWild) () (EApp (EVar "TVar") (EVar "c"))) (arm (PList) () (EApp (EVar "TRigid") (EVar "n"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EVar "eff")) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EVar "q"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "abstractSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "abstractSlotIds" ((PList)) (EListLit))
(DFunDef false "abstractSlotIds" ((PCons (PVar "mono") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "abstractSlotIds") (EVar "rest")))) (arm PWild () (EApp (EVar "abstractSlotIds") (EVar "rest")))))
(DTypeSig true "declaredOblArgOk" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "declaredOblArgOk" ((PVar "isBound") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "isBound") (EApp (EVar "tyvarId") (EVar "cell")))) (arm PWild () (EApp (EApp (EVar "allList") (EVar "isBound")) (EApp (EVar "monoTyvarIds") (EVar "m"))))))
(DTypeSig true "oblArgKey" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "oblArgKey" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "++" (EBinOp "++" (ELit (LString "v")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "cell"))))) (ELit (LString ".")))) (arm (PCon "TCon" (PVar "name") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString "")))) (arm (PCon "TRigid" (PVar "name")) () (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString "")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EVar "display") (EApp (EVar "oblArgKey") (EVar "a")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "oblArgKey") (EVar "b")))) (ELit (LString "")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f")) (EApp (EVar "display") (EApp (EVar "oblArgKey") (EVar "a")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "oblArgKey") (EVar "b")))) (ELit (LString "")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "oblArgKey") (EVar "a"))) (arm PWild () (ELit (LString "*")))))
(DTypeSig true "exactReturnRequestOfGoal" (TyFun (TyCon "Obligation") (TyApp (TyCon "Option") (TyCon "MethodReturnRequest"))))
(DFunDef false "exactReturnRequestOfGoal" ((PVar "goal")) (EMatch (EFieldAccess (EVar "goal") "oPayload") (arm (PCon "GPSite" PWild PWild (PCon "SKExactReturn" PWild (PVar "request"))) () (EApp (EVar "Some") (EVar "request"))) (arm PWild () (EVar "None"))))
(DTypeSig true "firstOrZero" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "firstOrZero" ((PList)) (ELit (LInt 0)))
(DFunDef false "firstOrZero" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "allMethodParamsMentioned" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "allMethodParamsMentioned" ((PList) PWild) (EVar "True"))
(DFunDef false "allMethodParamsMentioned" ((PCons (PVar "param") (PVar "rest")) (PVar "ty")) (EBinOp "&&" (EApp (EApp (EVar "argMentions") (EListLit (EVar "param"))) (EApp (EVar "stripTyConstraints") (EVar "ty"))) (EApp (EApp (EVar "allMethodParamsMentioned") (EVar "rest")) (EVar "ty"))))
(DTypeSig true "implDeclsWithReqs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "implDeclsWithReqs" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "implDeclWithReqs")) (EVar "prog")))
(DTypeSig false "implDeclWithReqs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "implDeclWithReqs" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclWithReqs") (EVar "d")))
(DFunDef false "implDeclWithReqs" ((PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" None)) true)) (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin")))) (EVar "tys") (EVar "reqs"))))
(DFunDef false "implDeclWithReqs" (PWild) (EListLit))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "Ident" true) (mem "Lit" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true) (mem "Require" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "identOriginFold" false) (mem "propParamName" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "normalizeLink" false) (mem "ppGo" false) (mem "tupleHeadTagTc" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authIsTop" false) (mem "authJoinAll" false) (mem "authNorm" false) (mem "authSub" false) (mem "authvarId" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomsNorm" false) (mem "effrowNorm" false) (mem "effvarId" false) (mem "findAtom" false) (mem "pureRow" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "HeadVarRoot" true) (mem "MethodReturnRequest" true) (mem "MStep" true) (mem "Obligation" true) (mem "Predicate" true) (mem "RecordInfo" true) (mem "SiteKind" true) (mem "Windowed" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "eqStr" false) (mem "filterList" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "minI" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyIdent" false) (mem "headKeyOfCon" false) (mem "headKeyTag" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "funHeadTag" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "authorityParamSubst" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true) (mem "Wanted" true))))
(DUse false (UseGroup ("list") ((mem "take" false))))
(DTypeSig true "effectCells" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "effectCells" ((PVar "mono") (PVar "cells")) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "effectCells") (EVar "b")) (EApp (EApp (EVar "effectCells") (EVar "a")) (EApp (EApp (EVar "effectRowCells") (EVar "row")) (EVar "cells"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "effectCells") (EVar "b")) (EApp (EApp (EVar "effectCells") (EVar "a")) (EVar "cells")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "effectRowCells") (EVar "row")) (EVar "cells"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "effectCells") (EVar "a")) (EVar "cells"))) (arm (PCon "TAuth" PWild) () (EVar "cells")) (arm PWild () (EVar "cells"))))
(DTypeSig false "effectRowCells" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "effectRowCells" ((PVar "row") (PVar "cells")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "cell")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "cells")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "cellIdSet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "cellIdSet" ((PVar "cells")) (EApp (EApp (EVar "cellIdSetGo") (EVar "cells")) (EVar "Tip")))
(DTypeSig false "cellIdSetGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "cellIdSetGo" ((PList) (PVar "ids")) (EVar "ids"))
(DFunDef false "cellIdSetGo" ((PCons (PVar "cell") (PVar "cells")) (PVar "ids")) (EApp (EApp (EVar "cellIdSetGo") (EVar "cells")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "effvarId") (EVar "cell"))) (ELit LUnit)) (EVar "ids"))))
(DTypeSig true "nthArgMono" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthArgMono" ((PLit (LInt 0)) (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "a") PWild PWild) () (EApp (EVar "Some") (EVar "a"))) (arm PWild () (EVar "None"))))
(DFunDef false "nthArgMono" ((PVar "n") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EApp (EApp (EVar "nthArgMono") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b"))) (arm PWild () (EVar "None"))))
(DTypeSig true "containsI" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "containsI" (PWild (PList)) (EVar "False"))
(DFunDef false "containsI" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "containsI") (EVar "x")) (EVar "ys"))))
(DTypeSig true "invocationHeadKey" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "invocationHeadKey" ((PVar "h")) (EMatch (EApp (EVar "headTyconMono") (EVar "h")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (ELit (LString "?")))))
(DTypeSig true "instantiateFields" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "instantiateFields" ((PVar "gctx") (PVar "args") (PTuple (PVar "params") (PVar "fieldTys"))) (EBlock (DoLet false false (PVar "asub") (EApp (EApp (EVar "authorityParamSubst") (EVar "params")) (EVar "args"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EListLit)) (EListLit)) (EVar "asub"))) (EVar "fieldTys")))))
(DTypeSig true "isPreludeOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))
(DFunDef false "isPreludeOrigin" ((PCon "OriginModule" (PVar "m"))) (EBinOp "==" (EVar "m") (ELit (LString "core"))))
(DFunDef false "isPreludeOrigin" (PWild) (EVar "False"))
(DTypeSig true "headIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "headIdConflict" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "tconIdConflict") (EApp (EVar "spineHead") (EVar "a"))) (EApp (EVar "spineHead") (EVar "b"))))
(DTypeSig true "spineHead" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "spineHead" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "firstIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "firstIdConflict" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))) (arm (PTuple (PCon "TApp" (PVar "f1") (PVar "x1")) (PCon "TApp" (PVar "f2") (PVar "x2"))) () (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "firstIdConflict") (EVar "f1")) (EVar "f2"))) (EApp (EApp (EVar "firstIdConflict") (EVar "x1")) (EVar "x2")))) (arm (PTuple (PCon "TFun" (PVar "d1") PWild (PVar "r1")) (PCon "TFun" (PVar "d2") PWild (PVar "r2"))) () (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "firstIdConflict") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EVar "firstIdConflict") (EVar "r1")) (EVar "r2")))) (arm (PTuple (PVar "x") (PVar "y")) () (EApp (EApp (EVar "tconIdConflict") (EVar "x")) (EVar "y")))))
(DTypeSig false "tconIdConflict" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "tconIdConflict" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))) (arm (PTuple (PCon "TCon" (PVar "n1") (PVar "o1")) (PCon "TCon" (PVar "n2") (PVar "o2"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n1")) (EVar "o1")) (EVar "n2")) (EVar "o2")))) (EApp (EVar "Some") (ETuple (EVar "n1") (EVar "o1") (EVar "o2"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig true "qualifierAuthIds" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "qualifierAuthIds" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "b")) (EApp (EApp (EVar "qualifierAuthIds") (EVar "a")) (EVar "acc")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EVar "qualifierAuthIds") (EVar "inner")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authIdsIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authIdsIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authIdsIn") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EApp (EApp (EVar "rowAuthIds") (EVar "row")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authIdsIn") (EVar "b")) (EApp (EApp (EVar "authIdsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "rowAuthIds") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authIdsIn") (EVar "inner")) (EApp (EApp (EVar "authTermIds") (EVar "q")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authTermIds") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig false "rowAuthIds" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "rowAuthIds" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "atom")) (EApp (EApp (EVar "authTermIds") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "m")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authTermIds" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authTermIds" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "authvarIdOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Int")))
(DFunDef false "authvarIdOf" ((PTuple PWild (PVar "cell"))) (EApp (EVar "authvarId") (EVar "cell")))
(DTypeSig true "effvarIdOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Int")))
(DFunDef false "effvarIdOf" ((PTuple PWild (PVar "cell"))) (EApp (EVar "effvarId") (EVar "cell")))
(DTypeSig true "litType" (TyFun (TyCon "Lit") (TyCon "Mono")))
(DFunDef false "litType" ((PCon "LInt" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DFunDef false "litType" ((PCon "LFloat" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Float"))))
(DFunDef false "litType" ((PCon "LString" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "String"))))
(DFunDef false "litType" ((PCon "LChar" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Char"))))
(DFunDef false "litType" ((PCon "LBool" PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DFunDef false "litType" ((PCon "LUnit")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))
(DFunDef false "litType" ((PCon "LU64" PWild PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "U64"))))
(DFunDef false "litType" ((PCon "LI64" PWild PWild)) (EApp (EVar "tconBuiltin") (ELit (LString "I64"))))
(DTypeSig true "foldrFun" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "foldrFun" ((PList) (PVar "result")) (EVar "result"))
(DFunDef false "foldrFun" ((PCons (PVar "a") (PVar "rest")) (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "a")) (EVar "pureRow")) (EApp (EApp (EVar "foldrFun") (EVar "rest")) (EVar "result"))))
(DTypeSig true "authOrderIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authOrderIn") (EVar "b")) (EApp (EApp (EVar "authOrderRow") (EVar "row")) (EApp (EApp (EVar "authOrderIn") (EVar "a")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authOrderIn") (EVar "b")) (EApp (EApp (EVar "authOrderIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "authOrderRow") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authOrderTerm") (EVar "q")) (EApp (EApp (EVar "authOrderIn") (EVar "inner")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authOrderTerm") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authOrderRow" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderRow" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "atom")) (EApp (EApp (EVar "authOrderTerm") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "a")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authOrderTerm" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "authOrderTerm" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "cell")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "authvarId") (EVar "cell"))) (DoExpr (EIf (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "a")) (EVar "a") (EBinOp "::" (EVar "i") (EVar "a"))))))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "xmodOblArgId" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "xmodOblArgId" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm PWild () (EApp (EVar "monoTyvarIds") (EVar "m")))))
(DTypeSig true "substOblArgs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "substOblArgs" (PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "substOblArgs" ((PVar "ids") (PCons (PVar "m") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "m")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "m2") (EVar "_s")))) (EApp (EApp (EApp (EVar "substOblArgs") (EVar "ids")) (EVar "rest")) (EVar "subst"))))))
(DTypeSig false "substOblArg" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "substOblArg" ((PVar "ids") (PVar "m") (PVar "subst")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "subst")) (arm (PCon "Some" (PVar "m2")) () (EApp (EVar "Some") (EVar "m2"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "ids")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "TVar") (EVar "cell"))))))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "a2")) (EApp (EApp (EVar "TQual") (EVar "a2")) (EVar "q")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "a2")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "b2")) (EApp (EApp (EVar "TApp") (EVar "a2")) (EVar "b2")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "b")) (EVar "subst")))))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "a")) (EVar "subst")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "a2")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "b2")) (EApp (EApp (EApp (EVar "TFun") (EVar "a2")) (EVar "eff")) (EVar "b2")))) (EApp (EApp (EApp (EVar "substOblArg") (EVar "ids")) (EVar "b")) (EVar "subst")))))) (arm (PVar "other") () (EApp (EVar "Some") (EVar "other")))))
(DTypeSig true "substMonos" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "substMonos" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "substMonos" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" (PVar "mono")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "mono") (EVar "_s")))) (EApp (EApp (EVar "substMonos") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "nthFunDomain" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthFunDomain" ((PVar "k") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "a") PWild (PVar "r")) () (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "a")) (EApp (EApp (EVar "nthFunDomain") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "r")))) (arm PWild () (EVar "None"))))
(DTypeSig true "expectedParamTypes" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "expectedParamTypes" (PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "expectedParamTypes" ((PCon "TFun" (PVar "a") PWild (PVar "b")) (PVar "n")) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "expectedParamTypes") (EApp (EVar "normalize") (EVar "b"))) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DFunDef false "expectedParamTypes" (PWild PWild) (EListLit))
(DTypeSig true "containerParamScalarArg" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "containerParamScalarArg" ((PVar "ft") (PVar "xt")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") PWild PWild) () (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TApp" PWild PWild) () (EMatch (EApp (EVar "headTyconNameMono") (EVar "dom")) (arm (PCon "None") () (EMatch (EApp (EVar "normalize") (EVar "xt")) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None")))) (arm (PCon "Some" PWild) () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "funArity" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "funArity" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild PWild (PVar "r")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "funArity") (EVar "r")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "domainIsTupleOfArity" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "domainIsTupleOfArity" ((PVar "ft") (PVar "n")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") PWild PWild) () (EMatch (EApp (EVar "headTyconNameMono") (EVar "dom")) (arm (PCon "Some" (PVar "c")) () (EBinOp "==" (EVar "c") (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "__"))))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "isUnshaped" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isUnshaped" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "recordAuthCells" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "recordAuthCells" ((PList) PWild PWild) (EVar "Tip"))
(DFunDef false "recordAuthCells" (PWild (PVar "result") (PVar "fields")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "f")) (EApp (EApp (EVar "authCellsIn") (EApp (EVar "snd") (EVar "f"))) (EVar "m")))) (EApp (EApp (EVar "authCellsIn") (EVar "result")) (EVar "Tip"))) (EVar "fields")))
(DTypeSig true "applyParams" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "applyParams" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyParams" ((PVar "head") (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "TApp") (EVar "head")) (EVar "p"))) (EVar "ps")))
(DTypeSig true "tupleUnifyClash" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "tupleUnifyClash" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "tupleSpine") (EVar "a")) (EApp (EVar "tupleSpine") (EVar "b"))) (arm (PTuple (PCon "Some" (PVar "xs")) (PCon "Some" (PVar "ys"))) () (EBinOp "/=" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys")))) (arm (PTuple (PCon "Some" PWild) (PCon "None")) () (EApp (EVar "monoSpineHeadIsCon") (EVar "b"))) (arm (PTuple (PCon "None") (PCon "Some" PWild)) () (EApp (EVar "monoSpineHeadIsCon") (EVar "a"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "False"))))
(DTypeSig true "instantiateNamedMonos" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "instantiateNamedMonos" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "instantiateNamedMonos" ((PVar "gctx") (PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest")) (PVar "subst")) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit)) (EVar "mono"))) (EApp (EApp (EApp (EVar "instantiateNamedMonos") (EVar "gctx")) (EVar "rest")) (EVar "subst"))))
(DTypeSig true "headsUnifier" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "headsUnifier" ((PVar "gctx") (PVar "rigidIds") (PVar "args") (PVar "allHeads")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "take") (EApp (EVar "listLen") (EVar "args"))) (EVar "allHeads"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "heads")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EApp (EApp (EApp (EVar "rigidSigPairs") (EVar "gctx")) (EVar "rigidIds")) (EApp (EApp (EVar "zipL") (EVar "args")) (EVar "heads"))))) (EApp (EVar "Some") (EVar "scratch")) (EVar "None")))))
(DTypeSig true "allArrowEffs" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "EffRow"))))
(DFunDef false "allArrowEffs" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "eff") (PVar "b")) () (EBinOp "::" (EVar "eff") (EApp (EVar "allArrowEffs") (EVar "b")))) (arm PWild () (EListLit))))
(DTypeSig true "headVarRootOf" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "HeadVarRoot"))))
(DFunDef false "headVarRootOf" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "Some") (EApp (EVar "TypeVarRoot") (EApp (EVar "tyvarId") (EVar "cell"))))) (arm (PCon "TEff" (PVar "row")) () (EMatch (EApp (EVar "effrowNorm") (EVar "row")) (arm (PCon "EffRow" (PList) (PCon "Some" (PVar "cell"))) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EVar "Some") (EApp (EVar "RowVarRoot") (EVar "id")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "isUnboundTvar" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isUnboundTvar" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "isMonoScheme" (TyFun (TyCon "Scheme") (TyCon "Bool")))
(DFunDef false "isMonoScheme" ((PCon "Forall" (PList) (PList) (PList) PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMonoScheme" (PWild) (EVar "False"))
(DTypeSig true "unquantifiedAuthIds" (TyFun (TyCon "Scheme") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "unquantifiedAuthIds" ((PCon "Forall" PWild PWild (PVar "auths") (PVar "residual") (PVar "force") (PVar "mono"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "id")) (EApp (EApp (EVar "IdMap.delete") (EVar "id")) (EVar "acc")))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "r")) (EApp (EApp (EVar "authTermIds") (EFieldAccess (EVar "r") "arUpper")) (EApp (EApp (EVar "authTermIds") (EFieldAccess (EVar "r") "arLower")) (EVar "acc"))))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EApp (EApp (EVar "rowAuthIds") (EVar "force")) (EVar "Tip")))) (EVar "residual"))) (EVar "auths")))
(DTypeSig true "sigTvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "sigTvarIds" ((PList)) (EListLit))
(DFunDef false "sigTvarIds" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "sigTvarIds") (EVar "rest")))) (arm PWild () (EApp (EVar "sigTvarIds") (EVar "rest")))))
(DTypeSig true "declaredOblArgId" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "declaredOblArgId" ((PVar "boundIds") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) ((GBool (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")))) (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TVar" PWild) () (EListLit)) (arm PWild () (EApp (EApp (EVar "filterList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "boundIds")))) (EApp (EVar "monoTyvarIds") (EVar "m"))))))
(DTypeSig true "boundTyvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "boundTyvarIds" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "boundTyvarIds" ((PVar "boundIds") (PCons (PVar "d") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "d")) (arm (PCon "TVar" (PVar "cell")) ((GBool (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "_s")))) (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "rest")))) (arm PWild () (EVar "None"))))
(DTypeSig true "monosTvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "monosTvarIds" ((PVar "boundIds") (PVar "monos")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "boundTvarId") (EVar "boundIds"))) (EVar "monos")))
(DTypeSig true "boundTvarId" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "boundTvarId" ((PVar "boundIds") (PVar "mono")) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "boundIds")) (EListLit (EApp (EVar "tyvarId") (EVar "cell"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig true "tconBuiltin" (TyFun (TyCon "String") (TyCon "Mono")))
(DFunDef false "tconBuiltin" ((PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "OriginBuiltin")))
(DTypeSig true "tconTupleHead" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "tconTupleHead" ((PVar "n")) (EApp (EApp (EVar "TCon") (EApp (EVar "tupleHeadTagTc") (EVar "n"))) (EVar "OriginBuiltin")))
(DTypeSig true "tconFrom" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "tconFrom" ((PVar "o") (PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "o")))
(DTypeSig true "tconUnresolved" (TyFun (TyCon "String") (TyCon "Mono")))
(DFunDef false "tconUnresolved" ((PVar "n")) (EApp (EApp (EVar "TCon") (EVar "n")) (EVar "OriginUnresolved")))
(DTypeSig true "newEffvarId" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "newEffvarId" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EVar "n"))))
(DTypeSig true "effvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "effvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild (PVar "l")) () (EVar "l")) (arm (PCon "ELink" PWild PWild) () (ELit (LInt 0))) (arm (PCon "EJoin" PWild (PVar "l") PWild) () (EVar "l")) (arm (PCon "ESummary" PWild (PVar "l") PWild) () (EVar "l"))))
(DTypeSig true "rowOfMembers" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "EffRow")))))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PList)) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None")))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PList (PVar "m"))) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EVar "m"))))
(DFunDef false "rowOfMembers" ((PVar "gctx") (PVar "labels") (PVar "ms")) (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EApp (EApp (EVar "joinCellOf") (EVar "gctx")) (EVar "ms")))))
(DTypeSig true "joinCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "joinCellOf" ((PVar "gctx") (PVar "ms")) (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "EJoin") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EApp (EVar "minLevelOf") (EVar "ms"))) (EVar "ms"))))
(DTypeSig true "minLevelOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Int")))
(DFunDef false "minLevelOf" ((PList)) (ELit (LInt 0)))
(DFunDef false "minLevelOf" ((PList (PVar "m"))) (EApp (EVar "effvarLevel") (EVar "m")))
(DFunDef false "minLevelOf" ((PCons (PVar "m") (PVar "ms"))) (EApp (EApp (EVar "minI") (EApp (EVar "effvarLevel") (EVar "m"))) (EApp (EVar "minLevelOf") (EVar "ms"))))
(DTypeSig true "effectRoots" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "effectRoots" ((PVar "t") (PVar "roots")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "effectRoots") (EVar "b")) (EApp (EApp (EVar "effectRoots") (EVar "a")) (EApp (EApp (EVar "effectRowRoots") (EVar "row")) (EVar "roots"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "effectRoots") (EVar "b")) (EApp (EApp (EVar "effectRoots") (EVar "a")) (EVar "roots")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "effectRowRoots") (EVar "row")) (EVar "roots"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "effectRoots") (EVar "a")) (EVar "roots"))) (arm (PCon "TAuth" PWild) () (EVar "roots")) (arm PWild () (EVar "roots"))))
(DTypeSig true "effectRowRoots" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "effectRowRoots" ((PVar "row") (PVar "roots")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "roots")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "authRowRoots" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authRowRoots" ((PVar "row") (PVar "roots")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "Tip"))))
(DTypeSig true "substRow" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "EffRow") (TyCon "EffRow"))))))
(DFunDef false "substRow" ((PVar "gctx") (PVar "esub") (PVar "asub") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "labels") (PVar "members")) (EApp (EVar "rowFlat") (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "rowOfMembers") (EVar "gctx")) (EApp (EApp (EVar "substAtoms") (EVar "asub")) (EVar "labels"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EVar "substMember") (EVar "esub")) (EVar "m")))) (EVar "members"))))))
(DTypeSig false "substAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "substAtoms" ((PList) (PVar "atoms")) (EVar "atoms"))
(DFunDef false "substAtoms" ((PVar "asub") (PVar "atoms")) (EApp (EApp (EMethodRef "map") (EApp (EVar "substAtom") (EVar "asub"))) (EVar "atoms")))
(DTypeSig false "substAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Atom") (TyCon "Atom"))))
(DFunDef false "substAtom" ((PVar "asub") (PCon "Atom" (PVar "l") (PVar "q"))) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q"))))
(DTypeSig true "substAuth" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "substAuth" ((PList) (PVar "q")) (EVar "q"))
(DFunDef false "substAuth" ((PVar "asub") (PVar "q")) (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AVar" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (EApp (EVar "AVar") (EVar "cell"))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "asub")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EApp (EVar "substAuth") (EVar "asub"))) (EVar "ms")))) (arm (PCon "AProduct" (PVar "axes")) () (EApp (EVar "authNorm") (EApp (EVar "AProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))) (arm (PVar "c") () (EVar "c"))))
(DTypeSig false "substMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "substMember" ((PVar "esub") (PVar "m")) (EMatch (EUnOp "!" (EVar "m")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EApp (EApp (EVar "optionOr") (EVar "m")) (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "esub")))) (arm PWild () (EVar "m"))))
(DTypeSig true "anyListM" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyListM" (PWild (PList)) (EVar "False"))
(DFunDef false "anyListM" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyListM") (EVar "p")) (EVar "xs"))))
(DTypeSig false "monoSize" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoSize" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TApp" (PVar "f") (PVar "a")) () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "f"))) (EApp (EVar "monoSize") (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "r")) () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "a"))) (EApp (EVar "monoSize") (EVar "r")))) (arm (PCon "TQual" (PVar "a") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSize") (EVar "a")))) (arm PWild () (ELit (LInt 1)))))
(DTypeSig true "monoSizes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int")))
(DFunDef false "monoSizes" ((PList)) (ELit (LInt 0)))
(DFunDef false "monoSizes" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "+" (EApp (EVar "monoSize") (EVar "m")) (EApp (EVar "monoSizes") (EVar "rest"))))
(DTypeSig true "monoMintedBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "monoMintedBefore" ((PVar "tyvars") (PVar "effvars") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "<" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "tyvars"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a")) (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a")) (EApp (EApp (EVar "rowMintedBefore") (EVar "effvars")) (EVar "r"))) (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "rowMintedBefore") (EVar "effvars")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars")) (EVar "a"))) (arm PWild () (EVar "True"))))
(DTypeSig false "rowMintedBefore" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowMintedBefore" ((PVar "effvars") (PVar "r")) (EApp (EApp (EVar "allList") (ELam ((PVar "cell")) (EBinOp "<" (EApp (EVar "effvarId") (EVar "cell")) (EVar "effvars")))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "r")))))
(DTypeSig true "walkMonosSame" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "walkMonosSame" ((PList) (PList)) (EVar "True"))
(DFunDef false "walkMonosSame" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "walkMonosSame") (EVar "arest")) (EVar "brest"))))
(DFunDef false "walkMonosSame" (PWild PWild) (EVar "False"))
(DTypeSig false "walkMonoSame" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "walkMonoSame" ((PVar "x") (PVar "y")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "x")) (EApp (EVar "normalize") (EVar "y"))) (arm (PTuple (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EVar "walkMonoSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "walkMonoSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) () (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (arm (PTuple (PCon "TQual" (PVar "t1") (PVar "q1")) (PCon "TQual" (PVar "t2") (PVar "q2"))) () (EBinOp "&&" (EApp (EApp (EVar "walkMonoSame") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2")))) (arm (PTuple (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) () (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2"))) (arm (PTuple (PCon "TQual" PWild PWild) PWild) () (EVar "False")) (arm (PTuple PWild (PCon "TQual" PWild PWild)) () (EVar "False")) (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")))))
(DTypeSig true "tyvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Int")))
(DFunDef false "tyvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" PWild) () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DTypeSig true "monoSpineDepth" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoSpineDepth" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoSpineDepth") (EVar "a")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "monoIsApp" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoIsApp" ((PCon "TApp" PWild PWild)) (EVar "True"))
(DFunDef false "monoIsApp" (PWild) (EVar "False"))
(DTypeSig true "dedupI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "dedupI" ((PList)) (EListLit))
(DFunDef false "dedupI" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dedupI" ((PList (PVar "x") (PVar "y"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EListLit (EVar "x")) (EListLit (EVar "x") (EVar "y"))))
(DFunDef false "dedupI" ((PVar "xs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EVar "Tip")) (EListLit))))
(DTypeSig false "dedupIGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "dedupIGo" ((PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "dedupIGo" ((PCons (PVar "x") (PVar "xs")) (PVar "seen") (PVar "result")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "x")) (EVar "seen")) (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EVar "seen")) (EVar "result")) (EApp (EApp (EApp (EVar "dedupIGo") (EVar "xs")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "x") (EVar "result")))))
(DTypeSig true "authCellsIn" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authCellsIn" ((PVar "t") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) () (EApp (EApp (EVar "authCellsIn") (EVar "b")) (EApp (EApp (EVar "authCellsIn") (EVar "a")) (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "acc"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "authCellsIn") (EVar "b")) (EApp (EApp (EVar "authCellsIn") (EVar "a")) (EVar "acc")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "acc"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "authCellsIn") (EVar "inner")) (EApp (EApp (EVar "authTermCells") (EVar "q")) (EVar "acc")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "authTermCells") (EVar "q")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig true "authRowCells" (TyFun (TyCon "EffRow") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authRowCells" ((PVar "row") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "atom")) (EApp (EApp (EVar "authTermCells") (EApp (EVar "atomAuth") (EVar "atom"))) (EVar "m")))) (EVar "acc")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "authTermCells" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "authTermCells" ((PVar "q") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "cell")) (EVar "m")))) (EVar "acc")) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "authRoots" (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "authRoots" ((PVar "t") (PVar "roots")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip"))))
(DTypeSig true "substMono" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "substMono" ((PVar "gctx") (PVar "subst") (PVar "esub") (PVar "asub") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (EApp (EVar "TVar") (EVar "cell"))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "subst")))) (arm (PAs "c" (PCon "TCon" PWild PWild)) () (EVar "c")) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "TRigid") (EVar "n"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "a"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "substRow") (EVar "gctx")) (EVar "esub")) (EVar "asub")) (EVar "eff"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EVar "TEff") (EApp (EApp (EApp (EApp (EVar "substRow") (EVar "gctx")) (EVar "esub")) (EVar "asub")) (EVar "r")))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EVar "esub")) (EVar "asub")) (EVar "inner"))) (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q")))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EVar "TAuth") (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q"))))))
(DTypeSig true "stripEff" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripEff" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EVar "t"))
(DFunDef false "stripEff" ((PVar "t")) (EVar "t"))
(DTypeSig true "tyVarNames" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarNames" ((PCon "TyVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "tyVarNames" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "a")) (EApp (EVar "tyVarNames") (EVar "b"))))
(DFunDef false "tyVarNames" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "a")) (EApp (EVar "tyVarNames") (EVar "b"))))
(DFunDef false "tyVarNames" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "ts")))
(DFunDef false "tyVarNames" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyVarNames" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyVarNames") (EVar "t")))
(DFunDef false "tyVarNames" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyVarNames") (EVar "t")))
(DTypeSig true "tyAppSpine" (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "tyAppSpine" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EVar "a")) (arm (PTuple (PVar "head") (PVar "args")) () (ETuple (EVar "head") (EBinOp "++" (EVar "args") (EListLit (EVar "b")))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (ETuple (EVar "t") (EListLit)))
(DTypeSig true "monoScheme" (TyFun (TyCon "Mono") (TyCon "Scheme")))
(DFunDef false "monoScheme" ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EVar "t")))
(DTypeSig true "schemeAuthIds" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "schemeAuthIds" ((PCon "Forall" PWild PWild (PVar "avars") PWild PWild PWild)) (EVar "avars"))
(DTypeSig true "tyArrowCount" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "tyArrowCount" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyArrowCount") (EVar "t")))
(DFunDef false "tyArrowCount" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyArrowCount") (EVar "t")))
(DFunDef false "tyArrowCount" ((PCon "TyFun" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "tyArrowCount") (EVar "b"))))
(DFunDef false "tyArrowCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "arrowArity" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "arrowArity" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "arrowArity") (EVar "b")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "arrowArity") (EVar "inner"))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig true "stripArrows" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "stripArrows" ((PCon "TFun" PWild PWild (PVar "b"))) (EApp (EVar "stripArrows") (EVar "b")))
(DFunDef false "stripArrows" ((PVar "t")) (EVar "t"))
(DTypeSig true "recordOwnerModule" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "recordOwnerModule" ((PVar "ri")) (EMatch (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hk")) () (EMatch (EApp (EVar "headKeyIdent") (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "Ident" PWild (PVar "io") PWild)) () (EApp (EApp (EApp (EVar "identOriginFold") (EVar "None")) (ELam ((PVar "mid")) (EApp (EVar "Some") (EVar "mid")))) (EVar "io")))))))
(DTypeSig true "rowSame" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowSame" ((PVar "r1") (PVar "r2")) (EBlock (DoLet false false (PTuple (PVar "atoms1") (PVar "tails1")) (EApp (EVar "rowFlat") (EVar "r1"))) (DoLet false false (PTuple (PVar "atoms2") (PVar "tails2")) (EApp (EVar "rowFlat") (EVar "r2"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "effvarId")) (EVar "tails1")) (EApp (EApp (EMethodRef "map") (EVar "effvarId")) (EVar "tails2"))) (EApp (EApp (EVar "atomsSame") (EApp (EVar "atomsNorm") (EVar "atoms1"))) (EApp (EVar "atomsNorm") (EVar "atoms2")))))))
(DTypeSig false "atomsSame" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Bool"))))
(DFunDef false "atomsSame" ((PList) (PList)) (EVar "True"))
(DFunDef false "atomsSame" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "atomKey") (EVar "y"))) (EApp (EApp (EVar "authSame") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EApp (EApp (EVar "atomsSame") (EVar "xs")) (EVar "ys"))))
(DFunDef false "atomsSame" (PWild PWild) (EVar "False"))
(DTypeSig true "authSame" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSame" ((PVar "p") (PVar "q")) (EBinOp "&&" (EApp (EApp (EVar "authSub") (EVar "p")) (EVar "q")) (EApp (EApp (EVar "authSub") (EVar "q")) (EVar "p"))))
(DTypeSig true "recordResultMono" (TyFun (TyCon "RecordInfo") (TyCon "Mono")))
(DFunDef false "recordResultMono" ((PCon "RecordInfo" PWild PWild (PVar "result") PWild PWild)) (EVar "result"))
(DTypeSig true "rootIdOf" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "rootIdOf" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" (PVar "t")) () (EApp (EVar "rootVarId") (EApp (EApp (EVar "normalizeLink") (EVar "cell")) (EVar "t"))))))
(DFunDef false "rootIdOf" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig false "rootVarId" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "rootVarId" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "Link" PWild) () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DFunDef false "rootVarId" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "sameRootId" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "sameRootId" ((PVar "id") (PVar "v")) (EBinOp "==" (EApp (EVar "rootIdOf") (EVar "v")) (EVar "id")))
(DTypeSig true "monoIsBool" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoIsBool" ((PCon "TCon" (PLit (LString "Bool")) PWild)) (EVar "True"))
(DFunDef false "monoIsBool" (PWild) (EVar "False"))
(DTypeSig true "resultAfterArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "resultAfterArrows" ((PVar "n") (PVar "t")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "t")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild (PVar "b")) () (EApp (EApp (EVar "resultAfterArrows") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "monoHasArrowInSlot" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHasArrowInSlot" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrow") (EVar "b")) (EApp (EVar "monoHasArrowInSlot") (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrowInSlot") (EVar "a")) (EApp (EVar "monoHasArrowInSlot") (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig false "monoHasArrow" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHasArrow" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild PWild PWild) () (EVar "True")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EApp (EVar "monoHasArrow") (EVar "a")) (EApp (EVar "monoHasArrow") (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig true "monoIsTyvarId" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "monoIsTyvarId" ((PVar "m") (PVar "id")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm PWild () (EVar "False"))))
(DTypeSig true "matchCol0Type" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "matchCol0Type" ((PVar "ty")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "ty")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "headTyconMono") (EVar "ty")) (arm (PCon "Some" (PCon "HkDecl" (PVar "k"))) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "Some" (PCon "HkRigid" PWild)) () (EApp (EVar "Some") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "n"))))))))
(DTypeSig true "nthTy" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "nthTy" (PWild (PList)) (EVar "None"))
(DFunDef false "nthTy" ((PVar "i") (PCons (PVar "t") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "t")) (EIf (EVar "otherwise") (EApp (EApp (EVar "nthTy") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "collectAuthvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectAuthvarIds" ((PCons (PCon "TAuth" (PCon "AVar" (PVar "cell"))) (PVar "rs"))) (EBinOp "::" (EApp (EVar "authvarId") (EVar "cell")) (EApp (EVar "collectAuthvarIds") (EVar "rs"))))
(DFunDef false "collectAuthvarIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectAuthvarIds") (EVar "rs")))
(DFunDef false "collectAuthvarIds" ((PList)) (EListLit))
(DTypeSig true "collectTyIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectTyIds" ((PCons (PCon "TVar" (PVar "cell")) (PVar "rs"))) (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "collectTyIds") (EVar "rs"))))
(DFunDef false "collectTyIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectTyIds") (EVar "rs")))
(DFunDef false "collectTyIds" ((PList)) (EListLit))
(DTypeSig true "collectRowEffvarIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "collectRowEffvarIds" ((PCons (PCon "TEff" (PCon "EffRow" PWild (PCon "Some" (PVar "cell")))) (PVar "rs"))) (EBinOp "::" (EApp (EVar "effvarId") (EVar "cell")) (EApp (EVar "collectRowEffvarIds") (EVar "rs"))))
(DFunDef false "collectRowEffvarIds" ((PCons PWild (PVar "rs"))) (EApp (EVar "collectRowEffvarIds") (EVar "rs")))
(DFunDef false "collectRowEffvarIds" ((PList)) (EListLit))
(DTypeSig true "monoTyvarId" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoTyvarId" ((PCon "TVar" (PVar "cell"))) (EApp (EVar "tyvarId") (EVar "cell")))
(DFunDef false "monoTyvarId" (PWild) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "schemeMono" (TyFun (TyCon "Scheme") (TyCon "Mono")))
(DFunDef false "schemeMono" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig true "monoUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoUnboundIds" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoUnboundIds") (EVar "a")))))
(DTypeSig true "monoArgUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoArgUnboundIds" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoArgUnboundIds") (EVar "b")))) (arm PWild () (EListLit))))
(DTypeSig true "monoRootIdSet" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "monoRootIdSet" ((PVar "monos")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "monos"))))) (EVar "omEmpty")))
(DTypeSig true "concreteHeadVarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "concreteHeadVarIds" ((PVar "dm")) (EMatch (EApp (EVar "headTyconMono") (EVar "dm")) (arm (PCon "Some" PWild) () (EApp (EVar "monoUnboundIds") (EVar "dm"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "argMentions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "argMentions" ((PVar "typarams") (PVar "ty")) (EApp (EApp (EVar "anyMember") (EApp (EVar "tyVarNames") (EVar "ty"))) (EVar "typarams")))
(DTypeSig true "anyMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyMember" ((PVar "xs") (PVar "ys")) (EApp (EApp (EDictApp "any") (ELam ((PVar "x")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")))) (EVar "xs")))
(DTypeSig true "propParamNamesTc" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesTc" ((PVar "ps")) (EApp (EApp (EMethodRef "map") (EVar "propParamName")) (EVar "ps")))
(DTypeSig true "patVarsTc" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsTc" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsTc" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListTc") (EVar "args")))
(DFunDef false "patVarsTc" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsTc") (EVar "h")) (EApp (EVar "patVarsTc") (EVar "t"))))
(DFunDef false "patVarsTc" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListTc") (EVar "ps")))
(DFunDef false "patVarsTc" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListTc") (EVar "ps")))
(DFunDef false "patVarsTc" ((PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsTc") (EVar "p"))))
(DFunDef false "patVarsTc" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldVarsTc")) (EVar "fields")))
(DFunDef false "patVarsTc" (PWild) (EListLit))
(DTypeSig true "patVarsListTc" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListTc" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patVarsTc")) (EVar "ps")))
(DTypeSig false "recPatFieldVarsTc" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsTc" ((PCon "RecPatField" (PVar "label") PWild PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsTc" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsTc") (EVar "p")))
(DTypeSig true "nthMono" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "nthMono" (PWild (PList)) (EVar "None"))
(DFunDef false "nthMono" ((PVar "k") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "x")) (EApp (EApp (EVar "nthMono") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "cohOverlap" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohOverlap" ((PVar "xs") (PVar "ys")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys"))) (EApp (EApp (EVar "cohOverlapGo") (EApp (EVar "Ref") (EListLit))) (EApp (EApp (EVar "zipL") (EVar "xs")) (EVar "ys"))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cohOverlapGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "cohOverlapGo" (PWild (PList)) (EVar "True"))
(DFunDef false "cohOverlapGo" ((PVar "subst") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")) (EApp (EApp (EVar "cohOverlapGo") (EVar "subst")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohResolve" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "cohResolve" ((PVar "subst") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "tyvarId") (EVar "cell"))) (EUnOp "!" (EVar "subst"))) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m2"))) (arm (PCon "None") () (EApp (EVar "TVar") (EVar "cell"))))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "cohGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohGo" ((PVar "subst") (PVar "t1") (PVar "t2")) (EApp (EApp (EApp (EVar "cohGoR") (EVar "subst")) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "t1"))) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "t2"))))
(DTypeSig false "cohGoR" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c1"))) (EApp (EVar "TVar") (EVar "c2"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TVar" (PVar "c1")) (PVar "t")) (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c1"))) (EVar "t")))
(DFunDef false "cohGoR" ((PVar "subst") (PVar "t") (PCon "TVar" (PVar "c2"))) (EApp (EApp (EApp (EVar "cohBind") (EVar "subst")) (EApp (EVar "tyvarId") (EVar "c2"))) (EVar "t")))
(DFunDef false "cohGoR" (PWild (PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "cohGoR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" (PWild (PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a1")) (EVar "a2"))))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TFun" (PVar "a1") PWild (PVar "b1")) (PCon "TFun" (PVar "a2") PWild (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "b1")) (EVar "b2"))))
(DFunDef false "cohGoR" (PWild (PCon "TEff" PWild) (PCon "TEff" PWild)) (EVar "True"))
(DFunDef false "cohGoR" (PWild (PCon "TAuth" PWild) (PCon "TAuth" PWild)) (EVar "True"))
(DFunDef false "cohGoR" ((PVar "subst") (PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")))
(DFunDef false "cohGoR" ((PVar "subst") (PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "cohGo") (EVar "subst")) (EVar "a")) (EVar "b")))
(DFunDef false "cohGoR" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "cohBind" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohBind" ((PVar "subst") (PVar "id") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "m")) (EVar "False") (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "subst")) (EBinOp "::" (ETuple (EVar "id") (EVar "m")) (EUnOp "!" (EVar "subst"))))) (DoExpr (EVar "True")))))
(DTypeSig false "cohOccurs" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "cohOccurs" ((PVar "subst") (PVar "id") (PVar "m")) (EMatch (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm (PCon "TApp" (PVar "f") (PVar "a")) () (EBinOp "||" (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "f")) (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a")) (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "cohOccurs") (EVar "subst")) (EVar "id")) (EVar "a"))) (arm PWild () (EVar "False"))))
(DTypeSig true "matchOneSided" (TyFun (TyFun (TyVar "g") (TyFun (TyVar "s") (TyApp (TyApp (TyApp (TyCon "MStep") (TyVar "k")) (TyVar "g")) (TyVar "s")))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "k") (TyCon "Bool"))) (TyFun (TyFun (TyVar "s") (TyFun (TyVar "s") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "g") (TyVar "s"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "s"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "s"))))))))))
(DFunDef false "matchOneSided" (PWild PWild PWild (PList) (PVar "acc")) (EApp (EVar "Some") (EVar "acc")))
(DFunDef false "matchOneSided" ((PVar "step") (PVar "keyEq") (PVar "eqS") (PCons (PTuple (PVar "g") (PVar "s")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "step") (EVar "g")) (EVar "s")) (arm (PCon "MFail") () (EVar "None")) (arm (PCon "MOk") () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EVar "acc"))) (arm (PCon "MKids" (PVar "kids")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EBinOp "++" (EVar "kids") (EVar "rest"))) (EVar "acc"))) (arm (PCon "MVar" (PVar "k")) () (EMatch (EApp (EApp (EApp (EVar "lookupBy") (EVar "keyEq")) (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PVar "prev")) () (EIf (EApp (EApp (EVar "eqS") (EVar "prev")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EVar "acc")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "step")) (EVar "keyEq")) (EVar "eqS")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "s")) (EVar "acc"))))))))
(DTypeSig false "lookupBy" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "k") (TyCon "Bool"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "lookupBy" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupBy" ((PVar "keq") (PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "keq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EApp (EVar "lookupBy") (EVar "keq")) (EVar "k")) (EVar "rest"))))
(DTypeSig true "cohEqMono" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "cohEqMono" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "cohEqR") (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "cohEqR" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "cohEqR" ((PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))))
(DFunDef false "cohEqR" ((PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "cohEqR" ((PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "cohEqR" ((PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EVar "cohEqMono") (EVar "f1")) (EVar "f2")) (EApp (EApp (EVar "cohEqMono") (EVar "a1")) (EVar "a2"))))
(DFunDef false "cohEqR" ((PCon "TFun" (PVar "a1") PWild (PVar "b1")) (PCon "TFun" (PVar "a2") PWild (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EVar "cohEqMono") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "cohEqMono") (EVar "b1")) (EVar "b2"))))
(DFunDef false "cohEqR" ((PCon "TEff" PWild) (PCon "TEff" PWild)) (EVar "True"))
(DFunDef false "cohEqR" ((PCon "TAuth" PWild) (PCon "TAuth" PWild)) (EVar "True"))
(DFunDef false "cohEqR" ((PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EVar "cohEqR") (EApp (EVar "normalize") (EVar "a"))) (EVar "b")))
(DFunDef false "cohEqR" ((PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EVar "cohEqR") (EVar "a")) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "cohEqR" (PWild PWild) (EVar "False"))
(DTypeSig true "matchEqMono" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "matchEqMono" ((PVar "subst") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "matchEqR") (EVar "subst")) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "b"))))
(DTypeSig false "matchEqR" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "matchEqR" (PWild (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))))
(DFunDef false "matchEqR" (PWild (PCon "TCon" (PVar "a") (PVar "oa")) (PCon "TCon" (PVar "b") (PVar "ob"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "matchEqR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" (PWild (PCon "TCon" (PVar "a") PWild) (PCon "TRigid" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" (PWild (PCon "TRigid" (PVar "a")) (PCon "TCon" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TApp" (PVar "f1") (PVar "a1")) (PCon "TApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a1")) (EVar "a2"))))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "matchEqRow") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "b1")) (EVar "b2"))))
(DFunDef false "matchEqR" (PWild (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) (EApp (EApp (EVar "matchEqRow") (EVar "r1")) (EVar "r2")))
(DFunDef false "matchEqR" (PWild (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) (EApp (EApp (EVar "matchEqAuth") (EVar "q1")) (EVar "q2")))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TQual" (PVar "a") (PVar "q1")) (PCon "TQual" (PVar "b") (PVar "q2"))) (EBinOp "&&" (EApp (EApp (EVar "matchEqAuth") (EVar "q1")) (EVar "q2")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" ((PVar "subst") (PCon "TQual" (PVar "a") (PVar "q")) (PVar "b")) (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "q")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" ((PVar "subst") (PVar "a") (PCon "TQual" (PVar "b") (PVar "q"))) (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "q")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EVar "a")) (EVar "b"))))
(DFunDef false "matchEqR" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "matchEqAuth" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "matchEqAuth" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "authSub") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "authSub") (EVar "b")) (EVar "a"))))
(DTypeSig false "matchEqRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "matchEqRow" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "atomsA") (PVar "tailsA")) (EApp (EVar "rowFlat") (EVar "a"))) (DoLet false false (PTuple (PVar "atomsB") (PVar "tailsB")) (EApp (EVar "rowFlat") (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "atomsA")) (EApp (EVar "listLen") (EVar "atomsB"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "tailsA")) (EApp (EVar "listLen") (EVar "tailsB")))) (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "atomsB")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EVar "matchEqAuth") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (arm (PCon "None") () (EVar "False"))))) (EVar "atomsA"))) (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EApp (EApp (EVar "anyList") (ELam ((PVar "y")) (EBinOp "==" (EApp (EVar "effvarId") (EVar "x")) (EApp (EVar "effvarId") (EVar "y"))))) (EVar "tailsB")))) (EVar "tailsA"))))))
(DTypeSig true "cohPpPair" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cohPpPair" ((PVar "xs") (PVar "ys")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "s1") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "cohPpEach") (EVar "ctx")) (EVar "cnt")) (EVar "xs")))) (DoLet false false (PVar "s2") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "cohPpEach") (EVar "ctx")) (EVar "cnt")) (EVar "ys")))) (DoExpr (ETuple (EVar "s1") (EVar "s2")))))
(DTypeSig false "cohPpEach" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "cohPpEach" ((PVar "ctx") (PVar "cnt") (PVar "ms")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0)))) (EVar "ms")))
(DTypeSig true "tySubsumesV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tySubsumesV" ((PVar "generals") (PVar "specifics")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "generals")) (EApp (EVar "listLen") (EVar "specifics"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "tyStep")) (EVar "eqStr")) (EVar "tyStructEq")) (EApp (EApp (EVar "zipL") (EVar "generals")) (EVar "specifics"))) (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tyHeadEqV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyHeadEqV" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "tySubsumesV") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "tySubsumesV") (EVar "b")) (EVar "a"))))
(DTypeSig true "tyStrictlyMoreSpecificV" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyStrictlyMoreSpecificV" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "tySubsumesV") (EVar "b")) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "tySubsumesV") (EVar "a")) (EVar "b")))))
(DTypeSig true "tyStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Ty")))))
(DFunDef false "tyStep" ((PCon "TyVar" (PVar "gn")) PWild) (EApp (EVar "MVar") (EVar "gn")))
(DFunDef false "tyStep" ((PRec "TyCon" ((rf "tyConName" (PVar "a")) (rf "tyConOrigin" (PVar "oa"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "b")) (rf "tyConOrigin" (PVar "ob"))) false)) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (EVar "MOk") (EVar "MFail")))
(DFunDef false "tyStep" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyApp" (PVar "f1") (PVar "a1")) (PCon "TyApp" (PVar "f2") (PVar "a2"))) (EApp (EVar "MKids") (EListLit (ETuple (EVar "f1") (EVar "f2")) (ETuple (EVar "a1") (EVar "a2")))))
(DFunDef false "tyStep" ((PCon "TyApp" PWild PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) (EApp (EVar "MKids") (EListLit (ETuple (EVar "a1") (EVar "a2")) (ETuple (EVar "b1") (EVar "b2")))))
(DFunDef false "tyStep" ((PCon "TyFun" PWild PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyTuple" (PVar "ts1")) (PCon "TyTuple" (PVar "ts2"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "ts1")) (EApp (EVar "listLen") (EVar "ts2"))) (EApp (EVar "MKids") (EApp (EApp (EVar "zipL") (EVar "ts1")) (EVar "ts2"))) (EVar "MFail")))
(DFunDef false "tyStep" ((PCon "TyTuple" PWild) PWild) (EVar "MFail"))
(DFunDef false "tyStep" ((PCon "TyEffect" PWild PWild (PVar "t1")) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyConstrained" PWild (PVar "t1")) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyRow" PWild PWild PWild) PWild) (EVar "MOk"))
(DFunDef false "tyStep" ((PCon "TyAuth" PWild PWild) PWild) (EVar "MOk"))
(DFunDef false "tyStep" ((PCon "TyNamed" PWild (PVar "t1") PWild) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DFunDef false "tyStep" ((PCon "TyQual" (PVar "t1") PWild PWild) (PVar "s")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t1") (EApp (EVar "stripTyWrap") (EVar "s"))))))
(DTypeSig true "stripTyWrap" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTyWrap" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "stripTyWrap") (EVar "t")))
(DFunDef false "stripTyWrap" ((PVar "t")) (EVar "t"))
(DTypeSig true "tyStructEq" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyStructEq" ((PRec "TyCon" ((rf "tyConName" (PVar "a")) (rf "tyConOrigin" (PVar "oa"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "b")) (rf "tyConOrigin" (PVar "ob"))) false)) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")))
(DFunDef false "tyStructEq" ((PCon "TyVar" (PVar "a")) (PCon "TyVar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "tyStructEq" ((PCon "TyApp" (PVar "f1") (PVar "a1")) (PCon "TyApp" (PVar "f2") (PVar "a2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "f1")) (EVar "f2")) (EApp (EApp (EVar "tyStructEq") (EVar "a1")) (EVar "a2"))))
(DFunDef false "tyStructEq" ((PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "tyStructEq") (EVar "b1")) (EVar "b2"))))
(DFunDef false "tyStructEq" ((PCon "TyTuple" (PVar "ts1")) (PCon "TyTuple" (PVar "ts2"))) (EApp (EApp (EVar "tyStructEqList") (EVar "ts1")) (EVar "ts2")))
(DFunDef false "tyStructEq" ((PCon "TyEffect" PWild PWild (PVar "t1")) (PCon "TyEffect" PWild PWild (PVar "t2"))) (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")))
(DFunDef false "tyStructEq" ((PCon "TyConstrained" PWild (PVar "t1")) (PCon "TyConstrained" PWild (PVar "t2"))) (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")))
(DFunDef false "tyStructEq" (PWild PWild) (EVar "False"))
(DTypeSig false "tyStructEqList" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "tyStructEqList" ((PList) (PList)) (EVar "True"))
(DFunDef false "tyStructEqList" ((PCons (PVar "t1") (PVar "ts1")) (PCons (PVar "t2") (PVar "ts2"))) (EBinOp "&&" (EApp (EApp (EVar "tyStructEq") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "tyStructEqList") (EVar "ts1")) (EVar "ts2"))))
(DFunDef false "tyStructEqList" (PWild PWild) (EVar "False"))
(DTypeSig false "headTyNode" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "headTyNode" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTyNode") (EVar "a")))
(DFunDef false "headTyNode" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTyNode") (EVar "t")))
(DFunDef false "headTyNode" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTyNode") (EVar "t")))
(DFunDef false "headTyNode" ((PVar "t")) (EVar "t"))
(DTypeSig true "headTySpineNode" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "headTySpineNode" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTySpineNode") (EVar "a")))
(DFunDef false "headTySpineNode" ((PVar "t")) (EVar "t"))
(DTypeSig true "headTyconTy" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "headTyconTy" ((PVar "t")) (EMatch (EApp (EVar "headTyNode") (EVar "t")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "o")) (EVar "n")))) (arm (PCon "TyTuple" (PVar "ts")) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "ts")))))) (arm (PCon "TyFun" PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EVar "funHeadTag")))) (arm PWild () (EVar "None"))))
(DTypeSig true "mergeSubstPreferConcrete" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "mergeSubstPreferConcrete" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "mergeSubstPreferConcrete" ((PVar "acc") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EApp (EApp (EVar "mergeSubstPreferConcrete") (EApp (EApp (EApp (EVar "mergeOne") (EVar "acc")) (EVar "k")) (EVar "v"))) (EVar "rest")))
(DTypeSig true "mergeOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "mergeOne" ((PList) (PVar "k") (PVar "v")) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "mergeOne" ((PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest")) (PVar "k") (PVar "v")) (EIf (EBinOp "==" (EVar "k2") (EVar "k")) (EBinOp "::" (ETuple (EVar "k2") (EApp (EApp (EVar "preferConcrete") (EVar "v2")) (EVar "v"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EApp (EApp (EApp (EVar "mergeOne") (EVar "rest")) (EVar "k")) (EVar "v"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preferConcrete" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "preferConcrete" ((PVar "a") (PVar "b")) (EMatch (EApp (EVar "headTyconMono") (EVar "a")) (arm (PCon "Some" PWild) () (EVar "a")) (arm (PCon "None") () (EVar "b"))))
(DTypeSig true "matchTyMono" (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "matchTyMono" ((PVar "headTy") (PVar "resultMono")) (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EListLit (ETuple (EVar "headTy") (EVar "resultMono")))) (EListLit)))))
(DTypeSig false "matchTyMonos" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "matchTyMonos" ((PVar "pats") (PVar "goals")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "goals"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EApp (EApp (EVar "zipL") (EVar "pats")) (EVar "goals"))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "entryHeadMatches" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "entryHeadMatches" ((PVar "hty") (PVar "itys") (PVar "goals")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "itys")) (EApp (EVar "listLen") (EVar "goals"))) (EApp (EVar "isSome") (EApp (EApp (EVar "matchTyMonos") (EVar "itys")) (EVar "goals"))) (EIf (EVar "otherwise") (EMatch (EVar "goals") (arm (PCons (PVar "g") PWild) () (EApp (EVar "isSome") (EApp (EApp (EVar "matchTyMono") (EVar "hty")) (EVar "g")))) (arm (PList) () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "matchStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Mono")))))
(DFunDef false "matchStep" ((PCon "TyVar" (PVar "n")) PWild) (EApp (EVar "MVar") (EVar "n")))
(DFunDef false "matchStep" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TCon" (PVar "n2") (PVar "o2")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (EVar "n2")) (EVar "o2")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TRigid" (PVar "n2")) () (EIf (EBinOp "==" (EVar "n") (EVar "n2")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "ma") (PVar "mb")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a") (EVar "ma")) (ETuple (EVar "b") (EVar "mb"))))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyTuple" (PVar "ts")) (PVar "m")) (EMatch (EApp (EVar "tupleSpine") (EVar "m")) (arm (PCon "Some" (PVar "ms")) () (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "ts")) (EApp (EVar "listLen") (EVar "ms"))) (EApp (EVar "MKids") (EApp (EApp (EVar "zipL") (EVar "ts")) (EVar "ms"))) (EVar "MFail"))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TFun" (PVar "ma") PWild (PVar "mb")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a") (EVar "ma")) (ETuple (EApp (EVar "stripEff") (EVar "b")) (EVar "mb"))))) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "m")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t") (EVar "m")))))
(DFunDef false "matchStep" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "m")) (EApp (EVar "MKids") (EListLit (ETuple (EVar "t") (EVar "m")))))
(DFunDef false "matchStep" ((PCon "TyRow" PWild PWild PWild) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TEff" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail"))))
(DFunDef false "matchStep" (PWild PWild) (EVar "MFail"))
(DTypeSig true "findTvarInMono" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarInMono" ((PVar "t") (PVar "id")) (EApp (EApp (EVar "findTvarN") (EApp (EVar "normalize") (EVar "t"))) (EVar "id")))
(DTypeSig false "findTvarN" (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarN" ((PCon "TVar" (PVar "cell")) (PVar "id")) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id")) (EApp (EVar "Some") (EApp (EVar "TVar") (EVar "cell"))) (EVar "None")))
(DFunDef false "findTvarN" ((PCon "TCon" PWild PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TRigid" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TApp" (PVar "a") (PVar "b")) (PVar "id")) (EApp (EApp (EApp (EVar "firstTvar") (EVar "a")) (EVar "b")) (EVar "id")))
(DFunDef false "findTvarN" ((PCon "TFun" (PVar "a") PWild (PVar "b")) (PVar "id")) (EApp (EApp (EApp (EVar "firstTvar") (EVar "a")) (EVar "b")) (EVar "id")))
(DFunDef false "findTvarN" ((PCon "TEff" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TAuth" PWild) PWild) (EVar "None"))
(DFunDef false "findTvarN" ((PCon "TQual" (PVar "a") PWild) (PVar "id")) (EApp (EApp (EVar "findTvarInMono") (EVar "a")) (EVar "id")))
(DTypeSig false "firstTvar" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "firstTvar" ((PVar "a") (PVar "b") (PVar "id")) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "a")) (EVar "id")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Some") (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "findTvarInMono") (EVar "b")) (EVar "id")))))
(DTypeSig true "headMonoNode" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "headMonoNode" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "headMonoNode") (EVar "a"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "headMonoNode") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "peelQual" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "peelQual" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "peelQual") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "headTyconMono" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "headTyconMono" ((PVar "t")) (EMatch (EApp (EVar "headMonoNode") (EVar "t")) (arm (PCon "TCon" (PVar "n") (PVar "o")) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "o")) (EVar "n")))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EApp (EVar "HkRigid") (EVar "n")))) (arm (PCon "TFun" PWild PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EVar "OriginBuiltin")) (EVar "funHeadTag")))) (arm PWild () (EVar "None"))))
(DTypeSig true "headTyconNameMono" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconNameMono" ((PVar "t")) (EMatch (EApp (EVar "headMonoNode") (EVar "t")) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig true "tupleMono" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono")))
(DFunDef false "tupleMono" ((PVar "ts")) (EApp (EApp (EVar "tupleSpineOf") (EApp (EVar "tconTupleHead") (EApp (EVar "listLen") (EVar "ts")))) (EVar "ts")))
(DTypeSig true "tupleSpineOf" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "tupleSpineOf" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "tupleSpineOf" ((PVar "acc") (PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "tupleSpineOf") (EApp (EApp (EVar "TApp") (EVar "acc")) (EVar "t"))) (EVar "rest")))
(DTypeSig true "findTvarInMonos" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "findTvarInMonos" ((PList) PWild) (EVar "None"))
(DFunDef false "findTvarInMonos" ((PCons (PVar "m") (PVar "rest")) (PVar "i")) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "m")) (EVar "i")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "findTvarInMonos") (EVar "rest")) (EVar "i")))))
(DTypeSig true "cohApply" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "cohApply" ((PVar "subst") (PVar "m")) (EMatch (EApp (EApp (EVar "cohResolve") (EVar "subst")) (EVar "m")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EVar "eff")) (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "cohApply") (EVar "subst")) (EVar "a"))) (EVar "q"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "sigStandIn" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "String")))
(DFunDef false "sigStandIn" ((PVar "cell")) (EBinOp "++" (EBinOp "++" (ELit (LString "%sig")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "cell"))))) (ELit (LString ""))))
(DTypeSig true "sigCellsOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))))))
(DFunDef false "sigCellsOf" ((PVar "sigIds") (PVar "cells")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "c")))) (EVar "sigIds")))) (EVar "cells")))
(DTypeSig true "sigRigidBindings" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))
(DFunDef false "sigRigidBindings" ((PVar "sigIds") (PVar "cells")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EApp (EVar "TRigid") (EApp (EVar "sigStandIn") (EVar "c")))))) (EApp (EApp (EVar "sigCellsOf") (EVar "sigIds")) (EVar "cells"))))
(DTypeSig true "rigidSigPairs" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "rigidSigPairs" ((PVar "gctx") (PVar "sigIds") (PVar "pairs")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EBinOp "++" (EApp (EVar "monoVarCells") (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "monoVarCells") (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs"))) (DoExpr (EMatch (EApp (EApp (EVar "sigRigidBindings") (EVar "sigIds")) (EVar "cells")) (arm (PList) () (EVar "pairs")) (arm (PVar "toRigid") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "toRigid")) (EListLit)) (EListLit)) (EApp (EVar "fst") (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "toRigid")) (EListLit)) (EListLit)) (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs")))))))
(DTypeSig true "monoVarCells" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar")))))
(DFunDef false "monoVarCells" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EVar "cell"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoVarCells") (EVar "a")) (EApp (EVar "monoVarCells") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoVarCells") (EVar "a")) (EApp (EVar "monoVarCells") (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoVarCells") (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "spineHeadMono" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "spineHeadMono" ((PVar "t")) (EMatch (EApp (EVar "peelQual") (EVar "t")) (arm (PCon "TApp" (PVar "f") PWild) () (EApp (EVar "spineHeadMono") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "locEq" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "locEq" ((PCon "Loc" (PVar "f1") (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PCon "Loc" (PVar "f2") (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f1") (EVar "f2")) (EBinOp "==" (EVar "a1") (EVar "a2"))) (EBinOp "==" (EVar "b1") (EVar "b2"))) (EBinOp "==" (EVar "c1") (EVar "c2"))) (EBinOp "==" (EVar "d1") (EVar "d2"))))
(DTypeSig true "stripTyConstraints" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTyConstraints" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripTyConstraints") (EVar "t")))
(DFunDef false "stripTyConstraints" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripTyConstraints") (EVar "t")))
(DFunDef false "stripTyConstraints" ((PVar "t")) (EVar "t"))
(DTypeSig true "allConcreteHeads" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "allConcreteHeads" ((PList)) (EVar "True"))
(DFunDef false "allConcreteHeads" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "m"))) (EApp (EVar "allConcreteHeads") (EVar "rest"))))
(DTypeSig true "monoIndexEffvarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoIndexEffvarIds" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoIndexEffvarIds") (EVar "a")) (EApp (EVar "monoIndexEffvarIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EApp (EVar "monoIndexEffvarIds") (EVar "a")) (EApp (EVar "rowTailId") (EVar "r"))) (EApp (EVar "monoIndexEffvarIds") (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EVar "rowTailId") (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoIndexEffvarIds") (EVar "a"))) (arm (PCon "TAuth" PWild) () (EListLit)) (arm PWild () (EListLit))))
(DTypeSig true "rowTailId" (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "rowTailId" ((PVar "row")) (EApp (EApp (EMethodRef "map") (EVar "effvarId")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig true "monoSameGiven" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoSameGiven" ((PVar "a") (PVar "b")) (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TVar" (PVar "c1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TVar" (PVar "c2")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2")))) (arm PWild () (EVar "False")))) (arm (PCon "TCon" (PVar "x") (PVar "ox")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TCon" (PVar "y") (PVar "oy")) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "x")) (EVar "ox")) (EVar "y")) (EVar "oy"))) (arm (PCon "TRigid" (PVar "y")) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False")))) (arm (PCon "TRigid" (PVar "x")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TRigid" (PVar "y")) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm (PCon "TCon" (PVar "y") PWild) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False")))) (arm (PCon "TApp" (PVar "a1") (PVar "b1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TApp" (PVar "a2") (PVar "b2")) () (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "monoSameGiven") (EVar "b1")) (EVar "b2")))) (arm PWild () (EVar "False")))) (arm (PCon "TFun" (PVar "a1") PWild (PVar "b1")) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TFun" (PVar "a2") PWild (PVar "b2")) () (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "monoSameGiven") (EVar "b1")) (EVar "b2")))) (arm PWild () (EVar "False")))) (arm (PCon "TAuth" PWild) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TAuth" PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "TEff" PWild) () (EMatch (EApp (EVar "peelQual") (EVar "b")) (arm (PCon "TEff" PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "monoVecSameGiven" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "monoVecSameGiven" ((PList) (PList)) (EVar "True"))
(DFunDef false "monoVecSameGiven" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "arest")) (EVar "brest"))))
(DFunDef false "monoVecSameGiven" (PWild PWild) (EVar "False"))
(DTypeSig true "monoTyvarIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "monoTyvarIds" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoTyvarIds") (EVar "a")) (EApp (EVar "monoTyvarIds") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoTyvarIds") (EVar "a")) (EApp (EVar "monoTyvarIds") (EVar "b")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoTyvarIds") (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "peelArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "peelArrows" ((PVar "n") (PVar "t")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "::" (EVar "a") (EApp (EApp (EVar "peelArrows") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "b")))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isBareTyvarMono" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isBareTyvarMono" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "monoVectorClosed" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "monoVectorClosed" ((PVar "args")) (EApp (EApp (EVar "allList") (EVar "monoClosed")) (EVar "args")))
(DTypeSig true "monoClosed" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoClosed" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EVar "False")) (arm (PCon "TRigid" PWild) () (EVar "False")) (arm (PCon "TCon" PWild PWild) () (EVar "True")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "&&" (EApp (EVar "monoClosed") (EVar "a")) (EApp (EVar "monoClosed") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "&&" (EApp (EVar "monoClosed") (EVar "a")) (EApp (EVar "monoClosed") (EVar "b")))) (arm (PCon "TEff" PWild) () (EVar "True")) (arm (PCon "TAuth" PWild) () (EVar "True")) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoClosed") (EVar "a")))))
(DTypeSig true "schemeBodyOf" (TyFun (TyCon "Scheme") (TyCon "Mono")))
(DFunDef false "schemeBodyOf" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (EVar "body"))
(DTypeSig true "monoHeadIsDecl" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoHeadIsDecl" ((PVar "m")) (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PCon "HkRigid" PWild)) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "anyConcreteHead" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "anyConcreteHead" ((PVar "args")) (EApp (EApp (EVar "anyListM") (ELam ((PVar "m")) (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "m"))))) (EVar "args")))
(DTypeSig true "schemeIds" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "schemeIds" ((PCon "Forall" (PVar "ids") PWild PWild PWild PWild PWild)) (EVar "ids"))
(DTypeSig true "findTvName" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "findTvName" (PWild (PList)) (EVar "None"))
(DFunDef false "findTvName" ((PVar "id") (PCons (PTuple (PVar "n") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id")) (EApp (EVar "Some") (EVar "n")) (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "rest")))))
(DTypeSig false "monoSpineHeadIsCon" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "monoSpineHeadIsCon" ((PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "monoSpineHeadIsCon") (EVar "a"))) (arm (PCon "TCon" PWild PWild) () (EVar "True")) (arm (PCon "TRigid" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "unrigidSig" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Tyvar"))) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "unrigidSig" ((PVar "sigCells") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TRigid" (PVar "n")) () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "sigStandIn") (EVar "c")) (EVar "n")))) (EVar "sigCells")) (arm (PCons (PVar "c") PWild) () (EApp (EVar "TVar") (EVar "c"))) (arm (PList) () (EApp (EVar "TRigid") (EVar "n"))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EVar "eff")) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "b")))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EVar "a"))) (EVar "q"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "abstractSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "abstractSlotIds" ((PList)) (EListLit))
(DFunDef false "abstractSlotIds" ((PCons (PVar "mono") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "::" (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "abstractSlotIds") (EVar "rest")))) (arm PWild () (EApp (EVar "abstractSlotIds") (EVar "rest")))))
(DTypeSig true "declaredOblArgOk" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "declaredOblArgOk" ((PVar "isBound") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "isBound") (EApp (EVar "tyvarId") (EVar "cell")))) (arm PWild () (EApp (EApp (EVar "allList") (EVar "isBound")) (EApp (EVar "monoTyvarIds") (EVar "m"))))))
(DTypeSig true "oblArgKey" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "oblArgKey" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "++" (EBinOp "++" (ELit (LString "v")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "cell"))))) (ELit (LString ".")))) (arm (PCon "TCon" (PVar "name") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString "")))) (arm (PCon "TRigid" (PVar "name")) () (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString "")))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EMethodRef "display") (EApp (EVar "oblArgKey") (EVar "a")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "oblArgKey") (EVar "b")))) (ELit (LString "")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f")) (EApp (EMethodRef "display") (EApp (EVar "oblArgKey") (EVar "a")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "oblArgKey") (EVar "b")))) (ELit (LString "")))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "oblArgKey") (EVar "a"))) (arm PWild () (ELit (LString "*")))))
(DTypeSig true "exactReturnRequestOfGoal" (TyFun (TyCon "Obligation") (TyApp (TyCon "Option") (TyCon "MethodReturnRequest"))))
(DFunDef false "exactReturnRequestOfGoal" ((PVar "goal")) (EMatch (EFieldAccess (EVar "goal") "oPayload") (arm (PCon "GPSite" PWild PWild (PCon "SKExactReturn" PWild (PVar "request"))) () (EApp (EVar "Some") (EVar "request"))) (arm PWild () (EVar "None"))))
(DTypeSig true "firstOrZero" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "firstOrZero" ((PList)) (ELit (LInt 0)))
(DFunDef false "firstOrZero" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "allMethodParamsMentioned" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "allMethodParamsMentioned" ((PList) PWild) (EVar "True"))
(DFunDef false "allMethodParamsMentioned" ((PCons (PVar "param") (PVar "rest")) (PVar "ty")) (EBinOp "&&" (EApp (EApp (EVar "argMentions") (EListLit (EVar "param"))) (EApp (EVar "stripTyConstraints") (EVar "ty"))) (EApp (EApp (EVar "allMethodParamsMentioned") (EVar "rest")) (EVar "ty"))))
(DTypeSig true "implDeclsWithReqs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "implDeclsWithReqs" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "implDeclWithReqs")) (EVar "prog")))
(DTypeSig false "implDeclWithReqs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "implDeclWithReqs" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclWithReqs") (EVar "d")))
(DFunDef false "implDeclWithReqs" ((PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" None)) true)) (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin")))) (EVar "tys") (EVar "reqs"))))
(DFunDef false "implDeclWithReqs" (PWild) (EListLit))
