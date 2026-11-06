# META
source_lines=1403
stages=DESUGAR,MARK
# SOURCE
-- tc_mark: the mark pass: rewrite a binding group's method references into marked occurrences
-- before inference. It holds the marker over expressions (`rewriteArgScoped` and its arms), the mark
-- sets and their derivation (`markSetsOf`, `markDictNames`, `methodMarkCtx`, `moduleMarkCtx`), the
-- group and tail-declaration entries (`markGroupClauses`, `markTailDecls`,
-- `markRecursiveOccurrences`), the module's begin and finish rows (`beginModuleMarking`,
-- `finishModuleMarking`), and the write-back of marked clauses over the declarations
-- (`rebuildGroupDecls`).
--
-- Spec: DICT section 4 (occurrence half), section 5, section 8 I7; SHADOW-SEMANTICS S1-NS, S2-DECL.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_groups`, `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_stamp`, `tc_module`.

import types.tc_types.{
  GraphCtx(..),
  MarkSets(..),
  SiteCell(..),
  ArgRw,
  MarkCtx(..),
  ModuleCtx(..),
  ModuleMarking(..),
  PreludeMarkFacts,
  RecDictApp(..),
  ScopedMember(..),
  TcEnv(..),
  BareLocals(..),
  SpellCtx(..),
  ModuleSeed(..),
  ScopeClass(..),
}
import types.tc_mono.{
  patVarsListTc,
  patVarsTc,
  propParamNamesTc,
}
import types.tc_env.{
  declTopFnNames,
  depExportsStandalone,
  depExportsUnknown,
  funDefs,
  graphPubDefiners,
  ifaceExportsIndex,
  importedBindings,
  namesToSet,
  allIfaceMethodNames,
}
import types.tc_scope.{
  aliasDictNames,
  aliasMethodSpellings,
  withAliasMethodNames,
}
import types.tc_decls.{
  importerDefiners,
}
import types.tc_solve.{
  isLocalAbsName,
  returnPosMethodNames,
}
import types.tc_shadow.{
  isPreludeMid,
  nameableIfaceMethodSet,
}
import types.tc_grants.{clausesOf, evOrdinal, grantNameIn}
import frontend.ast.{
  Section(..),
  Arm(..),
  Decl(..),
  DoStmt(..),
  EvId(..),
  Expr(..),
  FieldAssign(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  ImplMethod(..),
  InterpPart(..),
  LetBind(..),
  MethodDefault(..),
  Pat(..),
  Route(..),
  isUnminted,
  UsePath(..),
}
import types.repr.{
  Mono(..),
  Scheme(..),
}
import support.ordmap.{
  omEmpty,
  omFromNames,
  omFromPairs,
  omHasKey,
  omInsert,
  omLookup,
  OrdMap,
  omSize,
}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  filterList,
  lookupAssoc,
  startsWith,
}
import types.chain_key.{
  constrainedSigName,
}
import list.{
  reverse,
}
import map as IdMap
import types.private_mangle.{
  mangledName,
  unitSurfaces,
}
import frontend.visibility.{
  ModuleExports(..),
  coreExports,
  useModId,
  writtenImportsOf,
}
import frontend.name_scope.{
  ImportedSurface(..),
  NameBinding(..),
  NameRung(..),
  NameScope,
  NameTarget(..),
  bareBinding,
  importedSurfaces,
  nameScopeOf,
}
import types.tc_foreign.{
  declExternNames,
}
import types.tc_occurrence.{
  argDispatchIndicesById,
  argDispatchIndices,
  ctorHeadShaped,
  freshEvId,
  indexWithSlot,
  isGrantOnlyEv,
  methodConstraintNames,
  mintMethodCellRaw,
  pushRecDictAppGoal,
}

-- #2705: mint the cells for one `EMethodAt` node and return the id the node
-- carries.  [seed] is the pre-pass seed (the mangled definer-shadow symbol, or
-- ""): a non-empty seed becomes the `RLocal <seed> []` fallback the stampers and
-- every seed reader (`routeLocalSym`) expect to find on the dispatch cell.
mintMethodCell : ModuleCtx -> String -> EvId
mintMethodCell mctx seed =
  mintMethodCellRaw
    mctx
    ""
    None
    (if seed == "" then RNone else RLocal seed [])
    []

-- Mint the cell for one operator site, starting unrouted, and return its id.
mintOpSite : ModuleCtx -> Unit -> EvId
mintOpSite mctx _ = mintSite mctx (OpSite (Ref RNone))

-- Mint the cells for one numeric literal site: an unset float and an unrouted
-- `fromInt` route.
mintLitSite : ModuleCtx -> Unit -> EvId
mintLitSite mctx _ = mintSite mctx (LitSite (Ref None) (Ref RNone))

-- Mint the cell for one field access or record update, starting with the unknown
-- head "".
mintHeadSite : ModuleCtx -> Unit -> EvId
mintHeadSite mctx _ = mintSite mctx (HeadSite (Ref ""))

-- [ev] if it already has a site, else a freshly minted one: a body re-marked after
-- inference keeps the ids inference wrote through.
mintedOr : (Unit -> EvId) -> EvId -> EvId
mintedOr mint ev = if isUnminted ev then mint () else ev

mintSite : ModuleCtx -> SiteCell -> EvId
mintSite mctx cell =
  let ev = freshEvId mctx ()
  let g = mctx.mcGraph.graphRun
  let i = evOrdinal ev - g.evBase
  let arr = indexWithSlot g.siteCells i
  match arrayGetUnsafe i arr
    None => arraySetUnsafe i (Some (ev, cell)) arr
    Some _ => panic "site cell #\{intToString (evOrdinal ev)} minted twice"
  ev

freshLocalAbsName : GraphCtx -> String -> String
freshLocalAbsName gctx x =
  let st = gctx.graphRun.localAbs
  let (mid, k) = st.lasNext.value
  let name = "\{x}$\{mid}$\{intToString k}$lb"
  st.lasNext := (mid, k + 1)
  st.lasMinted := name :: st.lasMinted.value
  name

-- Mint a use node for a name that takes no dictionary, so its grants have an
-- identity to be recorded under.
mintGrantOnly : ModuleCtx -> String -> Expr
mintGrantOnly mctx n =
  let ev = freshEvId mctx ()
  let st = mctx.mcGraph.graphRun.grants
  st.gsGrantOnly := IdMap.set (evOrdinal ev) () st.gsGrantOnly.value
  EDictAt n ev

-- A grant-only use that became a dictionary application (a recursive use of a
-- member its group just promoted).
unmarkGrantOnly : GraphCtx -> EvId -> Unit
unmarkGrantOnly gctx ev =
  let st = gctx.graphRun.grants
  st.gsGrantOnly := IdMap.delete (evOrdinal ev) st.gsGrantOnly.value

-- the user program's top-level functions carrying a `=>` constraint in their
-- signature — the set the graph driver dictionary-passes
export
constrainedSigNames : List Decl -> List String
constrainedSigNames prog = flatMap constrainedSigName prog

-- The `ArgRw` hook that records nothing: every marker but the group-recursive one
-- (`markRecursiveOccurrences`) reads the dict application's route out of the goal
-- inference pushes for it, so it has nothing to do at mark time.
noDictHook : String -> EvId -> Unit
noDictHook _ _ = ()

-- Mint one dict-application node and tell the hook about it.
mintDictAt : ModuleCtx -> (String -> EvId -> Unit) -> String -> Expr
mintDictAt mctx onDict n =
  let ev = freshEvId mctx ()
  onDict n ev
  EDictAt n ev

-- rewrite a decl body with its own parameters seeded into the bound set.  Mirrors
-- desugar's mapDecl coverage exactly (DFunDef / DInterface / DImpl / DProp /
-- DTest / DAttrib; everything else — incl. DLetGroup — left unchanged),
-- so with the emit path off this would degenerate to the same node set mapProg
-- visits.
prePassDeclScoped : ModuleCtx -> ArgRw -> Decl -> Decl
prePassDeclScoped mctx rw (DFunDef pub n ps e site bid) =
  DFunDef
    pub
    n
    ps
    (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)
    site
    bid
prePassDeclScoped mctx rw (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (prePassIfaceMethodScoped mctx rw) methods }
prePassDeclScoped mctx rw (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (prePassImplMethodScoped mctx rw) methods }
prePassDeclScoped mctx rw (DProp pub name params body) =
  DProp
    pub
    name
    params
    (rewriteArgScoped mctx rw (boundOfList (propParamNamesTc params)) body)
prePassDeclScoped mctx rw (DTest pub name body) =
  DTest pub name (rewriteArgScoped mctx rw omEmpty body)
prePassDeclScoped mctx rw (DAttrib attrs d) =
  DAttrib attrs (prePassDeclScoped mctx rw d)
-- Top-level `let rec … with …` (DLetGroup): mapDecl/the catch-all skip its bodies,
-- so a constrained-fn occurrence inside a group body would never be rewritten to
-- EDictAt/EMethodAt → its call site gets no dict route → the dict-passed callee is
-- under-applied at eval.  Rewrite each clause body with that clause's params scoped
-- in, exactly like the DFunDef arm.
prePassDeclScoped mctx rw (DLetGroup pub binds) =
  DLetGroup pub (map (prePassLetBindScoped mctx rw) binds)
prePassDeclScoped _mctx _ d = d

prePassLetBindScoped : ModuleCtx -> ArgRw -> LetBind -> LetBind
prePassLetBindScoped mctx rw (LetBind n clauses site bid) =
  LetBind n (map (prePassFunClauseScoped mctx rw) clauses) site bid

prePassFunClauseScoped : ModuleCtx -> ArgRw -> FunClause -> FunClause
prePassFunClauseScoped mctx rw (FunClause ps e) =
  FunClause ps (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

prePassIfaceMethodScoped : ModuleCtx -> ArgRw -> IfaceMethod -> IfaceMethod
prePassIfaceMethodScoped _mctx _ (IfaceMethod n ty None mloc) =
  IfaceMethod n ty None mloc
prePassIfaceMethodScoped mctx rw (IfaceMethod n ty (Some (MethodDefault ps e)) mloc) =
  IfaceMethod
    n
    ty
    (Some
      (MethodDefault
        ps
        (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)))
    mloc

prePassImplMethodScoped : ModuleCtx -> ArgRw -> ImplMethod -> ImplMethod
prePassImplMethodScoped mctx rw (ImplMethod n ps e) =
  ImplMethod n ps (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

-- #1031: `bound` is an OrdMap-backed SET (name -> ()), not a `List String`
-- scanned by `contains` — a deep local nesting (N sequential lets, a reference
-- to an outer binding) made `contains n bound` an O(depth) scan per EVar,
-- O(depth²) over the body (the `scoperefs` shape).  `boundInsert`/`boundOfList`
-- extend it; membership is `omHasKey`.  A name maps to "" for an ordinary binder
-- and to the renamed binder for a candidate let binder (`letPatRename`).
boundInsert : List String -> OrdMap String -> OrdMap String
boundInsert [] b = b
boundInsert (n :: rest) b = boundInsert rest (omInsert n "" b)

-- A let binder that `isNonexpansive` may generalize: every such binder must be able
-- to take dictionary parameters, since generalizing one over a class predicate without
-- abstracting it would share one dictionary between uses at different types.  This
-- runs before inference, without the constructor table, so it over-approximates
-- `isCtorAppSpine` by the head's spelling alone.  A candidate that does not generalize
-- with predicates abstracts nothing and its uses stay plain variables.
localAbsCandidate : Expr -> Bool
localAbsCandidate (ELoc _ e) = localAbsCandidate e
localAbsCandidate (EDoOrigin _ e) = localAbsCandidate e
localAbsCandidate (EAnnot e _) = localAbsCandidate e
localAbsCandidate (EHeadAnnot e _) = localAbsCandidate e
localAbsCandidate (ELit _) = True
localAbsCandidate (EVar _) = True
localAbsCandidate (EVarId _ _) = True
localAbsCandidate (EMethodAt _ _ _) = True
localAbsCandidate (EDictAt _ _) = True
localAbsCandidate (EMethodRef _) = True
localAbsCandidate (ELam _ _) = True
localAbsCandidate (ETuple es) = allList localAbsCandidate es
localAbsCandidate (EListLit es) = allList localAbsCandidate es
localAbsCandidate (app@(EApp _ _)) = localAbsCtorSpine app
localAbsCandidate (ERecordCreate _ fs) =
  allList
    (fa => match fa
      FieldAssign _ e => localAbsCandidate e)
    fs
localAbsCandidate _ = False

localAbsCtorSpine : Expr -> Bool
localAbsCtorSpine (ELoc _ e) = localAbsCtorSpine e
localAbsCtorSpine (EDoOrigin _ e) = localAbsCtorSpine e
localAbsCtorSpine (EApp f x) = localAbsCtorSpine f && localAbsCandidate x
localAbsCtorSpine (EVar name) = ctorHeadShaped name
localAbsCtorSpine (EVarId name _) = ctorHeadShaped name
localAbsCtorSpine _ = False

localAbsCandidateBind : LetBind -> Bool
localAbsCandidateBind (LetBind _ clauses _ _) =
  anyList localAbsCandidateClause clauses

localAbsCandidateClause : FunClause -> Bool
localAbsCandidateClause (FunClause [] body) = localAbsCandidate body
localAbsCandidateClause (FunClause _ _) = True

-- A candidate let binder is renamed to a name no other binder carries, so the
-- binder and every occurrence of it name ONE binding for the rest of the pipeline;
-- the bound map sends the source name to the new one, and its occurrences are
-- marked `EDictAt` so a use can carry the dictionaries the binder abstracts.  A
-- name that is already one (a tree marked a second time) is an ordinary binder.
letPatRename : GraphCtx -> Pat -> Expr -> OrdMap String -> (Pat, OrdMap String)
letPatRename gctx (PVar x l bid) e1 b
  | localAbsCandidate e1 && not (isLocalAbsName x) =
    let fresh = freshLocalAbsName gctx x
    (PVar fresh l bid, omInsert x fresh b)
letPatRename _gctx p _ b = (p, boundInsert (patVarsTc p) b)

bindsRename : GraphCtx ->
  List LetBind ->
  OrdMap String ->
  (List LetBind, OrdMap String)
bindsRename _gctx [] b = ([], b)
bindsRename gctx ((bind@(LetBind n clauses site bid)) :: rest) b =
  let (n2, b1) =
    if localAbsCandidateBind bind && not (isLocalAbsName n) then
      let fresh = freshLocalAbsName gctx n
      (fresh, omInsert n fresh b)
    else
      (n, boundInsert [n] b)
  let (rest2, b2) = bindsRename gctx rest b1
  (LetBind n2 clauses site bid :: rest2, b2)

boundOfList : List String -> OrdMap String
boundOfList ns = boundInsert ns omEmpty

-- the core scope-threaded rewrite.  `bound` is the set of names in scope as
-- locals at this node.  At an EVar: the rp arm is scope-blind (unchanged); the
-- arg-position (`an`) and constrained-fn (`dn`) arms fire only when the name is
-- NOT shadowed by a local.  Binders
-- (ELam/ELet/ELetGroup/EMatch arms/EBlock/EDo + the where/do/guard
-- binders) extend `bound`; every other node recurses into its children with the
-- same `bound`.
rewriteArgScoped : ModuleCtx -> ArgRw -> OrdMap String -> Expr -> Expr
rewriteArgScoped mctx (ArgRw rp dn an sm onDict granted) bound (EVar n)
  -- P0-18: `n` is a MANGLED definer-shadow standalone (`<mid>__size`).  Mark it
  -- `EMethodAt` with the BARE dispatch name (so `implFor` finds the impl when the
  -- receiver has one) and seed the route's `RLocal <n>` fallback with the mangled
  -- symbol (so a no-impl receiver still reaches the standalone `@mdk_<mid>__size`).
  | omHasKey n bound = match omLookup n bound
    Some "" => EVar n
    Some renamed => EDictAt renamed (freshEvId mctx ())
    None => EVar n
  | otherwise = match lookupAssoc n sm
    Some bare => EMethodAt bare n (mintMethodCell mctx n)
    None =>
      if omHasKey n rp || omHasKey n an then
        EMethodAt n "" (mintMethodCell mctx "")
      else if omHasKey n dn then
        mintDictAt mctx onDict n
      else if granted n then
        mintGrantOnly mctx n
      else
        EVar n
-- A grant-only use of a member its group has just promoted becomes that member's
-- dictionary application, under the same id.
rewriteArgScoped mctx (ArgRw _ dn _ _ onDict _) _ (EDictAt n ev)
  | isGrantOnlyEv mctx.mcGraph ev && omHasKey n dn =
    unmarkGrantOnly mctx.mcGraph ev
    onDict n ev
    EDictAt n ev
  | otherwise = EDictAt n ev
-- No `EVarId` arm: every marker runs BEFORE resolve's binding-id stamp (the Flat
-- arm's whole-program pre-pass, and the schedule's per-group `markGroupClauses` →
-- `stampGroupClauses`), so a stamped occurrence never reaches this rewrite.
-- binders
rewriteArgScoped mctx rw bound (ELam ps body) =
  ELam ps (rewriteArgScoped mctx rw (boundInsert (patVarsListTc ps) bound) body)
rewriteArgScoped mctx rw bound (ELet m r p e1 e2) =
  let (p2, after) = letPatRename mctx.mcGraph p e1 bound
  let b1 = if r then after else bound
  ELet
    m
    r
    p2
    (rewriteArgScoped mctx rw b1 e1)
    (rewriteArgScoped mctx rw after e2)
rewriteArgScoped mctx rw bound (ELetGroup binds e2) =
  let (binds2, bnd) = bindsRename mctx.mcGraph binds bound
  ELetGroup
    (map (rewriteArgLetBind mctx rw bnd) binds2)
    (rewriteArgScoped mctx rw bnd e2)
rewriteArgScoped mctx rw bound (EMatch e0 arms) =
  EMatch
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgArm mctx rw bound) arms)
rewriteArgScoped mctx rw bound (EBlock stmts) =
  EBlock (rewriteArgStmts mctx rw bound stmts)
rewriteArgScoped mctx rw bound (EDo d stmts) =
  EDo d (rewriteArgStmts mctx rw bound stmts)
-- non-binder composites: recurse children with the same bound
rewriteArgScoped mctx rw bound (ELoc l e) =
  ELoc l (rewriteArgScoped mctx rw bound e)
rewriteArgScoped mctx rw bound (EDoOrigin l e) =
  EDoOrigin l (rewriteArgScoped mctx rw bound e)
rewriteArgScoped mctx rw bound (EApp f x) =
  EApp (rewriteArgScoped mctx rw bound f) (rewriteArgScoped mctx rw bound x)
rewriteArgScoped mctx rw bound (EIf c t e) =
  EIf
    (rewriteArgScoped mctx rw bound c)
    (rewriteArgScoped mctx rw bound t)
    (rewriteArgScoped mctx rw bound e)
-- An operator site is minted once: `markRecursiveOccurrences` re-marks bodies
-- inference already wrote through these ids, so a minted id passes through.
rewriteArgScoped mctx rw bound (EBinOp op l r ev) =
  let l2 = rewriteArgScoped mctx rw bound l
  let r2 = rewriteArgScoped mctx rw bound r
  EBinOp op l2 r2 (mintedOr (mintOpSite mctx) ev)
rewriteArgScoped mctx rw bound (EUnOp op x ev) =
  let x2 = rewriteArgScoped mctx rw bound x
  EUnOp op x2 (mintedOr (mintOpSite mctx) ev)
rewriteArgScoped mctx rw bound (EInfix op l r) =
  EInfix
    op
    (rewriteArgScoped mctx rw bound l)
    (rewriteArgScoped mctx rw bound r)
rewriteArgScoped mctx rw bound (EFieldAccess e0 n ev) =
  EFieldAccess
    (rewriteArgScoped mctx rw bound e0)
    n
    (mintedOr (mintHeadSite mctx) ev)
rewriteArgScoped mctx rw bound (ETuple es) =
  ETuple (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EListLit es) =
  EListLit (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EArrayLit es) =
  EArrayLit (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (ERangeList lo hi i) =
  ERangeList
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (ERangeArray lo hi i) =
  ERangeArray
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (ESlice e0 lo hi i) =
  ESlice
    (rewriteArgScoped mctx rw bound e0)
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (EIndex e0 i) =
  EIndex (rewriteArgScoped mctx rw bound e0) (rewriteArgScoped mctx rw bound i)
rewriteArgScoped mctx rw bound (EAnnot e0 t) =
  EAnnot (rewriteArgScoped mctx rw bound e0) t
rewriteArgScoped mctx rw bound (EHeadAnnot e0 t) =
  EHeadAnnot (rewriteArgScoped mctx rw bound e0) t
rewriteArgScoped mctx rw bound (ERecordCreate n fs) =
  ERecordCreate n (map (rewriteArgField mctx rw bound) fs)
rewriteArgScoped mctx rw bound (ERecordUpdate e0 fs ev) =
  ERecordUpdate
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgField mctx rw bound) fs)
    (mintedOr (mintHeadSite mctx) ev)
rewriteArgScoped mctx rw bound (EVariantUpdate c e0 fs) =
  EVariantUpdate
    c
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgField mctx rw bound) fs)
rewriteArgScoped mctx rw bound (EStringInterp parts) =
  EStringInterp (map (rewriteArgInterp mctx rw bound) parts)
rewriteArgScoped mctx rw bound (EGuards arms) =
  EGuards (map (rewriteArgGuardArm mctx rw bound) arms)
rewriteArgScoped mctx rw bound (ESection (SecRight op e0)) =
  ESection (SecRight op (rewriteArgScoped mctx rw bound e0))
rewriteArgScoped mctx rw bound (ESection (SecLeft e0 op)) =
  ESection (SecLeft (rewriteArgScoped mctx rw bound e0) op)
rewriteArgScoped mctx rw bound (EMapLit n kvs) =
  EMapLit n (map (rewriteArgKv mctx rw bound) kvs)
rewriteArgScoped mctx rw bound (ESetLit n es) =
  ESetLit n (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EAsPat x sub) =
  EAsPat x (rewriteArgScoped mctx rw bound sub)
rewriteArgScoped mctx rw bound (EOrPat es) =
  EOrPat (map (rewriteArgScoped mctx rw bound) es)
-- Numeric literals carry a site id that is minted here, like operators.
rewriteArgScoped mctx _ _ (ENumLit n ev lx) =
  ENumLit n (mintedOr (mintLitSite mctx) ev) lx
rewriteArgScoped mctx _ _ (EWideLit hi lo ev lx) =
  EWideLit hi lo (mintedOr (mintOpSite mctx) ev) lx
-- leaves (ELit / EMethodRef / EDictApp / EVarAt / EMethodAt / EDictAt / SecBare)
rewriteArgScoped _mctx _ _ e = e

rewriteArgField : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  FieldAssign ->
  FieldAssign
rewriteArgField mctx rw bound (FieldAssign n e) =
  FieldAssign n (rewriteArgScoped mctx rw bound e)

rewriteArgKv : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  (Expr, Expr) ->
  (Expr, Expr)
rewriteArgKv mctx rw bound (k, v) =
  (rewriteArgScoped mctx rw bound k, rewriteArgScoped mctx rw bound v)

rewriteArgInterp : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  InterpPart ->
  InterpPart
rewriteArgInterp _mctx _ _ (InterpStr s) = InterpStr s
rewriteArgInterp mctx rw bound (InterpExpr e) =
  InterpExpr (rewriteArgScoped mctx rw bound e)

rewriteArgLetBind : ModuleCtx -> ArgRw -> OrdMap String -> LetBind -> LetBind
rewriteArgLetBind mctx rw bound (LetBind n clauses site bid) =
  LetBind n (map (rewriteArgFunClause mctx rw bound) clauses) site bid

rewriteArgFunClause : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  FunClause ->
  FunClause
rewriteArgFunClause mctx rw bound (FunClause ps body) =
  FunClause
    ps
    (rewriteArgScoped mctx rw (boundInsert (patVarsListTc ps) bound) body)

-- a match/function arm: the pattern binds for the guards + body; a `| p <- e`
-- guard binds for later guards + the body (threaded left-to-right).
rewriteArgArm : ModuleCtx -> ArgRw -> OrdMap String -> Arm -> Arm
rewriteArgArm mctx rw bound (Arm p gs body) =
  let b0 = boundInsert (patVarsTc p) bound
  let (gs2, bnd) = rewriteArgGuards mctx rw b0 gs
  Arm p gs2 (rewriteArgScoped mctx rw bnd body)

rewriteArgGuardArm : ModuleCtx -> ArgRw -> OrdMap String -> GuardArm -> GuardArm
rewriteArgGuardArm mctx rw bound (GuardArm gs body) =
  let (gs2, bnd) = rewriteArgGuards mctx rw bound gs
  GuardArm gs2 (rewriteArgScoped mctx rw bnd body)

rewriteArgGuards : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  List Guard ->
  (List Guard, OrdMap String)
rewriteArgGuards _mctx _ bound [] = ([], bound)
rewriteArgGuards mctx rw bound ((GBool e) :: rest) =
  let e2 = rewriteArgScoped mctx rw bound e
  let (rest2, bnd) = rewriteArgGuards mctx rw bound rest
  (GBool e2 :: rest2, bnd)
rewriteArgGuards mctx rw bound ((GBind p e) :: rest) =
  let e2 = rewriteArgScoped mctx rw bound e
  let (rest2, bnd) =
    rewriteArgGuards mctx rw (boundInsert (patVarsTc p) bound) rest
  (GBind p e2 :: rest2, bnd)

-- do/block statements: a DoBind/DoLet pattern binds for SUBSEQUENT
-- statements (a recursive DoLet also for its own RHS).
rewriteArgStmts : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  List DoStmt ->
  List DoStmt
rewriteArgStmts _mctx _ _ [] = []
rewriteArgStmts mctx rw bound ((DoExpr e) :: rest) =
  DoExpr (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest
rewriteArgStmts mctx rw bound ((DoBind p e) :: rest) =
  DoBind p (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw (boundInsert (patVarsTc p) bound) rest
rewriteArgStmts mctx rw bound ((DoLet m r p e site) :: rest) =
  let (p2, after) = letPatRename mctx.mcGraph p e bound
  let b1 = if r then after else bound
  DoLet m r p2 (rewriteArgScoped mctx rw b1 e) site
    :: rewriteArgStmts mctx rw after rest
rewriteArgStmts mctx rw bound ((DoAssign x e) :: rest) =
  DoAssign x (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest
rewriteArgStmts mctx rw bound ((DoFieldAssign x fs e) :: rest) =
  DoFieldAssign x fs (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest

-- The `=>`-constrained-function dict-name set `elaborateModules` hands to prePass and
-- dictPass, which must see the same set: the prelude's constrained names, then the
-- full `constrainedSigNames` of every module (not the return-position subset:
-- dictPass gives a leading dict parameter to every function whose signature is
-- constrained, so a mark set that omitted `quad : Monoid a => a -> a` would leave
-- its call sites unmarked).  The prelude's names are the one prelude-only input, so
-- a driver with a prelude key derives them once per process.
moduleDictNames : List String -> List (String, List Decl) -> List String
moduleDictNames preludeNames modules =
  preludeNames ++ constrainedSigNames (flatMap snd modules)

argRwOf : MarkCtx ->
  OrdMap Unit ->
  (String -> EvId -> Unit) ->
  (String -> Bool) ->
  ArgRw
argRwOf mc dn onDict granted = ArgRw mc.mcRp dn mc.mcAn mc.mcSm onDict granted

-- Mark the declarations of one module that are not binding groups (impl, default,
-- prop and test bodies) with the module's final dict-name set.  Binding
-- groups were marked on the schedule (`markGroupClauses`) and are left alone.
export
markTailDecls : ModuleCtx ->
  MarkCtx ->
  OrdMap Unit ->
  (String -> Bool) ->
  List Decl ->
  List Decl
markTailDecls mctx mc dn granted decls =
  map (markTailDecl mctx (argRwOf mc dn noDictHook granted)) decls

markTailDecl : ModuleCtx -> ArgRw -> Decl -> Decl
markTailDecl _mctx _ (d@(DFunDef _ _ _ _ _ _)) = d
markTailDecl _mctx _ (d@(DLetGroup _ _)) = d
markTailDecl mctx rw (DAttrib attrs d) = DAttrib attrs (markTailDecl mctx rw d)
markTailDecl mctx rw d = prePassDeclScoped mctx rw d

markClauseWith : ModuleCtx -> ArgRw -> (List Pat, Expr) -> (List Pat, Expr)
markClauseWith mctx rw (ps, e) =
  (ps, rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

-- `allDecls` IS `coreDecls ++ flatMap snd modules` -- the envelope's
-- `deAllDecls`, see `declEnvDeclsOf` -- and every list split on that seam here is
-- a `flatMap` over decls (`returnPosMethodNames`, `methodConstraintNames`,
-- `argDispatchIndices`, `argDispatchIndicesById`), so `f (xs ++ ys)` is
-- `f xs ++ f ys` for each.  That is what makes the prelude half separable WITHOUT
-- changing the order any of them produces, and the order is observable: `dedup`
-- keeps the first occurrence.
export
markSetsOf : GraphCtx ->
  PreludeMarkFacts ->
  List Decl ->
  List (String, List Decl) ->
  List Decl ->
  MarkSets
markSetsOf gctx pmf coreDecls modules allDecls =
  -- P0-18: recover the definer-shadow map from the (already-mangled on the emit path)
  -- decls BEFORE marking/typecheck reads it.  Empty on the un-mangled path.  Set once
  -- here; per-module `freshModuleCtx` (in checkModuleFullImpl) does NOT clear it.
  let units = ("core", coreDecls) :: modules
  let userDecls = flatMap snd modules
  let shadowMap = computeMangledShadowMap allDecls units
  gctx.mangledShadowMapRef := shadowMap
  gctx.argDispatchIdxByIdRef :=
    pmf.pmfArgDispatchById ++ argDispatchIndicesById userDecls
  let rpNames = pmf.pmfReturnPos ++ returnPosMethodNames userDecls
  let markSharedNames =
    dedup
      (rpNames ++ pmf.pmfMethodConstraints ++ methodConstraintNames userDecls)
  let graphShadowNames =
    buildStandaloneShadowsGraph shadowMap allDecls userDecls
  let ms = MarkSets {
    msMarkRpNames = dedup (markSharedNames ++ graphShadowNames),
    msMarkSharedNames = markSharedNames,
    msGraphShadowNames = graphShadowNames,
    msArgNames = map fst (pmf.pmfArgDispatch ++ argDispatchIndices userDecls),
    msCoreShadowMap = coreShadowMapFor gctx coreDecls shadowMap,
    msBareDictNames = dedup (moduleDictNames pmf.pmfConstrainedNames modules),
    msUnits = units,
    msScopeClass = scopeClassesOf units,
  }
  gctx.markSetsRef := Some ms
  ms

-- What each user module's scope binds a bare name to at rungs 2 to 4, from the
-- units' export surfaces (`unitSurfaces`, one `coreExports` per drive) and the
-- imports each module's source wrote (`writtenImportsOf`).  The prelude stands
-- for rung 5 without its values, so a name only the prelude binds answers
-- `ScopeOther` and keeps its marking; its interfaces stay, so a prelude method a
-- module re-exports without its interface is still a method.  Core itself has
-- no scope here: it marks its own names without a scope class.
scopeClassesOf : List (String, List Decl) -> String -> String -> ScopeClass
scopeClassesOf units =
  let surfaces = unitSurfaces units
  let byMid = omFromPairs surfaces omEmpty
  let prelude = optionOrElse (_ => coreExports []) (lookupAssoc "core" surfaces)
  let outer = { prelude | expValueOrigins = [] }
  let scopes =
    omFromPairs
      (map (scopeOfUnit byMid outer) (filterList (not << isCoreUnit) units))
      omEmpty
  mid n => match omLookup mid scopes
    Some scope => scopeClassOf (bareBinding scope n)
    None => ScopeOther

isCoreUnit : (String, List Decl) -> Bool
isCoreUnit (mid, _) = mid == "core"

scopeOfUnit : OrdMap ModuleExports ->
  ModuleExports ->
  (String, List Decl) ->
  (String, NameScope)
scopeOfUnit byMid outer (mid, decls) = (mid, unitScope byMid outer decls)

unitScope : OrdMap ModuleExports -> ModuleExports -> List Decl -> NameScope
unitScope byMid prelude decls =
  let written = writtenImportsOf decls
  nameScopeOf
    written
    (flatMap (importedSurfaces (mid => omLookup mid byMid)) written)
    prelude

scopeClassOf : Option NameBinding -> ScopeClass
scopeClassOf (Some (Bound RungPrelude _)) = ScopeOther
scopeClassOf (Some (Bound _ (TargetValue _ _))) = ScopeValue
scopeClassOf (Some (Bound _ (TargetMethod _ _ _))) = ScopeMethod
scopeClassOf _ = ScopeOther

-- What module [mid]'s scope binds bare [n] to at rungs 2 to 4, once the drive's
-- mark sets exist.
export
scopeClassIn : GraphCtx -> String -> String -> ScopeClass
scopeClassIn gctx mid n = match gctx.markSetsRef.value
  Some ms => ms.msScopeClass mid n
  None => ScopeOther

-- The dict-name set `dictPass` consumes: [names] (the bare set plus every promotion
-- the graph made) and its import aliases across every module.  The same names, per
-- module, are what `beginModuleMarking` marked with — the def side and the call side
-- must agree on this set or the callee is under-applied (`unbound identifier:
-- $dict_…`, the Phase-134 shape).
--
-- IMPORT ALIASING: the marker rewrites a call site `EVar n` into a dict application
-- only when `n` is in the dict-name set — a set of DEFINITION names.  An aliased call
-- site writes the LOCAL name, so unless the alias locals are added the call is never
-- marked, receives no dict arguments, and silently UNDER-APPLIES: `check` stays
-- green and `run` dies downstream with a type-confused value.
export
markDictNames : GraphCtx ->
  List String ->
  List Decl ->
  List (String, List Decl) ->
  List String
markDictNames gctx names coreDecls modules =
  dedup
    (names
      ++ aliasDictNames
        (importerDefiners gctx)
        names
        (("core", coreDecls) :: modules)
        modules)

-- Mark one binding group's clauses (in the stored, newest-first order the map keeps)
-- with the dict-name set as it stands when the schedule reaches the group.  A use
-- of a member, or of a name whose scheme in [env] quantifies an authority, is
-- given a grant identity: a member's scheme is not known until the group closes.
export
markGroupClauses : ModuleMarking ->
  TcEnv ->
  List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
markGroupClauses mm env members grouped =
  let own = omFromNames members omEmpty
  mapGroupClauses
    (markClauseWith
      env.teDyn.dcModule
      (argRwOf mm.mmCtx mm.mmDictSet.value noDictHook (n =>
        omHasKey n own || grantNameIn env n)))
    members
    grouped

export
mapGroupClauses : ((List Pat, Expr) -> (List Pat, Expr)) ->
  List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
-- The map keeps a name's clauses newest-first (`groupClausesGo`); `f` is applied in
-- SOURCE order (`clausesOf`) so the evidence ids it mints follow the source, and the
-- result is stored back in the map's own order.
mapGroupClauses _ [] grouped = grouped
mapGroupClauses f (m :: rest) grouped =
  mapGroupClauses
    f
    rest
    (omInsert m (reverse (map f (clausesOf m grouped))) grouped)

-- At group close: the members this group promoted join the dict-name set, and the
-- group's own occurrences of them — the recursive calls, which were still `EVar`
-- when the group was marked because their callee had not generalized — become
-- dict applications.  Each carries the goal `inferDictAtFound`'s recursive arm
-- pushes for a callee that is a placeholder of the current group (`RecDictApp`,
-- realized at the graph-end drain against the callee's now-registered slots): the
-- callee's placeholder mono is the occurrence's instantiated type, the enclosing
-- member is the clause's own.  That arm is the ONLY effect the recursive arm has
-- beyond returning the instantiated type, which the `EVar` path returned too, so
-- rewriting after inference leaves the group's inference unchanged.
export
markRecursiveOccurrences : ModuleCtx ->
  ModuleMarking ->
  List (String, Mono) ->
  List ScopedMember ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
markRecursiveOccurrences mctx mm placeholders scopedMembers grouped =
  -- `promotedRef` is this module's promoted names so far (cumulative within the
  -- module); a member already in the dict-name set — a bare-name collision with a
  -- signatured graph name or an earlier module's promotion — was marked before
  -- inference and needs nothing here.
  let promoted = omFromNames mctx.mcCells.promotedRef.value omEmpty
  let fresh =
    filterList
      (m => omHasKey m promoted && not (omHasKey m mm.mmDictSet.value))
      (map (member => member.smName) scopedMembers)
  match fresh
    [] => grouped
    _ =>
      mm.mmDictSet := omFromNames fresh mm.mmDictSet.value
      recMarkMembers
        mctx
        (omFromNames fresh omEmpty)
        placeholders
        scopedMembers
        grouped

recMarkMembers : ModuleCtx ->
  OrdMap Unit ->
  List (String, Mono) ->
  List ScopedMember ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
recMarkMembers _mctx _ _ [] grouped = grouped
recMarkMembers mctx dn placeholders (member :: rest) grouped =
  let m = member.smName
  let onDict =
    callee ev =>
      pushRecDictAppGoal
        mctx.mcGraph
        (RecDictApp
          (Ref [])
          callee
          m
          (placeholderMonoOf callee placeholders)
          member.smScope
          ev)
  let rw = ArgRw omEmpty dn omEmpty [] onDict (_ => False)
  recMarkMembers
    mctx
    dn
    placeholders
    rest
    (mapGroupClauses (markClauseWith mctx rw) [m] grouped)

placeholderMonoOf : String -> List (String, Mono) -> Mono
placeholderMonoOf callee placeholders = match lookupAssoc callee placeholders
  Some v => v
  None =>
    panic "markRecursiveOccurrences: \{callee} is not a member of the group"

-- Write each group's marked clauses back over the declarations that produced them.
-- `funDefs` flattens `DFunDef` clauses and `DLetGroup` bindings in declaration
-- order and `clausesOf` returns a name's clauses in that order, so consuming them
-- head-first as the declarations are walked restores every clause to its own slot.
-- The arms below are `funDefs`' arms, and must stay that set: a declaration shape
-- `funDefs` collects clauses from but this walk passes through would drop those
-- clauses' marks from the returned tree without a panic (the reverse direction
-- panics in `popMarkedClause`).
export
rebuildGroupDecls : OrdMap (List (List Pat, Expr)) -> List Decl -> List Decl
rebuildGroupDecls grouped prog = fst (rebuildGroupDeclsGo grouped omEmpty prog)

rebuildGroupDeclsGo : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  List Decl ->
  (List Decl, OrdMap (List (List Pat, Expr)))
rebuildGroupDeclsGo _ pending [] = ([], pending)
rebuildGroupDeclsGo grouped pending ((DFunDef pub n _ _ site bid) :: rest) =
  let ((ps, e), pending2) = popMarkedClause grouped pending n
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (DFunDef pub n ps e site bid :: ds, pending3)
rebuildGroupDeclsGo grouped pending ((DLetGroup pub binds) :: rest) =
  let (binds2, pending2) = rebuildLetBinds grouped pending binds
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (DLetGroup pub binds2 :: ds, pending3)
rebuildGroupDeclsGo grouped pending ((DAttrib attrs d) :: rest) =
  let (inner, pending2) = rebuildGroupDeclsGo grouped pending [d]
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (map (d2 => DAttrib attrs d2) inner ++ ds, pending3)
rebuildGroupDeclsGo grouped pending (d :: rest) =
  let (ds, pending2) = rebuildGroupDeclsGo grouped pending rest
  (d :: ds, pending2)

rebuildLetBinds : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  List LetBind ->
  (List LetBind, OrdMap (List (List Pat, Expr)))
rebuildLetBinds _ pending [] = ([], pending)
rebuildLetBinds grouped pending ((LetBind n clauses site bid) :: rest) =
  let (clauses2, pending2) = rebuildFunClauses grouped pending n clauses
  let (binds, pending3) = rebuildLetBinds grouped pending2 rest
  (LetBind n clauses2 site bid :: binds, pending3)

rebuildFunClauses : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  String ->
  List FunClause ->
  (List FunClause, OrdMap (List (List Pat, Expr)))
rebuildFunClauses _ pending _ [] = ([], pending)
rebuildFunClauses grouped pending n (_ :: rest) =
  let ((ps, e), pending2) = popMarkedClause grouped pending n
  let (cs, pending3) = rebuildFunClauses grouped pending2 n rest
  (FunClause ps e :: cs, pending3)

-- The next unconsumed marked clause of [n]: `pending` holds the clauses not yet
-- written back, in source order, minted from `clausesOf` on first use.
popMarkedClause : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  String ->
  ((List Pat, Expr), OrdMap (List (List Pat, Expr)))
popMarkedClause grouped pending n =
  let remaining = match omLookup n pending
    Some cs => cs
    None => clausesOf n grouped
  match remaining
    c :: cs => (c, omInsert n cs pending)
    [] => panic "rebuildGroupDecls: no marked clause left for \{n}"

-- C5: graph-wide standalone-shadow names — every top-level funDef name in [userDecls]
-- (the user modules, NOT core) that is also an interface method name anywhere in
-- [allDecls].  Used by the MARK pass to rewrite such occurrences to EMethodAt (so the
-- route ref exists for resolveRLocalSites to stamp).  Excludes core's own decls as the
-- funDef source so core's elaboration (no standalone shadows there) is untouched.
-- P0-18: recover, per (module, iface-method) pair, the mangled standalone symbol the
-- mangler produced for a definer-shadow funDef.  Forward-constructs `mangledName mid
-- method` (using the KNOWN mid — exact, not lossy prefix-stripping) and checks it
-- against the module's actual funDef names; a hit is a `(mangledSymbol ↦ bareMethod)`
-- entry.  On the un-mangled path no funDef matches → [] → every consumer unchanged.
export
computeMangledShadowMap : List Decl ->
  List (String, List Decl) ->
  List (String, String)
computeMangledShadowMap allDecls units =
  -- DEDUPED: `allIfaceMethodNames` walks every `DInterface` in the graph and a method
  -- name declared by two interfaces appears twice, so an undeduped list mints the SAME
  -- `(sym ↦ bare)` row twice per unit.  The rows are identical, so no reader's answer
  -- changes; what changes is the size of the table every reader below walks or indexes.
  let methodNames = dedup (allIfaceMethodNames allDecls)
  flatMap (unitMangledShadows methodNames) units

-- The unit's funDef names are an INDEX, not a list: this probes once per interface
-- method, so a `contains` here is O(methods x funDefs) — a shape where both grow
-- together (N interfaces beside N top-level bindings) makes it quadratic.  Same
-- treatment as `prePassDictArg`'s name sets (#2189).
-- #2809: the bare row.  Mangling now runs AFTER elaboration, so a definer shadow's
-- funDef carries the name its author wrote and the forward-constructed `<mid>__m` matches
-- nothing.  The row is what `rewriteArgScoped`'s `sm` arm reads to seed the occurrence
-- with its standalone SYMBOL, and that symbol is what the later rename moves
-- (`private_mangle`'s `EMethodAt` seed arm and `mangleRoute`) into the emitted direct
-- call.  Without it the route names the bare METHOD, whose define the rename has already
-- moved, and the emitter calls a symbol DCE pruned: `use of undefined value
-- '@mdk_orElse'`, on the compiler's own `frontend.parser`.
-- On the bare row `sym == bare`, so `moduleSpellsShadowBare`'s definer arm admits it in
-- the module that defines the standalone and its import arm in a module that spells the
-- bare name -- the same two admitting cases #1684 ruled for the mangled row.
-- The prelude unit contributes no row: shadow-SEMANTICS S1-PRELUDE (a) puts the implicit
-- prelude in neither half of S1's standalone operand, so no `core.mdk` occurrence is a
-- user interface method's shadow -- the asymmetry `appendUniverseAccums` states, and the
-- direction #2153's `core__not ↦ not` incident was paid for.
unitMangledShadows : List String -> (String, List Decl) -> List (String, String)
unitMangledShadows methodNames (mid, decls) =
  let fns = omFromNames (map fst (funDefs decls)) omEmpty
  flatMap
    (m =>
      let sym = mangledName mid m
      if omHasKey sym fns then
        [(sym, m)]
      else if not (isPreludeMid mid) && omHasKey m fns then
        [(m, m)]
      else
        [])
    methodNames

export
buildStandaloneShadowsGraph : List (String, String) ->
  List Decl ->
  List Decl ->
  List String
buildStandaloneShadowsGraph sm allDecls userDecls =
  -- INDEX, not a list: this probes once per user funDef, so a `contains` over the
  -- interface-method names is O(funDefs x methods) — quadratic on a program whose
  -- interface count and top-level binding count grow together.
  let methodNames = omFromNames (allIfaceMethodNames allDecls) omEmpty
  let fns = dedup (map fst (funDefs userDecls))
  let direct = filter (n => omHasKey n methodNames) fns
  -- P0-18: written for the order where the EMIT path's funDef names were MANGLED
  -- (`<mid>__toList`), which the `direct` name-intersection misses; the map recovered
  -- them so the prePass marked their occurrences `EMethodAt`.
  -- #2809: no path reaches this with mangled funDefs any more, and the map is non-empty
  -- on ALL of them — the rows are `(name ↦ name)`, so this filter selects the funDef
  -- names `direct` already selected and the union is unchanged.  The header 25 lines up
  -- states that retirement.  The filter stays because it recovers a genuinely mangled row
  -- if one appears (a hand-written `<mid>__toList` mints one), and `dedup` makes the
  -- redundancy free.
  let mangled = filter (n => isSome (lookupAssoc n sm)) fns
  dedup (direct ++ mangled)

-- ── #2153: S1's `nameable in M` for the PRELUDE unit ─────────────────────────
-- `moduleMarkCtx` filters the definer-shadow map at the CONSUMING module.
-- `core` is the one unit that never goes through that filter: its context is built
-- from the RAW graph-wide map.  That is
-- fine for `rpNames`/`argNames` — they are BARE method names, and core's references to its
-- own standalones are all mangled `core__<n>` by the time this runs, so neither set can
-- match one (the P0-21 argument `elaborateModules` states at `markRpNames`).  It is NOT
-- fine for the shadow map, which is keyed by exactly those mangled symbols.
--
-- MEASURED (#2153): `computeMangledShadowMap` walks `("core", coreDecls)` against the
-- GRAPH-WIDE method-name list, so a USER module declaring `interface Ifc c where not : …`
-- mints `core__not ↦ not`.  `rewriteArgScoped`'s `sm` arm then rewrote CORE's OWN
-- `core__not` occurrence (in `neq`, `notElem`, a core prop, …) to `EMethodAt "not"`, and
-- core's env has no `not` — so `medaka build` died `E-PANIC: unbound method: not` on a
-- program `check` and `run` both accept, and even on one that never mentions the method.
-- That is the whole 22-name FAIL_BUILD class in `test/prelude_shadow_census.ledger`: a
-- prelude standalone reaches this arm only when ANOTHER prelude decl references it, which
-- is the very split `frontend/marker.mdk`'s `droppablePreludeFns` names (`clamp` yes,
-- `count`/`find` no) — and it is why the fix `types/private_mangle.mdk` landed for the
-- module's OWN occurrences could not reach these: the surviving occurrence is core's.
--
-- The rule applied is S1's own: an interface method declared in a USER module is not
-- nameable in `core`, so no `core.mdk` occurrence can be its shadow.  Same predicate and
-- same fail-OPEN guard as the per-module filter above — sited beside it so the two stay
-- auditable as a SET rather than as two independent answers to one question.
--
-- #2809 added the second conjunct, and its absence was measured.  With mangling moved
-- after elaboration a definer-shadow row is `(name ↦ name)`, so `map`'s standalone
-- `toList` and the prelude's OWN `Foldable.toList` occurrence in a specialized default
-- body (`impl Foldable Option`'s `isEmpty`) spell the same key: the nameable test alone
-- admitted the row, `rewriteArgScoped`'s `sm` arm seeded core's method occurrence with
-- `RLocal "toList"`, and the emitter turned a dispatch into a direct call to a symbol
-- core does not define — `use of undefined value '@mdk_toList'`, i.e. #2153's incident
-- with the bare spelling as the key.  `moduleSpellsShadowBare` is the SAME occurrence-
-- spelling test the per-module filter applies, so core is scoped by one rule, not two.
export
coreShadowMapFor : GraphCtx ->
  List Decl ->
  List (String, String) ->
  List (String, String)
coreShadowMapFor gctx coreProg shadowMap
  | omSize (ifaceExportsIndex gctx ()) == 0 = shadowMap
  | otherwise =
    let nameable = nameableIfaceMethodSet gctx coreProg
    let sc = spellCtxOf gctx coreProg
    filterList
      (e =>
        omHasKey (snd e) nameable && moduleSpellsShadowBare sc (fst e) (snd e))
      shadowMap

-- ── #1684: S1's STANDALONE operand, at the OCCURRENCE spelling ───────────────
-- The two filters above answer S1's INTERFACE operand (`nameable in M`) and nothing
-- else.  That is sufficient on the un-mangled check/run path, where an occurrence
-- carries the spelling the author wrote — but NOT on the emit path, where
-- `types/private_mangle.mdk` has already collapsed BOTH spellings of an imported
-- standalone onto ONE symbol:
--
--   import amod.{shrink}  → `shrink`    ⎫
--   import amod as A      → `A.shrink`  ⎭ → both become `EVar "amod__shrink"`
--
-- `computeMangledShadowMap` then recovers `amod__shrink ↦ shrink` from the DEFINING
-- module's funDefs and `rewriteArgScoped`'s `sm` arm rewrites EVERY occurrence of that
-- symbol to `EMethodAt "shrink"` — including the alias-qualified one, which was never
-- an S1 occurrence at all.  §1.0's standalone-operand row is *"defined in `M` or
-- imported into `M`"*, and `import amod as A` imports the standalone into `M` under the
-- local name `A.shrink`; bare `shrink` is bound by no import form there, so it names
-- nothing in `M` and can shadow nothing in `M`.
--
-- MEASURED (#1684, S0): a two-file program whose only interface is the PRELUDE's
-- `Arbitrary` — no `impl` and no `interface` written anywhere in it — had `A.shrink 5`
-- emitted as a call to `@mdk_impl_Int_shrink`, so the built binary printed
-- `Arbitrary.shrink`'s list default `[0, 2]` while `run` printed the standalone's `6`.
-- Both at exit 0, no diagnostic on any channel.
--
-- So the emit path must reconstruct what the mangle erased: admit a mangled shadow
-- symbol only where `M` actually spells its BARE name.  Two admitting cases, and the
-- test is over IMPORT FORMS rather than over the symbol's origin module, so a name
-- reaching `M` through a re-export chain (whose `useModId` is the re-exporter,
-- not the definer) is admitted exactly as it is today:
--   * `M` DEFINES the symbol itself — the definer shadow (P0-18), unchanged.
--   * some import form in `M` binds the LOCAL name `bare`: a member list naming it, or
--     a wildcard.  A module alias (`Some []`) and a member alias (`{size as sz}`, whose
--     local is `sz`) bind it under a different spelling, so neither admits it — and
--     both then agree with what the un-mangled path already does with that spelling.
-- Empty shadowMap ⇒ `lookupAssoc` misses ⇒ True ⇒ the check/run path is untouched.
shadowSymSpelledBare : SpellCtx -> List (String, String) -> String -> Bool
shadowSymSpelledBare sc sm n = match lookupAssoc n sm
  None => True
  Some bare => moduleSpellsShadowBare sc n bare

spellCtxOf : GraphCtx -> List Decl -> SpellCtx
spellCtxOf gctx prog = SpellCtx {
  scTopFns = declTopFnNames prog,
  scBare = declBareLocals gctx prog BareLocals { blAll = False, blSet = [] },
  scCorePfx = mangledName "core" "",
}

moduleSpellsShadowBare : SpellCtx -> String -> String -> Bool
moduleSpellsShadowBare sc sym bare =
  contains sym sc.scTopFns
    || startsWith sc.scCorePfx sym && sym == "\{sc.scCorePfx}\{bare}"
    || bareLocalBound sc.scBare bare

bareLocalBound : BareLocals -> String -> Bool
bareLocalBound bl bare = bl.blAll || contains bare bl.blSet

declBareLocals : GraphCtx -> List Decl -> BareLocals -> BareLocals
declBareLocals _gctx [] acc = acc
declBareLocals gctx ((DAttrib _ d) :: rest) acc =
  declBareLocals gctx rest (declBareLocals gctx [d] acc)
declBareLocals gctx ((DUse _ path _) :: rest) acc =
  declBareLocals gctx rest (formBareLocals gctx path acc)
declBareLocals gctx (_ :: rest) acc = declBareLocals gctx rest acc

-- one form's contribution.  `None` is the wildcard `import m.*`, which binds every export
-- of `m` under its own name; a module alias (`Some []`) and a member alias
-- (`{size as sz}`, whose local is `sz`) bind under a different spelling and so contribute
-- that spelling, not `size`.  Each contribution is intersected with what the dependency
-- actually EXPORTS AS A STANDALONE — S1's second conjunct, stated on
-- `depExportsStandalone` below.
formBareLocals : GraphCtx -> UsePath -> BareLocals -> BareLocals
formBareLocals gctx path acc =
  let depId = useModId path
  match importedBindings path
    None =>
      if depExportsUnknown gctx depId then
        { acc | blAll = True }
      else
        { acc | blSet = map fst (graphPubDefiners gctx depId) ++ acc.blSet }
    Some bindings => { acc |
      blSet =
        filterList (l => depExportsStandalone gctx depId l) (map snd bindings)
          ++ acc.blSet,
    }

-- the BARE interface-method name a (possibly mangled) standalone-shadow symbol stands for.
-- Identity on the un-mangled run/check path, where the map is empty.
shadowBareName : List (String, String) -> String -> String
shadowBareName sm n = optionOr n (lookupAssoc n sm)

-- Method nameability and standalone availability are independent. The wrapper
-- admits standalone routes only for this module's definitions or actual imported
-- standalone descriptors, never for private functions elsewhere in the graph.
methodMarkCtx : GraphCtx -> MarkSets -> String -> List Decl -> MarkCtx
methodMarkCtx gctx ms "" coreProg
  | omSize (ifaceExportsIndex gctx ()) == 0 = MarkCtx {
    mcRp = omFromNames ms.msMarkRpNames omEmpty,
    mcAn = omFromNames ms.msArgNames omEmpty,
    mcSm = ms.msCoreShadowMap,
  }
  | otherwise =
    let nameable = nameableIfaceMethodSet gctx coreProg
    let keep = n => omHasKey n nameable
    MarkCtx {
      mcRp = omFromNames (filterList keep ms.msMarkRpNames) omEmpty,
      mcAn = omFromNames (filterList keep ms.msArgNames) omEmpty,
      mcSm = ms.msCoreShadowMap,
    }
methodMarkCtx gctx ms _ prog
  -- fail OPEN when the graph index is absent, for the reason stated on
  -- `nameableIfaceShadows`: an unscoped mark set is today's behaviour, an empty one is the
  -- S4/#410 class.
  -- Guard the index this arm actually reads: the body reads `meIfaceExports`, so the
  -- guard tests that and not its sibling `meExports` — testing one while reading the
  -- other is an implicit conjunction of exactly the kind `registry_keying_ratchet`
  -- exists to forbid.  Run with an empty iface index, the other arm would filter out
  -- every imported and prelude shadow name, failing closed into the S4/#410 class that
  -- `nameableIfaceShadows` says must never happen.
  | omSize (ifaceExportsIndex gctx ()) == 0 =
    let aliasRows = aliasMethodSpellings gctx prog
    MarkCtx {
      mcRp =
        withAliasMethodNames
          aliasRows
          (omFromNames
            (dedup (ms.msMarkSharedNames ++ ms.msGraphShadowNames))
            omEmpty),
      mcAn = withAliasMethodNames aliasRows (omFromNames ms.msArgNames omEmpty),
      mcSm = gctx.mangledShadowMapRef.value,
    }
  | otherwise =
    -- S1-NS (b), the closure invariant.  The spec requires the predicate deciding
    -- SHADOW-HOOD to be a SUPERSET of the one deciding DISPATCH ELIGIBILITY, and rules two
    -- different predicates at the two sites non-conformant whichever way they differ.
    --
    -- The invariant is about inputs to dispatch, not about sets or selectors.
    -- `rewriteArgScoped` dispatches on `rp`, `an` AND `sm`, so every one of those
    -- inputs must be filtered, `rpNames` included: an unfiltered `rpNames` makes
    -- dispatch-eligibility a strict superset of shadow-hood, and a return-position
    -- method of a non-nameable interface then runs with no diagnostic (`run` gave 777
    -- against a built binary of 42, both exit 0).
    --
    -- THE ENUMERATION, so the next reader checks the SET rather than trusting a sentence.
    -- Every input `rewriteArgScoped` can turn into an `EMethodAt` is filtered here:
    --   * `rpNames`   — return-position method names AND method-level-constraint method
    --                   names (`markSharedNames` concatenates both).  BOTH are interface
    --                   METHOD names — each walks `DInterface`'s `methods` — so both are the
    --                   same kind of set as `argNames` and both are filtered.
    --   * `shadowNames` — via `shadowBareName`, because on the emit path these are mangled.
    --   * `argNames`  — arg-position dispatch indices.
    --   * `shadowMap` — the emit-path peer of `argNames`.
    -- `dictNames` is the ONE input deliberately NOT filtered, and it is not an input to
    -- dispatch at all: it produces `EDictAt`, a dict application of a `=>`-constrained
    -- FUNCTION, which selects no impl from a receiver.  Filtering it would drop a dict
    -- argument and UNDER-APPLY the callee (`unbound identifier: $dict_…`, the Phase-134
    -- shape) — so it is disjoint by node kind, not by name, and that is probed rather than
    -- argued (see `test/shadow_fixtures/`'s return-position cells and the PR body).
    let nameable = nameableIfaceMethodSet gctx prog
    let keep = n => omHasKey n nameable
    let shadowMap = gctx.mangledShadowMapRef.value
    -- The occurrence-spelling context, taken ONCE for this module rather than rebuilt
    -- inside each filter below — per row it was most of this cell's measured
    -- regression; see `SpellCtx`.
    let sc = spellCtxOf gctx prog
    let aliasRows = aliasMethodSpellings gctx prog
    MarkCtx {
      mcRp =
        withAliasMethodNames
          aliasRows
          (omFromNames
            (dedup
              (filterList keep ms.msMarkSharedNames
                ++ filterList
                  (n =>
                    omHasKey (shadowBareName shadowMap n) nameable
                      && shadowSymSpelledBare sc shadowMap n)
                  ms.msGraphShadowNames))
            omEmpty),
      mcAn =
        withAliasMethodNames
          aliasRows
          (omFromNames (filterList keep ms.msArgNames) omEmpty),
      mcSm =
        filterList
          (e =>
            omHasKey (snd e) nameable
              && moduleSpellsShadowBare sc (fst e) (snd e))
          shadowMap,
    }

-- `moduleMarkCtx ms mid prog`: core (`mid == ""`) is marked with the unsplit set and
-- the core-scoped shadow map (#2153).  A user module gets the split set, scoped by the
-- filter below.
--
-- CORE'S rp/arg SETS ARE S1-FILTERED TOO, and the argument that they need not be is
-- retired.  It read: "core's references to its own standalones are all mangled
-- `core__<n>` by the time this runs, so neither set can match one."  #2809 moved
-- mangling AFTER elaboration, so core's references now carry the names its author
-- wrote and a USER interface method spelled like a core standalone matches them.
-- MEASURED on `test/prelude_shadow_census.ledger`'s own probe shape — `interface Ifc c
-- where identity : c -> Int` beside `impl Ifc Int`, in a module that defines no
-- `identity` — `check` and `run` accept and print 1 while `build` died `E-PANIC: no
-- impl of method 'identity' for type 'List'`: core's own `identity` call, on a `List`,
-- had been rewritten to a dispatch on the USER's interface.  Four ledger rows
-- (`identity`, `otherwise`, `arbitraryList`, `arbitraryString`) moved PASS -> FAIL_BUILD
-- that way.  The rule applied is the one `coreShadowMapFor` already applies to the
-- shadow map for the same reason: an interface declared in a USER module is not
-- nameable in `core`, so no `core.mdk` occurrence is one of its method occurrences.
-- Same fail-OPEN guard as `nameableIfaceShadows`: an absent graph index leaves the sets
-- unfiltered rather than emptying them.
export
moduleMarkCtx : GraphCtx ->
  MarkSets ->
  String ->
  List Decl ->
  OrdMap Scheme ->
  MarkCtx
moduleMarkCtx gctx ms mid prog imported =
  let candidates = methodMarkCtx gctx ms mid prog
  let local = namesToSet (declTopFnNames prog) omEmpty
  -- A module's own extern denotes itself wherever the module spells it, as its
  -- own function named like an interface method does (SHADOW-SEMANTICS S2's
  -- definer arm), so its occurrences are never method occurrences.
  let externs = namesToSet (declExternNames prog) omEmpty
  MarkCtx {
    mcRp = IdMap.difference candidates.mcRp externs,
    mcAn = IdMap.difference candidates.mcAn externs,
    mcSm =
      filterList
        (entry => omHasKey (fst entry) local || omHasKey (snd entry) imported)
        candidates.mcSm,
  }

-- [mc] without the names the module's scope binds to a value at rungs 2 to 4.
-- Such a name is an ordinary reference wherever it is written
-- (docs/spec/SHADOW-SEMANTICS.md L5), so no occurrence of it becomes a method
-- occurrence; a name bound to a method, or answered only by the prelude, keeps
-- its marking.
ladderMarkCtx : (String -> ScopeClass) -> MarkCtx -> MarkCtx
ladderMarkCtx scopeOf mc =
  let marked n = scopeOf n /= ScopeValue
  MarkCtx {
    mcRp = IdMap.filterWithKey (n _ => marked n) mc.mcRp,
    mcAn = IdMap.filterWithKey (n _ => marked n) mc.mcAn,
    mcSm = filterList (e => marked (fst e) && marked (snd e)) mc.mcSm,
  }

-- Install the module's marking state at module start.  Reads the graph's mark sets
-- off the driver preamble; a Module arm reached without one is a driver bug, and
-- fails loud rather than marking nothing.
export
beginModuleMarking : ModuleCtx ->
  String ->
  List Decl ->
  OrdMap Int ->
  ModuleSeed ->
  Unit
beginModuleMarking mctx mid prog top seed =
  let ms =
    optionOrPanic
      "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)"
      mctx.mcGraph.markSetsRef.value
  -- Core imports nothing, so the dict names nameable in it are its own `=>`
  -- signatures, the set its `dictPass` gives parameters to.  A user definition that
  -- shares a bare name with a core one is a different definition.
  let known = match mid
    "" => constrainedSigNames prog
    _ => dedup (ms.msBareDictNames ++ mctx.mcGraph.promotionHarvestRef.value)
  let aliases = aliasDictNames (importerDefiners
    mctx.mcGraph) known ms.msUnits [
    (mid, prog),
  ]
  mctx.mcGraph.graphRun.localAbs.lasNext := (mid, 0)
  mctx.mcGraph.graphRun.localAbs.lasMinted := []
  let candidates = moduleMarkCtx mctx.mcGraph ms mid prog seed.msImportedValues
  mctx.mcCells.markingRef := Some ModuleMarking {
    mmCtx = ladderMarkCtx (ms.msScopeClass mid) candidates,
    mmTop = top,
    mmDictSet = Ref (omFromNames (known ++ aliases) omEmpty),
    mmUserNames = omFromNames (declTopFnNames prog) seed.msImportedNames,
    mmExterns = omFromNames (declExternNames prog) seed.msImportedExterns,
  }

-- The module's marked tree: its binding groups' marked clauses written back into the
-- declarations in source order, then the remaining bodies (impl, default, prop,
-- test) marked with the module's final dict-name set — they are inferred
-- after every group, so every promotion the module made is in the set by then.
export
finishModuleMarking : ModuleMarking ->
  TcEnv ->
  OrdMap (List (List Pat, Expr)) ->
  List Decl ->
  List Decl
finishModuleMarking mm env grouped prog =
  markTailDecls
    env.teDyn.dcModule
    mm.mmCtx
    mm.mmDictSet.value
    (grantNameIn env)
    (rebuildGroupDecls grouped prog)
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "MarkSets" true) (mem "SiteCell" true) (mem "ArgRw" false) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "PreludeMarkFacts" false) (mem "RecDictApp" true) (mem "ScopedMember" true) (mem "TcEnv" true) (mem "BareLocals" true) (mem "SpellCtx" true) (mem "ModuleSeed" true) (mem "ScopeClass" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "propParamNamesTc" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declTopFnNames" false) (mem "depExportsStandalone" false) (mem "depExportsUnknown" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ifaceExportsIndex" false) (mem "importedBindings" false) (mem "namesToSet" false) (mem "allIfaceMethodNames" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasDictNames" false) (mem "aliasMethodSpellings" false) (mem "withAliasMethodNames" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "importerDefiners" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false) (mem "returnPosMethodNames" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "isPreludeMid" false) (mem "nameableIfaceMethodSet" false))))
(DUse false (UseGroup ("types" "tc_grants") ((mem "clausesOf" false) (mem "evOrdinal" false) (mem "grantNameIn" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Section" true) (mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "isUnminted" false) (mem "UsePath" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "constrainedSigName" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false) (mem "unitSurfaces" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" true) (mem "coreExports" false) (mem "useModId" false) (mem "writtenImportsOf" false))))
(DUse false (UseGroup ("frontend" "name_scope") ((mem "ImportedSurface" true) (mem "NameBinding" true) (mem "NameRung" true) (mem "NameScope" false) (mem "NameTarget" true) (mem "bareBinding" false) (mem "importedSurfaces" false) (mem "nameScopeOf" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndicesById" false) (mem "argDispatchIndices" false) (mem "ctorHeadShaped" false) (mem "freshEvId" false) (mem "indexWithSlot" false) (mem "isGrantOnlyEv" false) (mem "methodConstraintNames" false) (mem "mintMethodCellRaw" false) (mem "pushRecDictAppGoal" false))))
(DTypeSig false "mintMethodCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "EvId"))))
(DFunDef false "mintMethodCell" ((PVar "mctx") (PVar "seed")) (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (ELit (LString ""))) (EVar "None")) (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "RNone") (EApp (EApp (EVar "RLocal") (EVar "seed")) (EListLit)))) (EListLit)))
(DTypeSig false "mintOpSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintOpSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "OpSite") (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintLitSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EApp (EVar "LitSite") (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintHeadSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintHeadSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "HeadSite") (EApp (EVar "Ref") (ELit (LString ""))))))
(DTypeSig false "mintedOr" (TyFun (TyFun (TyCon "Unit") (TyCon "EvId")) (TyFun (TyCon "EvId") (TyCon "EvId"))))
(DFunDef false "mintedOr" ((PVar "mint") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "mint") (ELit LUnit)) (EVar "ev")))
(DTypeSig false "mintSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SiteCell") (TyCon "EvId"))))
(DFunDef false "mintSite" ((PVar "mctx") (PVar "cell")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "siteCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "ev") (EVar "cell")))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "site cell #")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EVar "ev"))))
(DTypeSig false "freshLocalAbsName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "freshLocalAbsName" ((PVar "gctx") (PVar "x")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoLet false false (PTuple (PVar "mid") (PVar "k")) (EFieldAccess (EFieldAccess (EVar "st") "lasNext") "value")) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "x"))) (ELit (LString "$"))) (EApp (EVar "$core.display") (EVar "mid"))) (ELit (LString "$"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "$lb")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasNext")) (ETuple (EVar "mid") (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasMinted")) (EBinOp "::" (EVar "name") (EFieldAccess (EFieldAccess (EVar "st") "lasMinted") "value")))) (DoExpr (EVar "name"))))
(DTypeSig false "mintGrantOnly" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "mintGrantOnly" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value")))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "unmarkGrantOnly" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "unmarkGrantOnly" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EVar "IdMap.delete") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value"))))))
(DTypeSig true "constrainedSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "constrainedSigName")) (EVar "prog")))
(DTypeSig false "noDictHook" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "noDictHook" (PWild PWild) (ELit LUnit))
(DTypeSig false "mintDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "mintDictAt" ((PVar "mctx") (PVar "onDict") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "prePassDeclScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassIfaceMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassImplMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "propParamNamesTc") (EVar "params")))) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassLetBindScoped") (EVar "mctx")) (EVar "rw"))) (EVar "binds"))))
(DFunDef false "prePassDeclScoped" ((PVar "_mctx") PWild (PVar "d")) (EVar "d"))
(DTypeSig false "prePassLetBindScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "prePassLetBindScoped" ((PVar "mctx") (PVar "rw") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassFunClauseScoped") (EVar "mctx")) (EVar "rw"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "prePassFunClauseScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prePassFunClauseScoped" ((PVar "mctx") (PVar "rw") (PCon "FunClause" (PVar "ps") (PVar "e"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "prePassIfaceMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "_mctx") PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "prePassImplMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))
(DFunDef false "prePassImplMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "boundInsert" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "boundInsert" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsert" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsert") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LString ""))) (EVar "b"))))
(DTypeSig false "localAbsCandidate" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCandidate" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PAs "app" (PCon "EApp" PWild PWild))) (EApp (EVar "localAbsCtorSpine") (EVar "app")))
(DFunDef false "localAbsCandidate" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EVar "localAbsCandidate") (EVar "e")))))) (EVar "fs")))
(DFunDef false "localAbsCandidate" (PWild) (EVar "False"))
(DTypeSig false "localAbsCtorSpine" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCtorSpine" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "localAbsCtorSpine") (EVar "f")) (EApp (EVar "localAbsCandidate") (EVar "x"))))
(DFunDef false "localAbsCtorSpine" ((PCon "EVar" (PVar "name"))) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" ((PCon "EVarId" (PVar "name") PWild)) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" (PWild) (EVar "False"))
(DTypeSig false "localAbsCandidateBind" (TyFun (TyCon "LetBind") (TyCon "Bool")))
(DFunDef false "localAbsCandidateBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "localAbsCandidateClause")) (EVar "clauses")))
(DTypeSig false "localAbsCandidateClause" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" (PList) (PVar "body"))) (EApp (EVar "localAbsCandidate") (EVar "body")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig false "letPatRename" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyCon "Pat") (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "letPatRename" ((PVar "gctx") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "e1") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidate") (EVar "e1")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "x")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "x"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "PVar") (EVar "fresh")) (EVar "l")) (EVar "bid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EVar "fresh")) (EVar "b"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "letPatRename" ((PVar "_gctx") (PVar "p") PWild (PVar "b")) (ETuple (EVar "p") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "b"))))
(DTypeSig false "bindsRename" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "bindsRename" ((PVar "_gctx") (PList) (PVar "b")) (ETuple (EListLit) (EVar "b")))
(DFunDef false "bindsRename" ((PVar "gctx") (PCons (PAs "bind" (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (PVar "rest")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "n2") (PVar "b1")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidateBind") (EVar "bind")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "n")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "n"))) (DoExpr (ETuple (EVar "fresh") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "fresh")) (EVar "b"))))) (ETuple (EVar "n") (EApp (EApp (EVar "boundInsert") (EListLit (EVar "n"))) (EVar "b"))))) (DoLet false false (PTuple (PVar "rest2") (PVar "b2")) (EApp (EApp (EApp (EVar "bindsRename") (EVar "gctx")) (EVar "rest")) (EVar "b1"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n2")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EVar "rest2")) (EVar "b2")))))
(DTypeSig false "boundOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "boundOfList" ((PVar "ns")) (EApp (EApp (EVar "boundInsert") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "rewriteArgScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" (PVar "rp") (PVar "dn") (PVar "an") (PVar "sm") (PVar "onDict") (PVar "granted")) (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound")) (arm (PCon "Some" (PLit (LString ""))) () (EApp (EVar "EVar") (EVar "n"))) (arm (PCon "Some" (PVar "renamed")) () (EApp (EApp (EVar "EDictAt") (EVar "renamed")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "bare")) (EVar "n")) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (EVar "n")))) (arm (PCon "None") () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "rp")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "an"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (ELit (LString ""))) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (ELit (LString "")))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn")) (EApp (EApp (EApp (EVar "mintDictAt") (EVar "mctx")) (EVar "onDict")) (EVar "n")) (EIf (EApp (EVar "granted") (EVar "n")) (EApp (EApp (EVar "mintGrantOnly") (EVar "mctx")) (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" PWild (PVar "dn") PWild PWild (PVar "onDict") PWild) PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn"))) (EBlock (DoExpr (EApp (EApp (EVar "unmarkGrantOnly") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e1")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "bnd")) (EApp (EApp (EApp (EVar "bindsRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgLetBind") (EVar "mctx")) (EVar "rw")) (EVar "bnd"))) (EVar "binds2"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "ev"))) (EBlock (DoLet false false (PVar "x2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "x2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "i"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgInterp") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgGuardArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgKv") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "sub"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintLitSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "_mctx") PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteArgField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))))
(DFunDef false "rewriteArgField" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgKv" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "rewriteArgKv" ((PVar "mctx") (PVar "rw") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "rewriteArgInterp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))))
(DFunDef false "rewriteArgInterp" ((PVar "_mctx") PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "rewriteArgLetBind" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgFunClause") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteArgFunClause" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))))
(DFunDef false "rewriteArgFunClause" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "rewriteArgArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm"))))))
(DFunDef false "rewriteArgArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuardArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))))
(DFunDef false "rewriteArgGuardArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuards" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "rewriteArgGuards" ((PVar "_mctx") PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "rewriteArgStmts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "rewriteArgStmts" ((PVar "_mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "moduleDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleDictNames" ((PVar "preludeNames") (PVar "modules")) (EBinOp "++" (EVar "preludeNames") (EApp (EVar "constrainedSigNames") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules")))))
(DTypeSig false "argRwOf" (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "ArgRw"))))))
(DFunDef false "argRwOf" ((PVar "mc") (PVar "dn") (PVar "onDict") (PVar "granted")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EFieldAccess (EVar "mc") "mcRp")) (EVar "dn")) (EFieldAccess (EVar "mc") "mcAn")) (EFieldAccess (EVar "mc") "mcSm")) (EVar "onDict")) (EVar "granted")))
(DTypeSig true "markTailDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "markTailDecls" ((PVar "mctx") (PVar "mc") (PVar "dn") (PVar "granted") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EVar "mc")) (EVar "dn")) (EVar "noDictHook")) (EVar "granted")))) (EVar "decls")))
(DTypeSig false "markTailDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markTailDecl" ((PVar "_mctx") PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "_mctx") PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PVar "d")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d")))
(DTypeSig false "markClauseWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "markClauseWith" ((PVar "mctx") (PVar "rw") (PTuple (PVar "ps") (PVar "e"))) (ETuple (EVar "ps") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig true "markSetsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeMarkFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkSets")))))))
(DFunDef false "markSetsOf" ((PVar "gctx") (PVar "pmf") (PVar "coreDecls") (PVar "modules") (PVar "allDecls")) (EBlock (DoLet false false (PVar "units") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "userDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "shadowMap") (EApp (EApp (EVar "computeMangledShadowMap") (EVar "allDecls")) (EVar "units"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledShadowMapRef")) (EVar "shadowMap"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "argDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatchById") (EApp (EVar "argDispatchIndicesById") (EVar "userDecls"))))) (DoLet false false (PVar "rpNames") (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfReturnPos") (EApp (EVar "returnPosMethodNames") (EVar "userDecls")))) (DoLet false false (PVar "markSharedNames") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EVar "rpNames") (EFieldAccess (EVar "pmf") "pmfMethodConstraints")) (EApp (EVar "methodConstraintNames") (EVar "userDecls"))))) (DoLet false false (PVar "graphShadowNames") (EApp (EApp (EApp (EVar "buildStandaloneShadowsGraph") (EVar "shadowMap")) (EVar "allDecls")) (EVar "userDecls"))) (DoLet false false (PVar "ms") (ERecordCreate "MarkSets" ((fa "msMarkRpNames" (EApp (EVar "dedup") (EBinOp "++" (EVar "markSharedNames") (EVar "graphShadowNames")))) (fa "msMarkSharedNames" (EVar "markSharedNames")) (fa "msGraphShadowNames" (EVar "graphShadowNames")) (fa "msArgNames" (EApp (EApp (EVar "map") (EVar "fst")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatch") (EApp (EVar "argDispatchIndices") (EVar "userDecls"))))) (fa "msCoreShadowMap" (EApp (EApp (EApp (EVar "coreShadowMapFor") (EVar "gctx")) (EVar "coreDecls")) (EVar "shadowMap"))) (fa "msBareDictNames" (EApp (EVar "dedup") (EApp (EApp (EVar "moduleDictNames") (EFieldAccess (EVar "pmf") "pmfConstrainedNames")) (EVar "modules")))) (fa "msUnits" (EVar "units")) (fa "msScopeClass" (EApp (EVar "scopeClassesOf") (EVar "units")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "markSetsRef")) (EApp (EVar "Some") (EVar "ms")))) (DoExpr (EVar "ms"))))
(DTypeSig false "scopeClassesOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ScopeClass")))))
(DFunDef false "scopeClassesOf" ((PVar "units")) (EBlock (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "units"))) (DoLet false false (PVar "byMid") (EApp (EApp (EVar "omFromPairs") (EVar "surfaces")) (EVar "omEmpty"))) (DoLet false false (PVar "prelude") (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EVar "coreExports") (EListLit)))) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "core"))) (EVar "surfaces")))) (DoLet false false (PVar "outer") (ERecordUpdate (EVar "prelude") ((fa "expValueOrigins" (EListLit))))) (DoLet false false (PVar "scopes") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopeOfUnit") (EVar "byMid")) (EVar "outer"))) (EApp (EApp (EVar "filterList") (EBinOp "<<" (EVar "not") (EVar "isCoreUnit"))) (EVar "units")))) (EVar "omEmpty"))) (DoExpr (ELam ((PVar "mid") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "scopes")) (arm (PCon "Some" (PVar "scope")) () (EApp (EVar "scopeClassOf") (EApp (EApp (EVar "bareBinding") (EVar "scope")) (EVar "n")))) (arm (PCon "None") () (EVar "ScopeOther")))))))
(DTypeSig false "isCoreUnit" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "Bool")))
(DFunDef false "isCoreUnit" ((PTuple (PVar "mid") PWild)) (EBinOp "==" (EVar "mid") (ELit (LString "core"))))
(DTypeSig false "scopeOfUnit" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "NameScope"))))))
(DFunDef false "scopeOfUnit" ((PVar "byMid") (PVar "outer") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "unitScope") (EVar "byMid")) (EVar "outer")) (EVar "decls"))))
(DTypeSig false "unitScope" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "NameScope")))))
(DFunDef false "unitScope" ((PVar "byMid") (PVar "prelude") (PVar "decls")) (EBlock (DoLet false false (PVar "written") (EApp (EVar "writtenImportsOf") (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "nameScopeOf") (EVar "written")) (EApp (EApp (EVar "flatMap") (EApp (EVar "importedSurfaces") (ELam ((PVar "mid")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "byMid"))))) (EVar "written"))) (EVar "prelude")))))
(DTypeSig false "scopeClassOf" (TyFun (TyApp (TyCon "Option") (TyCon "NameBinding")) (TyCon "ScopeClass")))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" (PCon "RungPrelude") PWild))) (EVar "ScopeOther"))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" PWild (PCon "TargetValue" PWild PWild)))) (EVar "ScopeValue"))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" PWild (PCon "TargetMethod" PWild PWild PWild)))) (EVar "ScopeMethod"))
(DFunDef false "scopeClassOf" (PWild) (EVar "ScopeOther"))
(DTypeSig true "scopeClassIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ScopeClass")))))
(DFunDef false "scopeClassIn" ((PVar "gctx") (PVar "mid") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value") (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EFieldAccess (EVar "ms") "msScopeClass") (EVar "mid")) (EVar "n"))) (arm (PCon "None") () (EVar "ScopeOther"))))
(DTypeSig true "markDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "markDictNames" ((PVar "gctx") (PVar "names") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "dedup") (EBinOp "++" (EVar "names") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EApp (EVar "importerDefiners") (EVar "gctx"))) (EVar "names")) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (EVar "modules")))))
(DTypeSig true "markGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "markGroupClauses" ((PVar "mm") (PVar "env") (PVar "members") (PVar "grouped")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "omFromNames") (EVar "members")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EVar "noDictHook")) (ELam ((PVar "n")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "own")) (EApp (EApp (EVar "grantNameIn") (EVar "env")) (EVar "n"))))))) (EVar "members")) (EVar "grouped")))))
(DTypeSig true "mapGroupClauses" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "mapGroupClauses" (PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "mapGroupClauses" ((PVar "f") (PCons (PVar "m") (PVar "rest")) (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EVar "f")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EVar "f")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "grouped"))))
(DTypeSig true "markRecursiveOccurrences" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "markRecursiveOccurrences" ((PVar "mctx") (PVar "mm") (PVar "placeholders") (PVar "scopedMembers") (PVar "grouped")) (EBlock (DoLet false false (PVar "promoted") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (EVar "omEmpty"))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "promoted")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))))) (EApp (EApp (EVar "map") (ELam ((PVar "member")) (EFieldAccess (EVar "member") "smName"))) (EVar "scopedMembers")))) (DoExpr (EMatch (EVar "fresh") (arm (PList) () (EVar "grouped")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "mm") "mmDictSet")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "omEmpty"))) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped")))))))))
(DTypeSig false "recMarkMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "recMarkMembers" ((PVar "_mctx") PWild PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "recMarkMembers" ((PVar "mctx") (PVar "dn") (PVar "placeholders") (PCons (PVar "member") (PVar "rest")) (PVar "grouped")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "onDict") (ELam ((PVar "callee") (PVar "ev")) (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "callee")) (EVar "m")) (EApp (EApp (EVar "placeholderMonoOf") (EVar "callee")) (EVar "placeholders"))) (EFieldAccess (EVar "member") "smScope")) (EVar "ev"))))) (DoLet false false (PVar "rw") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EVar "omEmpty")) (EVar "dn")) (EVar "omEmpty")) (EListLit)) (EVar "onDict")) (ELam (PWild) (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EVar "dn")) (EVar "placeholders")) (EVar "rest")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EVar "mctx")) (EVar "rw"))) (EListLit (EVar "m"))) (EVar "grouped"))))))
(DTypeSig false "placeholderMonoOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "placeholderMonoOf" ((PVar "callee") (PVar "placeholders")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "callee")) (EVar "placeholders")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "markRecursiveOccurrences: ")) (EApp (EVar "$core.display") (EVar "callee"))) (ELit (LString " is not a member of the group")))))))
(DTypeSig true "rebuildGroupDecls" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rebuildGroupDecls" ((PVar "grouped") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "omEmpty")) (EVar "prog"))))
(DTypeSig false "rebuildGroupDeclsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildGroupDeclsGo" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e")) (EVar "site")) (EVar "bid")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending")) (EVar "binds"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "binds2")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DAttrib" (PVar "attrs") (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EListLit (EVar "d")))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "d2")) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")))) (EVar "inner")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "ds") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "d") (EVar "ds")) (EVar "pending2")))))
(DTypeSig false "rebuildLetBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildLetBinds" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildLetBinds" ((PVar "grouped") (PVar "pending") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "clauses2") (PVar "pending2")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending")) (EVar "n")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "binds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses2")) (EVar "site")) (EVar "bid")) (EVar "binds")) (EVar "pending3")))))
(DTypeSig false "rebuildFunClauses" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "rebuildFunClauses" (PWild (PVar "pending") PWild (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildFunClauses" ((PVar "grouped") (PVar "pending") (PVar "n") (PCons PWild (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "cs") (PVar "pending3")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending2")) (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e")) (EVar "cs")) (EVar "pending3")))))
(DTypeSig false "popMarkedClause" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "popMarkedClause" ((PVar "grouped") (PVar "pending") (PVar "n")) (EBlock (DoLet false false (PVar "remaining") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "pending")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EVar "clausesOf") (EVar "n")) (EVar "grouped"))))) (DoExpr (EMatch (EVar "remaining") (arm (PCons (PVar "c") (PVar "cs")) () (ETuple (EVar "c") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "cs")) (EVar "pending")))) (arm (PList) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "rebuildGroupDecls: no marked clause left for ")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "")))))))))
(DTypeSig true "computeMangledShadowMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "computeMangledShadowMap" ((PVar "allDecls") (PVar "units")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EVar "dedup") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls")))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "unitMangledShadows") (EVar "methodNames"))) (EVar "units")))))
(DTypeSig false "unitMangledShadows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "unitMangledShadows" ((PVar "methodNames") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "sym")) (EVar "fns")) (EListLit (ETuple (EVar "sym") (EVar "m"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPreludeMid") (EVar "mid"))) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "fns"))) (EListLit (ETuple (EVar "m") (EVar "m"))) (EListLit))))))) (EVar "methodNames")))))
(DTypeSig true "buildStandaloneShadowsGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildStandaloneShadowsGraph" ((PVar "sm") (PVar "allDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EApp (EVar "omFromNames") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "userDecls"))))) (DoLet false false (PVar "direct") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methodNames")))) (EVar "fns"))) (DoLet false false (PVar "mangled") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))) (EVar "fns"))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "coreShadowMapFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "coreShadowMapFor" ((PVar "gctx") (PVar "coreProg") (PVar "shadowMap")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "shadowMap") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "coreProg"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shadowSymSpelledBare" (TyFun (TyCon "SpellCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "shadowSymSpelledBare" ((PVar "sc") (PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EVar "n")) (EVar "bare")))))
(DTypeSig false "spellCtxOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SpellCtx"))))
(DFunDef false "spellCtxOf" ((PVar "gctx") (PVar "prog")) (ERecordCreate "SpellCtx" ((fa "scTopFns" (EApp (EVar "declTopFnNames") (EVar "prog"))) (fa "scBare" (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "prog")) (ERecordCreate "BareLocals" ((fa "blAll" (EVar "False")) (fa "blSet" (EListLit)))))) (fa "scCorePfx" (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (ELit (LString "")))))))
(DTypeSig false "moduleSpellsShadowBare" (TyFun (TyCon "SpellCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "moduleSpellsShadowBare" ((PVar "sc") (PVar "sym") (PVar "bare")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "sym")) (EFieldAccess (EVar "sc") "scTopFns")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EFieldAccess (EVar "sc") "scCorePfx")) (EVar "sym")) (EBinOp "==" (EVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EFieldAccess (EVar "sc") "scCorePfx"))) (ELit (LString ""))) (EApp (EVar "$core.display") (EVar "bare"))) (ELit (LString "")))))) (EApp (EApp (EVar "bareLocalBound") (EFieldAccess (EVar "sc") "scBare")) (EVar "bare"))))
(DTypeSig false "bareLocalBound" (TyFun (TyCon "BareLocals") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bareLocalBound" ((PVar "bl") (PVar "bare")) (EBinOp "||" (EFieldAccess (EVar "bl") "blAll") (EApp (EApp (EVar "contains") (EVar "bare")) (EFieldAccess (EVar "bl") "blSet"))))
(DTypeSig false "declBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "declBareLocals" ((PVar "_gctx") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "formBareLocals") (EVar "gctx")) (EVar "path")) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "formBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "formBareLocals" ((PVar "gctx") (PVar "path") (PVar "acc")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (ERecordUpdate (EVar "acc") ((fa "blAll" (EVar "True")))) (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EFieldAccess (EVar "acc") "blSet"))))))) (arm (PCon "Some" (PVar "bindings")) () (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EVar "depExportsStandalone") (EVar "gctx")) (EVar "depId")) (EVar "l")))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "bindings"))) (EFieldAccess (EVar "acc") "blSet"))))))))))
(DTypeSig false "shadowBareName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shadowBareName" ((PVar "sm") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))
(DTypeSig false "methodMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkCtx"))))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") (PLit (LString "")) (PVar "coreProg")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msMarkRpNames")) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkRpNames"))) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") PWild (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msMarkSharedNames") (EFieldAccess (EVar "ms") "msGraphShadowNames")))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty")))) (fa "mcSm" (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoLet false false (PVar "shadowMap") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkSharedNames")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "shadowBareName") (EVar "shadowMap")) (EVar "n"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "shadowSymSpelledBare") (EVar "sc")) (EVar "shadowMap")) (EVar "n"))))) (EFieldAccess (EVar "ms") "msGraphShadowNames"))))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty")))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "moduleMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "MarkCtx")))))))
(DFunDef false "moduleMarkCtx" ((PVar "gctx") (PVar "ms") (PVar "mid") (PVar "prog") (PVar "imported")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EVar "methodMarkCtx") (EVar "gctx")) (EVar "ms")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declExternNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcRp")) (EVar "externs"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcAn")) (EVar "externs"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "entry"))) (EVar "local")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "entry"))) (EVar "imported"))))) (EFieldAccess (EVar "candidates") "mcSm"))))))))
(DTypeSig false "ladderMarkCtx" (TyFun (TyFun (TyCon "String") (TyCon "ScopeClass")) (TyFun (TyCon "MarkCtx") (TyCon "MarkCtx"))))
(DFunDef false "ladderMarkCtx" ((PVar "scopeOf") (PVar "mc")) (EBlock (DoLet false true (PVar "marked") (ELam ((PVar "n")) (EBinOp "/=" (EApp (EVar "scopeOf") (EVar "n")) (EVar "ScopeValue")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.filterWithKey") (ELam ((PVar "n") PWild) (EApp (EVar "marked") (EVar "n")))) (EFieldAccess (EVar "mc") "mcRp"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.filterWithKey") (ELam ((PVar "n") PWild) (EApp (EVar "marked") (EVar "n")))) (EFieldAccess (EVar "mc") "mcAn"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EVar "marked") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "marked") (EApp (EVar "snd") (EVar "e")))))) (EFieldAccess (EVar "mc") "mcSm"))))))))
(DTypeSig true "beginModuleMarking" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ModuleSeed") (TyCon "Unit")))))))
(DFunDef false "beginModuleMarking" ((PVar "mctx") (PVar "mid") (PVar "prog") (PVar "top") (PVar "seed")) (EBlock (DoLet false false (PVar "ms") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value"))) (DoLet false false (PVar "known") (EMatch (EVar "mid") (arm (PLit (LString "")) () (EApp (EVar "constrainedSigNames") (EVar "prog"))) (arm PWild () (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "promotionHarvestRef") "value")))))) (DoLet false false (PVar "aliases") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EApp (EVar "importerDefiners") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "known")) (EFieldAccess (EVar "ms") "msUnits")) (EListLit (ETuple (EVar "mid") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasNext")) (ETuple (EVar "mid") (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasMinted")) (EListLit))) (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EApp (EVar "moduleMarkCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ms")) (EVar "mid")) (EVar "prog")) (EFieldAccess (EVar "seed") "msImportedValues"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef")) (EApp (EVar "Some") (ERecordCreate "ModuleMarking" ((fa "mmCtx" (EApp (EApp (EVar "ladderMarkCtx") (EApp (EFieldAccess (EVar "ms") "msScopeClass") (EVar "mid"))) (EVar "candidates"))) (fa "mmTop" (EVar "top")) (fa "mmDictSet" (EApp (EVar "Ref") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "known") (EVar "aliases"))) (EVar "omEmpty")))) (fa "mmUserNames" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedNames"))) (fa "mmExterns" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declExternNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedExterns"))))))))))
(DTypeSig true "finishModuleMarking" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "finishModuleMarking" ((PVar "mm") (PVar "env") (PVar "grouped") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "markTailDecls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EApp (EVar "grantNameIn") (EVar "env"))) (EApp (EApp (EVar "rebuildGroupDecls") (EVar "grouped")) (EVar "prog"))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "MarkSets" true) (mem "SiteCell" true) (mem "ArgRw" false) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "PreludeMarkFacts" false) (mem "RecDictApp" true) (mem "ScopedMember" true) (mem "TcEnv" true) (mem "BareLocals" true) (mem "SpellCtx" true) (mem "ModuleSeed" true) (mem "ScopeClass" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "propParamNamesTc" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declTopFnNames" false) (mem "depExportsStandalone" false) (mem "depExportsUnknown" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ifaceExportsIndex" false) (mem "importedBindings" false) (mem "namesToSet" false) (mem "allIfaceMethodNames" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasDictNames" false) (mem "aliasMethodSpellings" false) (mem "withAliasMethodNames" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "importerDefiners" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false) (mem "returnPosMethodNames" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "isPreludeMid" false) (mem "nameableIfaceMethodSet" false))))
(DUse false (UseGroup ("types" "tc_grants") ((mem "clausesOf" false) (mem "evOrdinal" false) (mem "grantNameIn" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Section" true) (mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "isUnminted" false) (mem "UsePath" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "constrainedSigName" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false) (mem "unitSurfaces" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" true) (mem "coreExports" false) (mem "useModId" false) (mem "writtenImportsOf" false))))
(DUse false (UseGroup ("frontend" "name_scope") ((mem "ImportedSurface" true) (mem "NameBinding" true) (mem "NameRung" true) (mem "NameScope" false) (mem "NameTarget" true) (mem "bareBinding" false) (mem "importedSurfaces" false) (mem "nameScopeOf" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndicesById" false) (mem "argDispatchIndices" false) (mem "ctorHeadShaped" false) (mem "freshEvId" false) (mem "indexWithSlot" false) (mem "isGrantOnlyEv" false) (mem "methodConstraintNames" false) (mem "mintMethodCellRaw" false) (mem "pushRecDictAppGoal" false))))
(DTypeSig false "mintMethodCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "EvId"))))
(DFunDef false "mintMethodCell" ((PVar "mctx") (PVar "seed")) (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (ELit (LString ""))) (EVar "None")) (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "RNone") (EApp (EApp (EVar "RLocal") (EVar "seed")) (EListLit)))) (EListLit)))
(DTypeSig false "mintOpSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintOpSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "OpSite") (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintLitSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EApp (EVar "LitSite") (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintHeadSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintHeadSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "HeadSite") (EApp (EVar "Ref") (ELit (LString ""))))))
(DTypeSig false "mintedOr" (TyFun (TyFun (TyCon "Unit") (TyCon "EvId")) (TyFun (TyCon "EvId") (TyCon "EvId"))))
(DFunDef false "mintedOr" ((PVar "mint") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "mint") (ELit LUnit)) (EVar "ev")))
(DTypeSig false "mintSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SiteCell") (TyCon "EvId"))))
(DFunDef false "mintSite" ((PVar "mctx") (PVar "cell")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "siteCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "ev") (EVar "cell")))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "site cell #")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EVar "ev"))))
(DTypeSig false "freshLocalAbsName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "freshLocalAbsName" ((PVar "gctx") (PVar "x")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoLet false false (PTuple (PVar "mid") (PVar "k")) (EFieldAccess (EFieldAccess (EVar "st") "lasNext") "value")) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "x"))) (ELit (LString "$"))) (EApp (EVar "$core.display") (EVar "mid"))) (ELit (LString "$"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "$lb")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasNext")) (ETuple (EVar "mid") (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasMinted")) (EBinOp "::" (EVar "name") (EFieldAccess (EFieldAccess (EVar "st") "lasMinted") "value")))) (DoExpr (EVar "name"))))
(DTypeSig false "mintGrantOnly" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "mintGrantOnly" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value")))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "unmarkGrantOnly" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "unmarkGrantOnly" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EVar "IdMap.delete") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value"))))))
(DTypeSig true "constrainedSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "constrainedSigName")) (EVar "prog")))
(DTypeSig false "noDictHook" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "noDictHook" (PWild PWild) (ELit LUnit))
(DTypeSig false "mintDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "mintDictAt" ((PVar "mctx") (PVar "onDict") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "prePassDeclScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassIfaceMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassImplMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "propParamNamesTc") (EVar "params")))) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassLetBindScoped") (EVar "mctx")) (EVar "rw"))) (EVar "binds"))))
(DFunDef false "prePassDeclScoped" ((PVar "_mctx") PWild (PVar "d")) (EVar "d"))
(DTypeSig false "prePassLetBindScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "prePassLetBindScoped" ((PVar "mctx") (PVar "rw") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassFunClauseScoped") (EVar "mctx")) (EVar "rw"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "prePassFunClauseScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prePassFunClauseScoped" ((PVar "mctx") (PVar "rw") (PCon "FunClause" (PVar "ps") (PVar "e"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "prePassIfaceMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "_mctx") PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "prePassImplMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))
(DFunDef false "prePassImplMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "boundInsert" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "boundInsert" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsert" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsert") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LString ""))) (EVar "b"))))
(DTypeSig false "localAbsCandidate" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCandidate" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PAs "app" (PCon "EApp" PWild PWild))) (EApp (EVar "localAbsCtorSpine") (EVar "app")))
(DFunDef false "localAbsCandidate" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EVar "localAbsCandidate") (EVar "e")))))) (EVar "fs")))
(DFunDef false "localAbsCandidate" (PWild) (EVar "False"))
(DTypeSig false "localAbsCtorSpine" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCtorSpine" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "localAbsCtorSpine") (EVar "f")) (EApp (EVar "localAbsCandidate") (EVar "x"))))
(DFunDef false "localAbsCtorSpine" ((PCon "EVar" (PVar "name"))) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" ((PCon "EVarId" (PVar "name") PWild)) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" (PWild) (EVar "False"))
(DTypeSig false "localAbsCandidateBind" (TyFun (TyCon "LetBind") (TyCon "Bool")))
(DFunDef false "localAbsCandidateBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "localAbsCandidateClause")) (EVar "clauses")))
(DTypeSig false "localAbsCandidateClause" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" (PList) (PVar "body"))) (EApp (EVar "localAbsCandidate") (EVar "body")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig false "letPatRename" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyCon "Pat") (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "letPatRename" ((PVar "gctx") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "e1") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidate") (EVar "e1")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "x")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "x"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "PVar") (EVar "fresh")) (EVar "l")) (EVar "bid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EVar "fresh")) (EVar "b"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "letPatRename" ((PVar "_gctx") (PVar "p") PWild (PVar "b")) (ETuple (EVar "p") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "b"))))
(DTypeSig false "bindsRename" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "bindsRename" ((PVar "_gctx") (PList) (PVar "b")) (ETuple (EListLit) (EVar "b")))
(DFunDef false "bindsRename" ((PVar "gctx") (PCons (PAs "bind" (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (PVar "rest")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "n2") (PVar "b1")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidateBind") (EVar "bind")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "n")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "n"))) (DoExpr (ETuple (EVar "fresh") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "fresh")) (EVar "b"))))) (ETuple (EVar "n") (EApp (EApp (EVar "boundInsert") (EListLit (EVar "n"))) (EVar "b"))))) (DoLet false false (PTuple (PVar "rest2") (PVar "b2")) (EApp (EApp (EApp (EVar "bindsRename") (EVar "gctx")) (EVar "rest")) (EVar "b1"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n2")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EVar "rest2")) (EVar "b2")))))
(DTypeSig false "boundOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "boundOfList" ((PVar "ns")) (EApp (EApp (EVar "boundInsert") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "rewriteArgScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" (PVar "rp") (PVar "dn") (PVar "an") (PVar "sm") (PVar "onDict") (PVar "granted")) (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound")) (arm (PCon "Some" (PLit (LString ""))) () (EApp (EVar "EVar") (EVar "n"))) (arm (PCon "Some" (PVar "renamed")) () (EApp (EApp (EVar "EDictAt") (EVar "renamed")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "bare")) (EVar "n")) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (EVar "n")))) (arm (PCon "None") () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "rp")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "an"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (ELit (LString ""))) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (ELit (LString "")))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn")) (EApp (EApp (EApp (EVar "mintDictAt") (EVar "mctx")) (EVar "onDict")) (EVar "n")) (EIf (EApp (EVar "granted") (EVar "n")) (EApp (EApp (EVar "mintGrantOnly") (EVar "mctx")) (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" PWild (PVar "dn") PWild PWild (PVar "onDict") PWild) PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn"))) (EBlock (DoExpr (EApp (EApp (EVar "unmarkGrantOnly") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e1")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "bnd")) (EApp (EApp (EApp (EVar "bindsRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgLetBind") (EVar "mctx")) (EVar "rw")) (EVar "bnd"))) (EVar "binds2"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "ev"))) (EBlock (DoLet false false (PVar "x2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "x2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "i"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgInterp") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgGuardArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgKv") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EMethodRef "sub"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintLitSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "_mctx") PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteArgField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))))
(DFunDef false "rewriteArgField" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgKv" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "rewriteArgKv" ((PVar "mctx") (PVar "rw") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "rewriteArgInterp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))))
(DFunDef false "rewriteArgInterp" ((PVar "_mctx") PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "rewriteArgLetBind" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgFunClause") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteArgFunClause" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))))
(DFunDef false "rewriteArgFunClause" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "rewriteArgArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm"))))))
(DFunDef false "rewriteArgArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuardArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))))
(DFunDef false "rewriteArgGuardArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuards" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "rewriteArgGuards" ((PVar "_mctx") PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "rewriteArgStmts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "rewriteArgStmts" ((PVar "_mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "moduleDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleDictNames" ((PVar "preludeNames") (PVar "modules")) (EBinOp "++" (EVar "preludeNames") (EApp (EVar "constrainedSigNames") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules")))))
(DTypeSig false "argRwOf" (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "ArgRw"))))))
(DFunDef false "argRwOf" ((PVar "mc") (PVar "dn") (PVar "onDict") (PVar "granted")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EFieldAccess (EVar "mc") "mcRp")) (EVar "dn")) (EFieldAccess (EVar "mc") "mcAn")) (EFieldAccess (EVar "mc") "mcSm")) (EVar "onDict")) (EVar "granted")))
(DTypeSig true "markTailDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "markTailDecls" ((PVar "mctx") (PVar "mc") (PVar "dn") (PVar "granted") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EVar "mc")) (EVar "dn")) (EVar "noDictHook")) (EVar "granted")))) (EVar "decls")))
(DTypeSig false "markTailDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markTailDecl" ((PVar "_mctx") PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "_mctx") PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PVar "d")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d")))
(DTypeSig false "markClauseWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "markClauseWith" ((PVar "mctx") (PVar "rw") (PTuple (PVar "ps") (PVar "e"))) (ETuple (EVar "ps") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig true "markSetsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeMarkFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkSets")))))))
(DFunDef false "markSetsOf" ((PVar "gctx") (PVar "pmf") (PVar "coreDecls") (PVar "modules") (PVar "allDecls")) (EBlock (DoLet false false (PVar "units") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "userDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "shadowMap") (EApp (EApp (EVar "computeMangledShadowMap") (EVar "allDecls")) (EVar "units"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledShadowMapRef")) (EVar "shadowMap"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "argDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatchById") (EApp (EVar "argDispatchIndicesById") (EVar "userDecls"))))) (DoLet false false (PVar "rpNames") (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfReturnPos") (EApp (EVar "returnPosMethodNames") (EVar "userDecls")))) (DoLet false false (PVar "markSharedNames") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EVar "rpNames") (EFieldAccess (EVar "pmf") "pmfMethodConstraints")) (EApp (EVar "methodConstraintNames") (EVar "userDecls"))))) (DoLet false false (PVar "graphShadowNames") (EApp (EApp (EApp (EVar "buildStandaloneShadowsGraph") (EVar "shadowMap")) (EVar "allDecls")) (EVar "userDecls"))) (DoLet false false (PVar "ms") (ERecordCreate "MarkSets" ((fa "msMarkRpNames" (EApp (EVar "dedup") (EBinOp "++" (EVar "markSharedNames") (EVar "graphShadowNames")))) (fa "msMarkSharedNames" (EVar "markSharedNames")) (fa "msGraphShadowNames" (EVar "graphShadowNames")) (fa "msArgNames" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatch") (EApp (EVar "argDispatchIndices") (EVar "userDecls"))))) (fa "msCoreShadowMap" (EApp (EApp (EApp (EVar "coreShadowMapFor") (EVar "gctx")) (EVar "coreDecls")) (EVar "shadowMap"))) (fa "msBareDictNames" (EApp (EVar "dedup") (EApp (EApp (EVar "moduleDictNames") (EFieldAccess (EVar "pmf") "pmfConstrainedNames")) (EVar "modules")))) (fa "msUnits" (EVar "units")) (fa "msScopeClass" (EApp (EVar "scopeClassesOf") (EVar "units")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "markSetsRef")) (EApp (EVar "Some") (EVar "ms")))) (DoExpr (EVar "ms"))))
(DTypeSig false "scopeClassesOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ScopeClass")))))
(DFunDef false "scopeClassesOf" ((PVar "units")) (EBlock (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "units"))) (DoLet false false (PVar "byMid") (EApp (EApp (EVar "omFromPairs") (EVar "surfaces")) (EVar "omEmpty"))) (DoLet false false (PVar "prelude") (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EVar "coreExports") (EListLit)))) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "core"))) (EVar "surfaces")))) (DoLet false false (PVar "outer") (ERecordUpdate (EVar "prelude") ((fa "expValueOrigins" (EListLit))))) (DoLet false false (PVar "scopes") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopeOfUnit") (EVar "byMid")) (EVar "outer"))) (EApp (EApp (EVar "filterList") (EBinOp "<<" (EVar "not") (EVar "isCoreUnit"))) (EVar "units")))) (EVar "omEmpty"))) (DoExpr (ELam ((PVar "mid") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "scopes")) (arm (PCon "Some" (PVar "scope")) () (EApp (EVar "scopeClassOf") (EApp (EApp (EVar "bareBinding") (EVar "scope")) (EVar "n")))) (arm (PCon "None") () (EVar "ScopeOther")))))))
(DTypeSig false "isCoreUnit" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "Bool")))
(DFunDef false "isCoreUnit" ((PTuple (PVar "mid") PWild)) (EBinOp "==" (EVar "mid") (ELit (LString "core"))))
(DTypeSig false "scopeOfUnit" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "NameScope"))))))
(DFunDef false "scopeOfUnit" ((PVar "byMid") (PVar "outer") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "unitScope") (EVar "byMid")) (EVar "outer")) (EVar "decls"))))
(DTypeSig false "unitScope" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "NameScope")))))
(DFunDef false "unitScope" ((PVar "byMid") (PVar "prelude") (PVar "decls")) (EBlock (DoLet false false (PVar "written") (EApp (EVar "writtenImportsOf") (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "nameScopeOf") (EVar "written")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "importedSurfaces") (ELam ((PVar "mid")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "byMid"))))) (EVar "written"))) (EVar "prelude")))))
(DTypeSig false "scopeClassOf" (TyFun (TyApp (TyCon "Option") (TyCon "NameBinding")) (TyCon "ScopeClass")))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" (PCon "RungPrelude") PWild))) (EVar "ScopeOther"))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" PWild (PCon "TargetValue" PWild PWild)))) (EVar "ScopeValue"))
(DFunDef false "scopeClassOf" ((PCon "Some" (PCon "Bound" PWild (PCon "TargetMethod" PWild PWild PWild)))) (EVar "ScopeMethod"))
(DFunDef false "scopeClassOf" (PWild) (EVar "ScopeOther"))
(DTypeSig true "scopeClassIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ScopeClass")))))
(DFunDef false "scopeClassIn" ((PVar "gctx") (PVar "mid") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value") (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EFieldAccess (EVar "ms") "msScopeClass") (EVar "mid")) (EVar "n"))) (arm (PCon "None") () (EVar "ScopeOther"))))
(DTypeSig true "markDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "markDictNames" ((PVar "gctx") (PVar "names") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "dedup") (EBinOp "++" (EVar "names") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EApp (EVar "importerDefiners") (EVar "gctx"))) (EVar "names")) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (EVar "modules")))))
(DTypeSig true "markGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "markGroupClauses" ((PVar "mm") (PVar "env") (PVar "members") (PVar "grouped")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "omFromNames") (EVar "members")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EVar "noDictHook")) (ELam ((PVar "n")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "own")) (EApp (EApp (EVar "grantNameIn") (EVar "env")) (EVar "n"))))))) (EVar "members")) (EVar "grouped")))))
(DTypeSig true "mapGroupClauses" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "mapGroupClauses" (PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "mapGroupClauses" ((PVar "f") (PCons (PVar "m") (PVar "rest")) (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EVar "f")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EVar "f")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "grouped"))))
(DTypeSig true "markRecursiveOccurrences" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "markRecursiveOccurrences" ((PVar "mctx") (PVar "mm") (PVar "placeholders") (PVar "scopedMembers") (PVar "grouped")) (EBlock (DoLet false false (PVar "promoted") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (EVar "omEmpty"))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "promoted")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "member")) (EFieldAccess (EVar "member") "smName"))) (EVar "scopedMembers")))) (DoExpr (EMatch (EVar "fresh") (arm (PList) () (EVar "grouped")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "mm") "mmDictSet")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "omEmpty"))) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped")))))))))
(DTypeSig false "recMarkMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "recMarkMembers" ((PVar "_mctx") PWild PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "recMarkMembers" ((PVar "mctx") (PVar "dn") (PVar "placeholders") (PCons (PVar "member") (PVar "rest")) (PVar "grouped")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "onDict") (ELam ((PVar "callee") (PVar "ev")) (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "callee")) (EVar "m")) (EApp (EApp (EVar "placeholderMonoOf") (EVar "callee")) (EVar "placeholders"))) (EFieldAccess (EVar "member") "smScope")) (EVar "ev"))))) (DoLet false false (PVar "rw") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EVar "omEmpty")) (EVar "dn")) (EVar "omEmpty")) (EListLit)) (EVar "onDict")) (ELam (PWild) (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EVar "dn")) (EVar "placeholders")) (EVar "rest")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EVar "mctx")) (EVar "rw"))) (EListLit (EVar "m"))) (EVar "grouped"))))))
(DTypeSig false "placeholderMonoOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "placeholderMonoOf" ((PVar "callee") (PVar "placeholders")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "callee")) (EVar "placeholders")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "markRecursiveOccurrences: ")) (EApp (EVar "$core.display") (EVar "callee"))) (ELit (LString " is not a member of the group")))))))
(DTypeSig true "rebuildGroupDecls" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rebuildGroupDecls" ((PVar "grouped") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "omEmpty")) (EVar "prog"))))
(DTypeSig false "rebuildGroupDeclsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildGroupDeclsGo" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e")) (EVar "site")) (EVar "bid")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending")) (EVar "binds"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "binds2")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DAttrib" (PVar "attrs") (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EListLit (EVar "d")))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "d2")) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")))) (EVar "inner")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "ds") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "d") (EVar "ds")) (EVar "pending2")))))
(DTypeSig false "rebuildLetBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildLetBinds" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildLetBinds" ((PVar "grouped") (PVar "pending") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "clauses2") (PVar "pending2")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending")) (EVar "n")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "binds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses2")) (EVar "site")) (EVar "bid")) (EVar "binds")) (EVar "pending3")))))
(DTypeSig false "rebuildFunClauses" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "rebuildFunClauses" (PWild (PVar "pending") PWild (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildFunClauses" ((PVar "grouped") (PVar "pending") (PVar "n") (PCons PWild (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "cs") (PVar "pending3")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending2")) (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e")) (EVar "cs")) (EVar "pending3")))))
(DTypeSig false "popMarkedClause" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "popMarkedClause" ((PVar "grouped") (PVar "pending") (PVar "n")) (EBlock (DoLet false false (PVar "remaining") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "pending")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EVar "clausesOf") (EVar "n")) (EVar "grouped"))))) (DoExpr (EMatch (EVar "remaining") (arm (PCons (PVar "c") (PVar "cs")) () (ETuple (EVar "c") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "cs")) (EVar "pending")))) (arm (PList) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "rebuildGroupDecls: no marked clause left for ")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "")))))))))
(DTypeSig true "computeMangledShadowMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "computeMangledShadowMap" ((PVar "allDecls") (PVar "units")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EVar "dedup") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "unitMangledShadows") (EVar "methodNames"))) (EVar "units")))))
(DTypeSig false "unitMangledShadows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "unitMangledShadows" ((PVar "methodNames") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "sym")) (EVar "fns")) (EListLit (ETuple (EVar "sym") (EVar "m"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPreludeMid") (EVar "mid"))) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "fns"))) (EListLit (ETuple (EVar "m") (EVar "m"))) (EListLit))))))) (EVar "methodNames")))))
(DTypeSig true "buildStandaloneShadowsGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildStandaloneShadowsGraph" ((PVar "sm") (PVar "allDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EApp (EVar "omFromNames") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "userDecls"))))) (DoLet false false (PVar "direct") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methodNames")))) (EVar "fns"))) (DoLet false false (PVar "mangled") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))) (EVar "fns"))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "coreShadowMapFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "coreShadowMapFor" ((PVar "gctx") (PVar "coreProg") (PVar "shadowMap")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "shadowMap") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "coreProg"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shadowSymSpelledBare" (TyFun (TyCon "SpellCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "shadowSymSpelledBare" ((PVar "sc") (PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EVar "n")) (EVar "bare")))))
(DTypeSig false "spellCtxOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SpellCtx"))))
(DFunDef false "spellCtxOf" ((PVar "gctx") (PVar "prog")) (ERecordCreate "SpellCtx" ((fa "scTopFns" (EApp (EVar "declTopFnNames") (EVar "prog"))) (fa "scBare" (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "prog")) (ERecordCreate "BareLocals" ((fa "blAll" (EVar "False")) (fa "blSet" (EListLit)))))) (fa "scCorePfx" (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (ELit (LString "")))))))
(DTypeSig false "moduleSpellsShadowBare" (TyFun (TyCon "SpellCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "moduleSpellsShadowBare" ((PVar "sc") (PVar "sym") (PVar "bare")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "sym")) (EFieldAccess (EVar "sc") "scTopFns")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EFieldAccess (EVar "sc") "scCorePfx")) (EVar "sym")) (EBinOp "==" (EVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EFieldAccess (EVar "sc") "scCorePfx"))) (ELit (LString ""))) (EApp (EVar "$core.display") (EVar "bare"))) (ELit (LString "")))))) (EApp (EApp (EVar "bareLocalBound") (EFieldAccess (EVar "sc") "scBare")) (EVar "bare"))))
(DTypeSig false "bareLocalBound" (TyFun (TyCon "BareLocals") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bareLocalBound" ((PVar "bl") (PVar "bare")) (EBinOp "||" (EFieldAccess (EVar "bl") "blAll") (EApp (EApp (EVar "contains") (EVar "bare")) (EFieldAccess (EVar "bl") "blSet"))))
(DTypeSig false "declBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "declBareLocals" ((PVar "_gctx") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "formBareLocals") (EVar "gctx")) (EVar "path")) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "formBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "formBareLocals" ((PVar "gctx") (PVar "path") (PVar "acc")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (ERecordUpdate (EVar "acc") ((fa "blAll" (EVar "True")))) (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EFieldAccess (EVar "acc") "blSet"))))))) (arm (PCon "Some" (PVar "bindings")) () (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EVar "depExportsStandalone") (EVar "gctx")) (EVar "depId")) (EVar "l")))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "bindings"))) (EFieldAccess (EVar "acc") "blSet"))))))))))
(DTypeSig false "shadowBareName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shadowBareName" ((PVar "sm") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))
(DTypeSig false "methodMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkCtx"))))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") (PLit (LString "")) (PVar "coreProg")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msMarkRpNames")) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkRpNames"))) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") PWild (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msMarkSharedNames") (EFieldAccess (EVar "ms") "msGraphShadowNames")))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty")))) (fa "mcSm" (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoLet false false (PVar "shadowMap") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkSharedNames")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "shadowBareName") (EVar "shadowMap")) (EVar "n"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "shadowSymSpelledBare") (EVar "sc")) (EVar "shadowMap")) (EVar "n"))))) (EFieldAccess (EVar "ms") "msGraphShadowNames"))))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty")))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "moduleMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "MarkCtx")))))))
(DFunDef false "moduleMarkCtx" ((PVar "gctx") (PVar "ms") (PVar "mid") (PVar "prog") (PVar "imported")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EVar "methodMarkCtx") (EVar "gctx")) (EVar "ms")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declExternNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcRp")) (EVar "externs"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcAn")) (EVar "externs"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "entry"))) (EVar "local")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "entry"))) (EVar "imported"))))) (EFieldAccess (EVar "candidates") "mcSm"))))))))
(DTypeSig false "ladderMarkCtx" (TyFun (TyFun (TyCon "String") (TyCon "ScopeClass")) (TyFun (TyCon "MarkCtx") (TyCon "MarkCtx"))))
(DFunDef false "ladderMarkCtx" ((PVar "scopeOf") (PVar "mc")) (EBlock (DoLet false true (PVar "marked") (ELam ((PVar "n")) (EBinOp "/=" (EApp (EVar "scopeOf") (EVar "n")) (EVar "ScopeValue")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.filterWithKey") (ELam ((PVar "n") PWild) (EApp (EVar "marked") (EVar "n")))) (EFieldAccess (EVar "mc") "mcRp"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.filterWithKey") (ELam ((PVar "n") PWild) (EApp (EVar "marked") (EVar "n")))) (EFieldAccess (EVar "mc") "mcAn"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EVar "marked") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "marked") (EApp (EVar "snd") (EVar "e")))))) (EFieldAccess (EVar "mc") "mcSm"))))))))
(DTypeSig true "beginModuleMarking" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ModuleSeed") (TyCon "Unit")))))))
(DFunDef false "beginModuleMarking" ((PVar "mctx") (PVar "mid") (PVar "prog") (PVar "top") (PVar "seed")) (EBlock (DoLet false false (PVar "ms") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value"))) (DoLet false false (PVar "known") (EMatch (EVar "mid") (arm (PLit (LString "")) () (EApp (EVar "constrainedSigNames") (EVar "prog"))) (arm PWild () (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "promotionHarvestRef") "value")))))) (DoLet false false (PVar "aliases") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EApp (EVar "importerDefiners") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "known")) (EFieldAccess (EVar "ms") "msUnits")) (EListLit (ETuple (EVar "mid") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasNext")) (ETuple (EVar "mid") (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasMinted")) (EListLit))) (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EApp (EVar "moduleMarkCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ms")) (EVar "mid")) (EVar "prog")) (EFieldAccess (EVar "seed") "msImportedValues"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef")) (EApp (EVar "Some") (ERecordCreate "ModuleMarking" ((fa "mmCtx" (EApp (EApp (EVar "ladderMarkCtx") (EApp (EFieldAccess (EVar "ms") "msScopeClass") (EVar "mid"))) (EVar "candidates"))) (fa "mmTop" (EVar "top")) (fa "mmDictSet" (EApp (EVar "Ref") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "known") (EVar "aliases"))) (EVar "omEmpty")))) (fa "mmUserNames" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedNames"))) (fa "mmExterns" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declExternNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedExterns"))))))))))
(DTypeSig true "finishModuleMarking" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "finishModuleMarking" ((PVar "mm") (PVar "env") (PVar "grouped") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "markTailDecls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EApp (EVar "grantNameIn") (EVar "env"))) (EApp (EApp (EVar "rebuildGroupDecls") (EVar "grouped")) (EVar "prog"))))
