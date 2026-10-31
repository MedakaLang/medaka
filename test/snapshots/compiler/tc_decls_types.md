# META
source_lines=2277
stages=DESUGAR,MARK
# SOURCE
-- tc_decls_types: the written-type layer of declaration analysis: AST types to `Mono`
-- (`fromAstType`, `fromAstTypeE` and their application, alias-argument, effect-row and
-- authority-qualifier cases `qualifyByTerms`, with the signature binder sets `SigVars` they read),
-- the expansion of an applied alias, at conversion and at a written head (`aliasArgBindings`,
-- `aliasScopeE`, `expandAliasHeadTy`, `substAliasArgs`),
-- declared-kind consistency (`checkDeclaredKinds`, `checkHeadKinds`, `checkIfaceHeadKinds`,
-- `checkSuperKinds`), effect domains (`registerEffectDomain`, `populateEffectDomainsGraph`,
-- `checkDomainAxes`, `checkWrittenElementCap`), authority terms and binders (`authArgOf`,
-- `checkDeclAuthorityUses`, `checkBinderDomain`, `checkPhantomAuthorityExport`,
-- `reportUnboundAuthorityNamesIn`, `authorityBinderBound`) and written effect-parameter checks
-- (`checkEffectParams`), with the message builders those checks use.
--
-- Spec: DICT section 1 (the type and predicate forms the conversion lowers); EFFECTS section 2.1
-- (the domain family a label declares: `Unit`, `Prefix`, `Set`, `Product`), section 4.1 (named
-- authorities and scoped constraints), section 6.1-section 6.5 (kinds, declaration sites, partial
-- annotations, kind consistency, requires chains), including section 6.4 (alias expansion invents
-- no qualifier); SYNTAX Declared parameter kinds.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_decls`, `tc_foreign`,
-- `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`,
-- `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`,
-- `tc_module`.

import support.diag_codes.{DiagCode(..)}
import types.tc_types.{
  Kind(..),
  SigVars(..),
  GraphCtx,
  ModuleCtx,
}
import types.tc_mono.{
  joinCellOf,
  newEffvarId,
  stripEff,
  tconBuiltin,
  tconFrom,
  tconTupleHead,
  tupleMono,
  tupleSpineOf,
  tyAppSpine,
}
import types.tc_diag_text.{
  aliasArityMsg,
  authorityAsTypeMsg,
  authorityAtomicLabelMsg,
  authorityParamAsRowMsg,
  authorityParamAsTypeMsg,
  authorityTermAsTypeMsg,
  binderDomainMsg,
  binderDomainTypeMsg,
  binderNoDomainMsg,
  binderTypeMsg,
  effectArrowOnDataHeadMsg,
  effectParamAsTypeMsg,
  exactInPatternSlotMsg,
  ifaceParamAuthorityKindMsg,
  ifaceParamEffectKindMsg,
  ifaceSlotDeclaredTypeMsg,
  joinDomainMsg,
  nameNotAuthorityMsg,
  ordinaryInPatternSlotMsg,
  patternDomainMsg,
  phantomExportMsg,
  qualifierBinderTypeMsg,
  renderKindArrow,
  requiresKindMsg,
  rowKindMismatchMsg,
  typeAsAuthorityMsg,
  typeInRowSlotMsg,
  typeParamAsRowMsg,
  typeVarAsAuthorityMsg,
  unannotatedGradedParamMsg,
  unannotatedRowParamMsg,
}
import types.tc_state.{emptySigVars, mctxAtIfSome}
import types.tc_env.{
  anyKRow,
  ceLookupAt,
  ceRowParamKinds,
  declEnvsOrdOf,
  domainHasPatterns,
  dtopFor,
  effTailNames,
  ifaceParamKindsDeclAll,
  ifaceParamKindsFor,
  ifaceParamKindsOf,
  ifaceTabKey,
  kindAnnSlots,
  padAnns,
  tyTabKey,
}
import types.tc_diag.{
  pushTypeError,
  pushTypeErrorAt,
  pushTypeErrorOnce,
  pushTypeErrorOnceAt,
  pushTypeErrorOncePerSite,
}
import types.tc_unify.{
  atomBindersIn, authSlotNamesIn, freshAuthvarRanged, freshVar, openRow
}
import types.tc_decls_variance.{payloadAstTypes, variantPayload}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  authJoinAll,
  authPatternClose,
  authTop,
  authvarDomain,
  authvarIsPattern,
  isPatternParam,
  linkAuthvar,
}
import types.effect_rows.{
  Atom(..),
  EffLabel(..),
  EffRow(..),
  Effvar(..),
  atomsNorm,
  atomWith,
  effLabelName,
  labelKey,
  pureRow,
}
import frontend.ast.{
  ConPayload(..),
  Constraint(..),
  DataVis(..),
  Decl(..),
  EffAtomTy(..),
  EffParamTy(..),
  ExternDecl(..),
  Field(..),
  IfaceMethod(..),
  KindAnn(..),
  Loc(..),
  Super(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  Variant(..),
  authTermNames,
  authTermsSurface,
  firstTyLoc,
  firstTyLocList,
  lookupTab,
  mapTyFull,
  orElseLoc,
  patternMark,
  qualifierSource,
  tabKeyEq,
  variantName,
}
import types.repr.{Mono(..), ppAuthArg, ppTy}
import types.effect_domain.{
  Param(..),
  canonParam,
  domainKey,
  extendParam,
  lookupAxis,
  subTopOf,
  writtenSetProblem,
}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  escStr,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  reverseL,
  zipL,
}
import list.{get}
import types.effect_param_decode.{
  atomicLabelParamText,
  effectParamMsg,
  effectParamProblems,
  repeatedNames,
  writtenAxis,
  writtenParam,
}
import types.registry.{regKeyOfTab}

-- The effect-label domain registry maps a label's identity key (`labelKey`) to the
-- top param of its declared domain.  A `PPrefix None` entry means "Prefix domain
-- (carries a pattern)"; a `PPath None` entry is a Prefix domain whose runtime confines
-- by canonical path, so its order compares canonical paths (`FileRead`, `FileWrite`:
-- the labels of the file externs that take a grant); absence means atomic (Unit).
-- Seeded with the builtin labels and extended per program from `effect Net Prefix`
-- decls, each under its declaration's own identity, so two modules' same-spelled
-- labels own separate schemas.  An assoc-list Ref (the label set is tiny).
seedEffectDomains : GraphCtx -> Unit -> Unit
seedEffectDomains gctx _ =
  let builtins = [
    ("Net", PPrefix None),
    ("FileRead", PPath None),
    ("FileWrite", PPath None),
    ("Env", PSet None),
    ("Exec", PPrefix None),
    ("FFI", PPrefix None),
  ]
  gctx.effectDomains := builtins

-- register a label's domain from its `effect` decl: Some "Prefix" ⇒ Prefix;
-- None ⇒ atomic.
-- A Product label registers its declared axis schema as its top (each axis
-- at the top of its own domain, in declaration order); the schema is what
-- names the primary axis a bare literal lifts into and the axes a written
-- product may name.  A Product without axes, or axes on any other domain, is
-- refused at the declaration (`T-EFFECT-PARAM`).
registerEffectDomain : GraphCtx ->
  EffLabel ->
  Option String ->
  List (String, String) ->
  Unit
registerEffectDomain gctx label domain axes =
  let entry = (labelKey label, domainParamWith domain axes)
  gctx.effectDomains := entry :: gctx.effectDomains.value

-- Located at the declaration's own span: nothing else in an `effect`
-- declaration has one, and a declaration-level check is outside every
-- construct.
checkDomainAxes : ModuleCtx ->
  Option Loc ->
  String ->
  Option String ->
  List (String, String) ->
  Unit
checkDomainAxes mctx loc l (Some "Product") [] =
  pushTypeErrorAt
    mctx
    TEffectParam
    loc
    (effectParamMsg
      l
      "a Product label declares its axes; write `effect \{l} Product (Host : Prefix, Method : Set)`")
checkDomainAxes mctx loc l (Some "Product") axes =
  fold
    (_ name =>
      pushTypeErrorAt
        mctx
        TEffectParam
        loc
        (effectParamMsg l "axis `\{name}` of `\{l}` is declared twice"))
    ()
    (repeatedNames (map fst axes) [])
  fold
    (_ a => match snd a
      "Prefix" => ()
      "Set" => ()
      other =>
        pushTypeErrorAt
          mctx
          TEffectParam
          loc
          (effectParamMsg
            l
            "axis `\{fst a}` of `\{l}` names the domain `\{other}`; an axis is `Prefix` or `Set`"))
    ()
    axes
checkDomainAxes mctx _ _ _ [] = ()
checkDomainAxes mctx loc l _ _ =
  pushTypeErrorAt
    mctx
    TEffectParam
    loc
    (effectParamMsg l "only a `Product` label declares axes")

-- the ⊤-param a declared label carries: atomic ⇒ PUnit; Prefix ⇒ PPrefix None.
domainParam : Option String -> Param
domainParam (Some "Prefix") = PPrefix None
domainParam (Some "Set") = PSet None
domainParam (Some "Product") = PProduct []
domainParam _ = PUnit

domainParamWith : Option String -> List (String, String) -> Param
domainParamWith (Some "Product") axes =
  PProduct (map (a => (fst a, domainParam (Some (snd a)))) axes)
domainParamWith domain _ = domainParam domain

-- The same thing over a module GRAPH, in `deAllDecls` order (prelude first, then
-- the loader's dependency-first modules) but without flattening it: the Module-mode
-- drivers must populate the table BEFORE they build the declaration envelope (the
-- envelope's atom seed reads it -- see `declEnvRowAtomsEntries`), and at that point
-- `deAllDecls` does not exist yet.  Registering unit by unit is the same sequence of
-- `registerEffectDomain` calls the flattened list produces, so the resulting table is
-- the same value; spelling it this way is what keeps the concatenation from being
-- built twice per analyze.
export
populateEffectDomainsGraph : GraphCtx ->
  List Decl ->
  List (String, List Decl) ->
  Unit
populateEffectDomainsGraph gctx coreDecls modules =
  seedEffectDomains gctx ()
  populateGo gctx coreDecls
  populateUnitsGo gctx modules

populateUnitsGo : GraphCtx -> List (String, List Decl) -> Unit
populateUnitsGo gctx [] = ()
populateUnitsGo gctx ((_, prog) :: rest) =
  populateGo gctx prog
  populateUnitsGo gctx rest

populateGo : GraphCtx -> List Decl -> Unit
populateGo gctx [] = ()
populateGo gctx ((DEffect _ name domain axes origin _) :: rest) =
  registerEffectDomain gctx (EffLabel name origin) domain axes
  populateGo gctx rest
populateGo gctx (_ :: rest) = populateGo gctx rest

-- build an atom from a WRITTEN annotation atom.  A bare label takes the
-- domain's top; a written parameter becomes the element of the label's domain
-- it spells; a parameter of the wrong shape for the domain is diagnosed by
-- `checkOneEffectParam` and takes the top here.  Pure: validation is a
-- separate pass.  A named parameter is a binder-bound authority; until the
-- authority representation lands it elaborates as the top.
-- A named parameter is the binder's authority variable, shared with every
-- other occurrence in the same signature.  A name no binder in the signature
-- introduces is a resolve error already; here it takes the domain's top.
atomOfWrittenIn : GraphCtx -> SigVars -> EffAtomTy -> Atom
atomOfWrittenIn gctx sv a =
  let l = EffLabel a.eatLabel a.eatOrigin
  match (a.eatParam, dtopFor gctx l)
    (EPName n, top) => match lookupAssoc n sv.svAuths
      Some cell => Atom l (AVar cell)
      None => atomWith l top
    (EPProduct axes, PProduct schema) if axisNamesArgument axes =>
      Atom l (AProduct (map (writtenAxisTerm sv axes) schema))
    (p, top) => atomWith l (writtenParam top p)

-- One axis of a product that names an argument: the named argument's
-- variable, whose domain is that axis's; a written value; or the axis's top
-- where the atom leaves it out.
writtenAxisTerm : SigVars ->
  List (String, EffParamTy) ->
  (String, Param) ->
  (String, Authority)
writtenAxisTerm sv written (name, top) = match lookupAssoc name written
  Some (EPName n) => match lookupAssoc n sv.svAuths
    Some cell => (name, AVar cell)
    None => (name, authTop top)
  Some p => match writtenAxis (name, p)
    (_, PUnit) => (name, authTop top)
    (_, v) => (name, AConst (canonParam v))
  None => (name, authTop top)

export
atomsOfWritten : GraphCtx -> List EffAtomTy -> List Atom
atomsOfWritten gctx ls = atomsOfWrittenIn gctx emptySigVars ls

export
atomsOfWrittenIn : GraphCtx -> SigVars -> List EffAtomTy -> List Atom
atomsOfWrittenIn gctx sv ls = atomsNorm (map (atomOfWrittenIn gctx sv) ls)

-- validate every written effect param in a program's type annotations against
-- the registry: a Prefix label's pattern must pass prefixPatternOk; an atomic
-- label rejects a param outright.  Runs as a side-effecting pass (errors via
-- pushTypeError) — the OCaml side does this inline in atom_of_written.
export
checkEffectParams : ModuleCtx -> List Decl -> Unit
checkEffectParams mctx [] = ()
checkEffectParams mctx (d :: rest) =
  checkEffectParamsDecl mctx d
  checkEffectParams mctx rest

checkEffectParamsDecl : ModuleCtx -> Decl -> Unit
checkEffectParamsDecl mctx (DTypeSig _ _ t _) = checkEffectParamsTy mctx t
checkEffectParamsDecl mctx (DExtern (ExternDecl { edTy = t, ... })) =
  checkEffectParamsTy mctx t
checkEffectParamsDecl mctx (DAttrib _ d) = checkEffectParamsDecl mctx d
checkEffectParamsDecl mctx (DData { dataCtors = ctors }) =
  fold
    (_ v => match v
      Variant _ payload => checkEffectParamsTys mctx (payloadAstTypes payload))
    ()
    ctors
checkEffectParamsDecl mctx (DTypeAlias { tyAliasRhs = rhs }) =
  checkEffectParamsTy mctx rhs
checkEffectParamsDecl mctx (DNewtype { newtypeFieldTy = t }) =
  checkEffectParamsTy mctx t
checkEffectParamsDecl mctx (DInterface { methods = ms }) =
  fold
    (_ m => match m
      IfaceMethod _ t _ _ => checkEffectParamsTy mctx t)
    ()
    ms
checkEffectParamsDecl mctx _ = ()

-- A declaration's `Authority L` parameter, or a constructor's existential
-- `(q : Authority L)` binder, has L's domain, so each use of it in the
-- declaration, at an atom or an index slot, must be of that domain, as a
-- signature's binder must (`reportBinderDomains`). Runs after
-- `registerAllData`: an index slot's domain is read from the kind table.
export
checkDeclAuthorityUses : ModuleCtx -> List Decl -> Unit
checkDeclAuthorityUses mctx ds = each (checkDeclAuthorityUsesDecl mctx) ds

checkDeclAuthorityUsesDecl : ModuleCtx -> Decl -> Unit
checkDeclAuthorityUsesDecl mctx (DAttrib _ d) =
  checkDeclAuthorityUsesDecl mctx d
checkDeclAuthorityUsesDecl mctx (DData { dataParams = ps, dataParamKinds = ks, dataCtors = ctors, dataCtorBinders = bss }) =
  let heads = flatMap (declaredAuthority mctx.mcGraph) (zipParamKinds ps ks)
  fold
    (_ cb => match cb
      (Variant _ payload, bs) =>
        checkDeclAuthorityDomains mctx heads bs (payloadAstTypes payload))
    ()
    (zipCtorBinders ctors bss)
checkDeclAuthorityUsesDecl mctx (DTypeAlias { tyAliasParams = ps, tyAliasParamKinds = ks, tyAliasRhs = rhs }) = checkDeclAuthorityDomains
  mctx
  (flatMap (declaredAuthority mctx.mcGraph) (zipParamKinds ps ks))
  []
  [rhs]
checkDeclAuthorityUsesDecl mctx (DNewtype { newtypeParams = ps, newtypeParamKinds = ks, newtypeCtorBinders = bs, newtypeFieldTy = t }) = checkDeclAuthorityDomains
  mctx
  (flatMap (declaredAuthority mctx.mcGraph) (zipParamKinds ps ks))
  bs
  [t]
-- No other declaration declares an `Authority` parameter: a signature's
-- binders are checked with the signature (`reportBinderDomains`), and an
-- interface parameter cannot be an authority.
checkDeclAuthorityUsesDecl mctx _ = ()

-- The head's authorities and a constructor's own binders, then each use in
-- [fields] against them. A binder never repeats a head parameter's name:
-- resolve refuses that (`duplicateCtorBinders`).
checkDeclAuthorityDomains : ModuleCtx ->
  List (String, Param) ->
  List (String, KindAnn) ->
  List Ty ->
  Unit
checkDeclAuthorityDomains mctx _ _ [] = ()
checkDeclAuthorityDomains mctx heads bs (t :: ts) =
  let declared =
    heads
      ++ flatMap (b => declaredAuthority mctx.mcGraph (fst b, Some (snd b))) bs
  let names = map fst declared
  let uses =
    filterList
      (u => contains (fst u) names)
      (flatMap (authorityUsesOf mctx) (t :: ts))
  if isEmptyL uses then () else reportBinderDomains mctx t (declared ++ uses)

declaredAuthority : GraphCtx -> (String, Option KindAnn) -> List (String, Param)
declaredAuthority gctx (p, Some (KindAuthority l o _ _)) =
  [(p, dtopFor gctx (EffLabel l o))]
declaredAuthority gctx _ = []

-- Each constructor with its existential binders; a declaration without the
-- binder list (every constructor binds none) pairs each with none.
zipCtorBinders : List Variant ->
  List (List (String, KindAnn)) ->
  List (Variant, List (String, KindAnn))
zipCtorBinders [] _ = []
zipCtorBinders (v :: vs) (b :: bs) = (v, b) :: zipCtorBinders vs bs
zipCtorBinders (v :: vs) [] = (v, []) :: zipCtorBinders vs []

zipParamKinds : List String ->
  List (Option KindAnn) ->
  List (String, Option KindAnn)
zipParamKinds (p :: ps) (k :: ks) = (p, k) :: zipParamKinds ps ks
zipParamKinds _ _ = []

-- ── Declared-kind consistency (EFFECTS-SEMANTICS §6.4, §6.5) ──────────────
-- Declaring a kind creates an obligation between the head and the body.  Runs
-- AFTER `registerAllData` (like `checkUndeterminedRetEffVars`), because the
-- "is this slot Effect-kinded" reads (`rowArgNames`) consult the kind table.
--
-- (a) declared kind CONTRADICTED by usage: `data Async (e : Type) a = Mk (Unit
--     -> <e> a)` — or, the compulsory-migration case, an UNANNOTATED `e` in an
--     effect-tail / Effect-slot position, which §6.3 says can never be
--     `Effect`-kinded by inference.  Both are `T-EFFECT-KIND-MISMATCH`, at the
--     field whose position demands the kind.
-- (b) declared `Effect` but used as an ordinary type (`data Box (e : Effect) a
--     = Mk e`): the same code.  A phantom `Effect` parameter — declared and
--     never used — is LEGAL (§6.4 (b)).
-- (c) an interface parameter: an unannotated parameter whose methods put it
--     at a slot that co-occurs with an effect tail (the retired inference rule)
--     needs `(f : Effect -> Type -> Type)`; a declared arrow kind whose slots
--     disagree with that evidence is reported the same way.
-- (d) `requires`-chain agreement (§6.5), for a superinterface declared in the
--     SAME module: the parameter's resolved kinds must equal the super's.
export
checkDeclaredKinds : ModuleCtx -> List Decl -> Unit
checkDeclaredKinds mctx prog = checkDeclaredKindsGo mctx prog prog

checkDeclaredKindsGo : ModuleCtx -> List Decl -> List Decl -> Unit
checkDeclaredKindsGo mctx _ [] = ()
checkDeclaredKindsGo mctx prog (d :: rest) =
  checkDeclaredKindsDecl mctx prog d
  checkDeclaredKindsGo mctx prog rest

checkDeclaredKindsDecl : ModuleCtx -> List Decl -> Decl -> Unit
checkDeclaredKindsDecl mctx prog (DAttrib _ d) =
  checkDeclaredKindsDecl mctx prog d
-- An effect label's domain schema is declared on its head as a data type's
-- kinds are: a Product declares its axes, nothing else does.
checkDeclaredKindsDecl mctx _ (DEffect _ name domain axes _ loc) =
  checkDomainAxes mctx loc name domain axes
checkDeclaredKindsDecl mctx _ (DData { dataVis = vis, dataName = n, dataParams = ps, dataParamKinds = ks, dataCtors = vs, dataCtorBinders = bs }) =
  checkAuthorityKindLabels
    mctx
    (ks ++ flatMap (b => map (x => Some (snd x)) b) bs)
  checkHeadKinds
    mctx
    n
    ps
    ks
    (flatMap (v => payloadAstTypes (variantPayload v)) vs)
  checkPhantomAuthorityExport mctx vis n (authorityParamNames ps ks) vs
checkDeclaredKindsDecl mctx _ (DNewtype { newtypeName = n, newtypeParams = ps, newtypeParamKinds = ks, newtypeFieldTy = fty, newtypeCtorBinders = bs }) =
  checkAuthorityKindLabels mctx (ks ++ map (b => Some (snd b)) bs)
  checkHeadKinds mctx n ps ks [fty]
checkDeclaredKindsDecl mctx _ (DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasParamKinds = ks, tyAliasRhs = rhs }) =
  checkAuthorityKindLabels mctx ks
  checkAliasPatternSlots mctx (zipParamKinds ps ks) rhs
  checkHeadKinds mctx n ps ks [rhs]
checkDeclaredKindsDecl mctx prog (DInterface { name, typarams, typaramKinds, supers, methods, ... }) =
  checkIfaceHeadKinds mctx name typarams (padAnns typarams typaramKinds) methods
  checkSuperKinds
    mctx
    prog
    name
    typarams
    (padAnns typarams typaramKinds)
    methods
    supers
checkDeclaredKindsDecl mctx _ _ = ()

-- An alias parameter of an ordinary `Authority L` kind admits an exact
-- element, which an `Authority L*` slot of the right-hand side refuses, so
-- the declaration is refused where it is written rather than at whichever
-- use passes one.
checkAliasPatternSlots : ModuleCtx ->
  List (String, Option KindAnn) ->
  Ty ->
  Unit
checkAliasPatternSlots mctx params rhs =
  let slots = patternSlotNamesIn mctx rhs
  fold
    (_ pk => match pk
      (p, Some (KindAuthority l _ False loc)) =>
        if contains p slots then
          pushTypeErrorOncePerSite
            mctx
            TAuthorityPattern
            loc
            (ordinaryInPatternSlotMsg p l)
      _ => ())
    ()
    params

-- `Authority L` ranges over the domain `L` declares (§6.1); a label that
-- declares none — an atomic one, `IO` included — has no authorities to range
-- over, so the kind is refused at the label rather than admitted as a slot
-- every index trivially fills.
checkAuthorityKindLabels : ModuleCtx -> List (Option KindAnn) -> Unit
checkAuthorityKindLabels mctx anns =
  fold
    (_ a => match a
      Some k => checkAuthorityKindLabel mctx k
      None => ())
    ()
    anns

checkAuthorityKindLabel : ModuleCtx -> KindAnn -> Unit
checkAuthorityKindLabel mctx (KindAuthority l o pat loc) =
  match dtopFor mctx.mcGraph (EffLabel l o)
    PUnit =>
      pushTypeErrorOncePerSite
        mctx
        TAuthorityKind
        loc
        (authorityAtomicLabelMsg l)
    top =>
      if pat && not (domainHasPatterns top) then
        pushTypeErrorOncePerSite
          mctx
          TAuthorityPattern
          loc
          (patternDomainMsg ("Authority " ++ l ++ "*") l)
checkAuthorityKindLabel mctx (KindArrow a b) =
  checkAuthorityKindLabel mctx a
  checkAuthorityKindLabel mctx b
checkAuthorityKindLabel mctx _ = ()

-- A constructor CARRYING an `Authority` parameter in no field is a phantom
-- index: applying it proves nothing, so it may invent any authority.  Its
-- declaring module is trusted with that (an `export data` handle's raw
-- descriptor), exactly as it is trusted with an extern's row; a module that
-- exports the constructor itself hands that trust to every importer, which
-- §4.1 forbids.  Every constructor of a `public export data` with an
-- `Authority` parameter must therefore carry it, and carrying is decided by
-- `tyCarries`, not by mention: `List (Handle p)` mentions `p` and carries
-- nothing, since `[]` inhabits it at every index.
checkPhantomAuthorityExport : ModuleCtx ->
  DataVis ->
  String ->
  List String ->
  List Variant ->
  Unit
checkPhantomAuthorityExport mctx VisPublic tyName (p :: ps) variants =
  fold
    (_ v =>
      let tys = payloadAstTypes (variantPayload v)
      if anyList (tyCarries mctx.mcGraph [] p) tys then
        ()
      else
        pushTypeErrorOnceAt
          mctx
          TAuthorityPhantomExport
          (firstTyLocList tys)
          (phantomExportMsg tyName (variantName v) p))
    ()
    variants
  checkPhantomAuthorityExport mctx VisPublic tyName ps variants
checkPhantomAuthorityExport mctx _ _ _ _ = ()

-- The head's `Authority`-kinded parameter names, positional with the kinds.
authorityParamNames : List String -> List (Option KindAnn) -> List String
authorityParamNames params anns =
  flatMap
    (pk => match snd pk
      Some (KindAuthority _ _ _ _) => [fst pk]
      _ => [])
    (zipL params (padAnns params anns))

-- A field CARRIES the parameter [p] when every value of the field's type
-- holds a value at [p]'s authority: a qualifier (`String @p`), the
-- parameter itself, a tuple with a carrying component, or an index `H … p …`
-- of a head whose every constructor carries that parameter (`Handle p`, by
-- the head's own constructors) — not `List (Handle p)`, whose `[]` carries
-- nothing, and not an arrow, which an idle closure inhabits.  A head whose
-- constructors an importer cannot apply (`export data`, a private head) is
-- trusted: only its declaring module builds a value of it, so holding one is
-- holding that module's word.  A builtin container (`List`, `Array`) has no
-- registered constructors and carries nothing.  Recursion through a head
-- assumes the head carries (the greatest fixpoint): a finite value bottoms
-- out in a carrying constructor, or the type is empty.
tyCarries : GraphCtx -> List TabKey -> String -> Ty -> Bool
tyCarries gctx _ p (TyVar n) = n == p
tyCarries gctx seen p (TyQual t ps _) =
  isNonEmptyL ps && allList (q => authTermNames [q] == [p]) ps
    || tyCarries gctx seen p t
tyCarries gctx seen p (TyTuple ts) = anyList (tyCarries gctx seen p) ts
tyCarries gctx seen p (TyConstrained _ t) = tyCarries gctx seen p t
tyCarries gctx seen p (TyNamed _ t _) = tyCarries gctx seen p t
tyCarries gctx seen p (TyApp a b) = match tyAppSpine (TyApp a b)
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    argsCarry gctx seen p (tyTabKey o n) 0 args
  _ => False
tyCarries gctx _ _ _ = False

-- Argument [i] of head [key] carries [p] when the head's parameter [i]
-- carries and the argument is [p] itself or carries it.
argsCarry : GraphCtx ->
  List TabKey ->
  String ->
  TabKey ->
  Int ->
  List Ty ->
  Bool
argsCarry gctx _ _ _ _ [] = False
argsCarry gctx seen p key i (arg :: rest) =
  paramCarries gctx seen key i && tyCarries gctx seen p arg
    || argsCarry gctx seen p key (i + 1) rest

paramCarries : GraphCtx -> List TabKey -> TabKey -> Int -> Bool
paramCarries gctx seen key i
  | anyList (k => tabKeyEq k key) seen = True
  | otherwise = match lookupTab key gctx.crossRun.universeDataCtors.value
    None => False
    Some (VisPublic, params, variants) => match get i params
      None => False
      Some q =>
        allList
          (v =>
            anyList
              (tyCarries gctx (key :: seen) q)
              (payloadAstTypes (variantPayload v)))
          variants
    Some _ => True

-- data / newtype / alias heads: [fieldTys] are every type the declaration's
-- body mentions.
checkHeadKinds : ModuleCtx ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List Ty ->
  Unit
checkHeadKinds mctx name params anns fieldTys =
  let rowNames =
    dedup (flatMap effTailNames fieldTys ++ flatMap (rowArgNames mctx) fieldTys)
  checkHeadKindsGo mctx name rowNames fieldTys params (padAnns params anns)

checkHeadKindsGo : ModuleCtx ->
  String ->
  List String ->
  List Ty ->
  List String ->
  List (Option KindAnn) ->
  Unit
checkHeadKindsGo mctx _ _ _ [] _ = ()
checkHeadKindsGo mctx name rowNames fieldTys (p :: ps) (a :: anns) =
  let loc = firstTyLocList fieldTys
  match a
    None =>
      if contains p rowNames then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (unannotatedRowParamMsg name p)
    Some KindEffect =>
      if anyList (tyVarTypeOcc mctx p) fieldTys then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (effectParamAsTypeMsg name p)
    Some (k@(KindArrow _ _)) =>
      if kindAnnHasEffect k then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (effectArrowOnDataHeadMsg name p k)
    Some KindType =>
      if contains p rowNames then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (typeParamAsRowMsg name p)
    Some (KindAuthority _ _ _ _) =>
      if contains p rowNames then
        pushTypeErrorOnceAt
          mctx
          TAuthorityKind
          loc
          (authorityParamAsRowMsg name p)
      else if anyList (tyVarTypeOcc mctx p) fieldTys then
        pushTypeErrorOnceAt
          mctx
          TAuthorityKind
          loc
          (authorityParamAsTypeMsg name p)
  checkHeadKindsGo mctx name rowNames fieldTys ps anns
checkHeadKindsGo mctx _ _ _ _ [] = ()

-- does the type variable [p] occur in a TYPE position of [t] — anywhere but an
-- effect tail or an `Effect`-kinded argument slot of a registered head?
tyVarTypeOcc : ModuleCtx -> String -> Ty -> Bool
tyVarTypeOcc mctx p (TyVar n) = n == p
tyVarTypeOcc mctx p (TyEffect _ _ t) = tyVarTypeOcc mctx p t
tyVarTypeOcc mctx _ (TyRow _ _ _) = False
tyVarTypeOcc mctx p (TyNamed _ t _) = tyVarTypeOcc mctx p t
tyVarTypeOcc mctx p (TyQual t _ _) = tyVarTypeOcc mctx p t
tyVarTypeOcc mctx p (TyFun a b) = tyVarTypeOcc mctx p a || tyVarTypeOcc mctx p b
tyVarTypeOcc mctx p (TyTuple ts) = anyList (tyVarTypeOcc mctx p) ts
tyVarTypeOcc mctx p (TyConstrained _ t) = tyVarTypeOcc mctx p t
tyVarTypeOcc mctx p (TyApp a b) = match tyAppSpine (TyApp a b)
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
      Some kinds if listLen kinds == listLen args =>
        tyVarTypeOccSlots mctx p kinds args
      _ => anyList (tyVarTypeOcc mctx p) args
  (hd, args) => tyVarTypeOcc mctx p hd || anyList (tyVarTypeOcc mctx p) args
tyVarTypeOcc mctx _ _ = False

-- per slot: a bare `p` at a KRow slot is a ROW occurrence (skipped); anything
-- else is walked as a type.
tyVarTypeOccSlots : ModuleCtx -> String -> List Kind -> List Ty -> Bool
tyVarTypeOccSlots mctx p (KRow :: ks) ((TyVar _) :: ts) =
  tyVarTypeOccSlots mctx p ks ts
tyVarTypeOccSlots mctx p ((KAuth _ _) :: ks) ((TyVar _) :: ts) =
  tyVarTypeOccSlots mctx p ks ts
tyVarTypeOccSlots mctx p (_ :: ks) (t :: ts) =
  tyVarTypeOcc mctx p t || tyVarTypeOccSlots mctx p ks ts
tyVarTypeOccSlots mctx _ _ _ = False

-- interface heads (c): the retired co-occurrence inference is the EVIDENCE.
checkIfaceHeadKinds : ModuleCtx ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List IfaceMethod ->
  Unit
checkIfaceHeadKinds mctx _ [] _ _ = ()
checkIfaceHeadKinds mctx name (p :: ps) (a :: anns) methods =
  let inferred = ifaceParamKindsOf p methods
  let loc = firstIfaceMethodLoc methods
  match a
    Some (k@(KindArrow _ _)) =>
      let want = kindAnnSlots mctx.mcGraph k
      if isNonEmptyL inferred
        && listLen inferred == listLen want
        && anyRowDeclaredType inferred want then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (ifaceSlotDeclaredTypeMsg name p k)
    Some KindEffect =>
      pushTypeErrorOnceAt
        mctx
        TEffectKindMismatch
        loc
        (ifaceParamEffectKindMsg name p)
    Some (KindAuthority _ _ _ _) =>
      pushTypeErrorOnceAt
        mctx
        TAuthorityKind
        loc
        (ifaceParamAuthorityKindMsg name p)
    _ =>
      if anyKRow inferred then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          loc
          (unannotatedGradedParamMsg name p inferred)
  checkIfaceHeadKinds mctx name ps anns methods
checkIfaceHeadKinds mctx _ _ [] _ = ()

-- a slot the methods use as an effect row that the annotation declares `Type`
anyRowDeclaredType : List Kind -> List Kind -> Bool
anyRowDeclaredType (KRow :: _) (KType :: _) = True
anyRowDeclaredType (_ :: gs) (_ :: ws) = anyRowDeclaredType gs ws
anyRowDeclaredType _ _ = False

firstIfaceMethodLoc : List IfaceMethod -> Option Loc
firstIfaceMethodLoc [] = None
firstIfaceMethodLoc ((IfaceMethod _ mty _ _) :: _) = firstTyLoc mty

-- (d) `requires` chain, same module only: the sub's resolved kinds for the
-- parameters it applies the super to must equal the super's own resolved
-- kinds at those positions.
checkSuperKinds : ModuleCtx ->
  List Decl ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List IfaceMethod ->
  List Super ->
  Unit
checkSuperKinds mctx _ _ _ _ _ [] = ()
checkSuperKinds mctx prog name typarams anns methods ((Super { superHead = sh, superParams = sps }) :: rest) =
  match findIfaceDecl prog sh
    Some (stps, sanns, smethods) =>
      let subKinds =
        map (p => ifaceParamKindsFor mctx.mcGraph typarams anns methods p) sps
      let superKinds =
        ifaceParamKindsDeclAll mctx.mcGraph stps (padAnns stps sanns) smethods
      if listLen subKinds == listLen superKinds
        && not
          (allList
            (pair => kindsEq (fst pair) (snd pair))
            (zipKinds subKinds superKinds)) then
        pushTypeErrorOnceAt
          mctx
          TEffectKindMismatch
          (firstIfaceMethodLoc methods)
          (requiresKindMsg name sh)
    None => ()
  checkSuperKinds mctx prog name typarams anns methods rest

zipKinds : List (List Kind) -> List (List Kind) -> List (List Kind, List Kind)
zipKinds (a :: xs) (b :: ys) = (a, b) :: zipKinds xs ys
zipKinds _ _ = []

findIfaceDecl : List Decl ->
  String ->
  Option (List String, List (Option KindAnn), List IfaceMethod)
findIfaceDecl [] _ = None
findIfaceDecl ((DAttrib _ d) :: rest) n = findIfaceDecl (d :: rest) n
findIfaceDecl ((DInterface { name, typarams, typaramKinds, methods, ... }) :: rest) n
  | name == n = Some (typarams, typaramKinds, methods)
  | otherwise = findIfaceDecl rest n
findIfaceDecl (_ :: rest) n = findIfaceDecl rest n

checkEffectParamsTy : ModuleCtx -> Ty -> Unit
checkEffectParamsTy mctx (TyFun (TyNamed n a d) b) =
  checkAuthorityBinder (mctxAtIfSome (firstTyLoc a) mctx) n a b
  checkBinderDomain mctx n a d
  checkEffectParamsTy mctx a
  checkEffectParamsTy mctx b
checkEffectParamsTy mctx (TyFun a b) =
  checkEffectParamsTy mctx a
  checkEffectParamsTy mctx b
-- An index literal (`Handle "config/*"`) is validated where the index is
-- elaborated (`authArgOf`), which knows the slot's declared domain.
checkEffectParamsTy mctx (TyApp a b) =
  checkEffectParamsTy mctx a
  checkEffectParamsTy mctx b
checkEffectParamsTy mctx (TyAuth _ _) = ()
checkEffectParamsTy mctx (TyTuple ts) = checkEffectParamsTys mctx ts
checkEffectParamsTy mctx (TyEffect labels _ t) =
  checkEffectAtoms mctx labels
  checkEffectParamsTy mctx t
-- A bare row atom (#997) carries written effect params exactly like
-- `TyEffect` above (`Async <Net "example.com"> Unit` must be domain-checked
-- the same as the degenerate `Async (<Net "example.com"> Unit) Unit`) —
-- without this arm the bare spelling silently skipped `T-EFFECT-PARAM`
-- domain validation entirely (S1: a way to mint an invalid `Net` capability
-- no other spelling admits).
checkEffectParamsTy mctx (TyRow labels _ _) = checkEffectAtoms mctx labels
checkEffectParamsTy mctx (TyConstrained _ t) = checkEffectParamsTy mctx t
checkEffectParamsTy mctx _ = ()

checkEffectParamsTys : ModuleCtx -> List Ty -> Unit
checkEffectParamsTys mctx [] = ()
checkEffectParamsTys mctx (t :: ts) =
  checkEffectParamsTy mctx t
  checkEffectParamsTys mctx ts

checkEffectAtoms : ModuleCtx -> List EffAtomTy -> Unit
checkEffectAtoms mctx atoms =
  checkEachEffectAtom mctx atoms
  checkWrittenElementCap mctx atoms

checkEachEffectAtom : ModuleCtx -> List EffAtomTy -> Unit
checkEachEffectAtom mctx [] = ()
checkEachEffectAtom mctx (a :: rest) =
  match a.eatParam
    EPTop => ()
    p =>
      let l = EffLabel a.eatLabel a.eatOrigin
      checkOneEffectParam
        (mctxAtIfSome a.eatLoc mctx)
        a.eatLabel
        (dtopFor mctx.mcGraph l)
        p
  checkEachEffectAtom mctx rest

-- A row keeps the elements it writes for one label as a set, at most
-- `setCardCap` of them once covered ones are dropped, with no merged Set past
-- that size. Past either, inference would fold them into one wider element,
-- so a written bound would admit more than it says; it is refused at the
-- label's first atom instead (`writtenSetProblem`).
checkWrittenElementCap : ModuleCtx -> List EffAtomTy -> Unit
checkWrittenElementCap mctx [] = ()
checkWrittenElementCap mctx (a :: rest) =
  let l = EffLabel a.eatLabel a.eatOrigin
  let onLabel b = labelKey (EffLabel b.eatLabel b.eatOrigin) == labelKey l
  let same = filterList onLabel rest
  let others = filterList (b => not (onLabel b)) rest
  let top = dtopFor mctx.mcGraph l
  match writtenSetProblem (flatMap (writtenElement top) (a :: same))
    Some why =>
      pushTypeError
        (mctxAtIfSome a.eatLoc mctx)
        TEffectParam
        (effectParamMsg a.eatLabel why)
    None => ()
  checkWrittenElementCap mctx others

writtenElement : Param -> EffAtomTy -> List Param
writtenElement top a = match a.eatParam
  EPName _ => []
  EPProduct axes if axisNamesArgument axes => [
    writtenParam
      top
      (EPProduct (filterList (ax => not (isEPName (snd ax))) axes)),
  ]
  p => [writtenParam top p]

-- A written parameter must be an element of its label's domain: a Prefix
-- label takes one non-empty pattern or exact element, a Set label takes a
-- set or a single member, a Product label takes its axes or a bare host
-- pattern, and an atomic label takes nothing.  A named authority is checked at its binder.
-- The rule is `effectParamProblems`; this reports each problem at the atom.
checkOneEffectParam : ModuleCtx -> String -> Param -> EffParamTy -> Unit
checkOneEffectParam mctx l top p =
  fold
    (_ m => pushTypeError mctx TEffectParam (effectParamMsg l m))
    ()
    (effectParamProblems l top p)

-- A binder an effect atom names must have a type the domain can abstract
-- (a `String`, in this increment), and every label naming it must draw
-- from one domain: an authority has exactly one domain.
checkAuthorityBinder : ModuleCtx -> String -> Ty -> Ty -> Unit
checkAuthorityBinder mctx n a rest =
  match filterList (u => fst u == n) (authorityUsesOf mctx rest)
    [] => ()
    (_, top) :: others =>
      if isStringTy a then
        ()
      else
        pushTypeError mctx TAuthorityBinder (binderTypeMsg n (ppTy a))

-- A written binder domain, `(n : String @L)`, names a label whose domain has
-- elements, for a binder of a type the domain can abstract.
checkBinderDomain : ModuleCtx -> String -> Ty -> Option EffAtomTy -> Unit
checkBinderDomain mctx _ _ None = ()
checkBinderDomain outer n a (Some l) =
  let mctx = mctxAtIfSome l.eatLoc outer
  if isStringTy
    a then match dtopFor mctx.mcGraph (EffLabel l.eatLabel l.eatOrigin)
    PUnit =>
      pushTypeError
        mctx
        TEffectParam
        (effectParamMsg l.eatLabel (atomicLabelParamText l.eatLabel))
    top =>
      if l.eatPattern && not (domainHasPatterns top) then
        pushTypeError
          mctx
          TAuthorityPattern
          (patternDomainMsg ("@" ++ l.eatLabel ++ "*") l.eatLabel)
  else
    pushTypeError mctx TAuthorityBinder (binderDomainTypeMsg n (ppTy a))

isStringTy : Ty -> Bool
isStringTy (TyCon { tyConName = n }) = n == "String"
isStringTy _ = False

-- Two Products are one domain only when their schemas agree.
sameDomainTop : Param -> Param -> Bool
sameDomainTop p q = domainKey p == domainKey q

sigVarsWithRows : List (String, Ref Effvar) -> SigVars -> SigVars
sigVarsWithRows rows sv = SigVars { sv | svRows = rows ++ sv.svRows }

export
sigVarsWithAuths : List (String, Ref Authvar) -> SigVars -> SigVars
sigVarsWithAuths auths sv = SigVars { sv | svAuths = auths ++ sv.svAuths }

-- [inner]'s binders shadow [outer]'s of the same name.
sigVarsUnion : SigVars -> SigVars -> SigVars
sigVarsUnion inner outer = SigVars {
  svRows = inner.svRows ++ outer.svRows,
  svAuths = inner.svAuths ++ outer.svAuths,
}

-- An authority has exactly one domain: a name the signature uses at two
-- labels of different domains — as its binder's written domain, an atom's
-- parameter or an index slot, in any pair — is reported once, whatever binds it.
export
reportBinderDomains : ModuleCtx -> Ty -> List (String, Param) -> Unit
reportBinderDomains mctx ty uses =
  fold
    (_ u =>
      if anyList
        (v => fst v == fst u && not (sameDomainTop (snd u) (snd v)))
        uses then
        pushTypeErrorAt
          mctx
          TAuthorityDomain
          (firstTyLoc ty)
          (binderDomainMsg (fst u)))
    ()
    uses

-- A name is an authority binder of the signature only where something binds
-- it: a named argument (of type `String`, else `checkAuthorityBinder` reports
-- it and it binds nothing) or an `Authority`-kinded index slot.  An atom or a
-- qualifier that names it is a USE; a use of a name nothing binds is a type
-- variable used as an authority, reported by `reportUnboundAuthorityNames`.
export
authorityBinderBound : List (String, Ty) -> List String -> String -> Bool
authorityBinderBound named authNames n = match lookupAssoc n named
  Some a => isStringTy a
  None => contains n authNames

-- Every authority name the signature writes (`<L n>`, `String @n`) must be
-- one of its binders.  Resolve admits any name written to the left; here the
-- kind is known, so a type variable used as an authority is reported, once at
-- each atom or qualifier that writes it.
--
-- A qualifier naming a `String` named argument that no atom or index slot of
-- the signature names reads an authority with no domain: an authority is an
-- element of one label's domain (§4.1), and nothing here says which, so the
-- qualifier could bound nothing.  That is `T-AUTHORITY-DOMAIN`, the report
-- for a binder at two domains, since one domain is exactly one.  A qualifier
-- naming a named argument of another type is `T-AUTHORITY-BINDER` here (an
-- atom naming one is reported by `checkAuthorityBinder`).  The names a joined
-- qualifier writes must likewise share one domain.
export
reportUnboundAuthorityNames : ModuleCtx -> Ty -> SigVars -> Unit
reportUnboundAuthorityNames mctx ty sv =
  let named = namedArgTypes ty
  fold
    (_ use =>
      let n = fst use
      let loc = orElseLoc (snd use) (firstTyLoc ty)
      if isSome (lookupAssoc n sv.svAuths) then
        ()
      else match lookupAssoc n named
        Some a =>
          if isStringTy a then
            pushTypeErrorAt mctx TAuthorityDomain loc (binderNoDomainMsg n)
        None => pushTypeErrorAt mctx TAuthorityKind loc (nameNotAuthorityMsg n))
    ()
    (dedupLocated (authorityNamesWritten mctx.mcGraph ty) [])
  fold
    (_ q =>
      fold
        (_ n => match lookupAssoc n named
          Some a =>
            if isStringTy a then
              ()
            else
              pushTypeErrorAt
                mctx
                TAuthorityBinder
                (orElseLoc (snd q) (firstTyLoc ty))
                (qualifierBinderTypeMsg n (ppTy a))
          None => ())
        ()
        (fst q))
    ()
    (writtenQualifiers ty)
  fold
    (_ q =>
      let tops =
        flatMap
          (n => match lookupAssoc n sv.svAuths
            Some cell => [authvarDomain cell]
            None => [])
          (fst q)
      match tops
        top :: rest =>
          if allList (sameDomainTop top) rest then
            ()
          else
            pushTypeErrorAt
              mctx
              TAuthorityDomain
              (orElseLoc (snd q) (firstTyLoc ty))
              (joinDomainMsg (fst q))
        [] => ())
    ()
    (writtenQualifiers ty)

-- First occurrence of each name, keeping its span.
dedupLocated : List (String, Option Loc) ->
  List (String, Option Loc) ->
  List (String, Option Loc)
dedupLocated [] acc = reverseL acc
dedupLocated ((n, l) :: rest) acc =
  if isSome (lookupAssoc n acc) then
    dedupLocated rest acc
  else
    dedupLocated rest ((n, l) :: acc)

-- Every qualifier the type writes, its names with its span.
writtenQualifiers : Ty -> List (List String, Option Loc)
writtenQualifiers (TyQual t ps l) = (authTermNames ps, l) :: writtenQualifiers t
writtenQualifiers (TyEffect _ _ t) = writtenQualifiers t
writtenQualifiers (TyApp a b) = writtenQualifiers a ++ writtenQualifiers b
writtenQualifiers (TyFun a b) = writtenQualifiers a ++ writtenQualifiers b
writtenQualifiers (TyTuple ts) = flatMap writtenQualifiers ts
writtenQualifiers (TyConstrained _ t) = writtenQualifiers t
writtenQualifiers (TyNamed _ t _) = writtenQualifiers t
writtenQualifiers _ = []

-- The names written in authority position, atom parameters and qualifiers,
-- each with the span of the atom or qualifier that writes it.
authorityNamesWritten : GraphCtx -> Ty -> List (String, Option Loc)
authorityNamesWritten gctx (TyQual t ps l) =
  map (n => (n, l)) (authTermNames ps) ++ authorityNamesWritten gctx t
authorityNamesWritten gctx (TyEffect atoms _ t) =
  flatMap (atomAuthorityName gctx) atoms ++ authorityNamesWritten gctx t
authorityNamesWritten gctx (TyRow atoms _ _) =
  flatMap (atomAuthorityName gctx) atoms
authorityNamesWritten gctx (TyApp a b) =
  authorityNamesWritten gctx a ++ authorityNamesWritten gctx b
authorityNamesWritten gctx (TyFun a b) =
  authorityNamesWritten gctx a ++ authorityNamesWritten gctx b
authorityNamesWritten gctx (TyTuple ts) =
  flatMap (authorityNamesWritten gctx) ts
authorityNamesWritten gctx (TyConstrained _ t) = authorityNamesWritten gctx t
authorityNamesWritten gctx (TyNamed _ t _) = authorityNamesWritten gctx t
authorityNamesWritten gctx _ = []

atomAuthorityName : GraphCtx -> EffAtomTy -> List (String, Option Loc)
atomAuthorityName gctx a = map (b => (fst b, a.eatLoc)) (namedAtomBinder gctx a)

export
namedArgTypes : Ty -> List (String, Ty)
namedArgTypes (TyFun (TyNamed n a _) b) = (n, a) :: namedArgTypes b
namedArgTypes (TyFun _ b) = namedArgTypes b
namedArgTypes (TyConstrained _ t) = namedArgTypes t
namedArgTypes _ = []

-- Every authority use a signature writes: a binder an atom names, each with
-- the domain top of its label, and a bare name in an `Authority`-kinded
-- index slot, with the slot's declared label's.  A name used at two domains
-- is diagnosed by `checkAuthorityBinder`; the first use decides here.
authorityUsesOf : ModuleCtx -> Ty -> List (String, Param)
authorityUsesOf mctx ty =
  binderDomainsIn mctx.mcGraph ty
    ++ namedAtomBinders mctx.mcGraph ty
    ++ authArgBindersIn mctx ty

-- The binders a signature writes a domain for, `(n : String @L)`, each with
-- the domain its authority is drawn from: the label's, or for a Product label
-- its primary axis's, the axis a string lifts into.  An atomic label has no
-- domain and gives none (`checkBinderDomain` reports it).
export
binderDomainsIn : GraphCtx -> Ty -> List (String, Param)
binderDomainsIn gctx (TyNamed n t (Some l)) =
  let own = match dtopFor gctx (EffLabel l.eatLabel l.eatOrigin)
    PUnit => []
    PProduct ((_, axis) :: _) => [(n, subTopOf axis)]
    top => [(n, top)]
  own ++ binderDomainsIn gctx t
binderDomainsIn gctx (TyNamed _ t None) = binderDomainsIn gctx t
binderDomainsIn gctx (TyFun a b) =
  binderDomainsIn gctx a ++ binderDomainsIn gctx b
binderDomainsIn gctx (TyApp a b) =
  binderDomainsIn gctx a ++ binderDomainsIn gctx b
binderDomainsIn gctx (TyTuple ts) = flatMap (binderDomainsIn gctx) ts
binderDomainsIn gctx (TyEffect _ _ t) = binderDomainsIn gctx t
binderDomainsIn gctx (TyConstrained _ t) = binderDomainsIn gctx t
binderDomainsIn gctx (TyQual t _ _) = binderDomainsIn gctx t
binderDomainsIn gctx _ = []

-- The bare names sitting in `Authority`-kinded argument slots of registered
-- heads, with the slot's domain: the twin of `rowArgNamesIn` for authorities.
export
authArgBindersIn : ModuleCtx -> Ty -> List (String, Param)
authArgBindersIn mctx ty =
  authSlotNamesIn mctx (kauthArgVarNames mctx.mcGraph) ty

-- The names sitting in pattern-ranging `Authority L*` slots, the slots a
-- bare name inherits its range from (`binderIsPattern`).
export
patternSlotNamesIn : ModuleCtx -> Ty -> List String
patternSlotNamesIn mctx ty = authSlotNamesIn mctx patternArgVarNames ty

patternArgVarNames : List Kind -> List Ty -> List String
patternArgVarNames ((KAuth _ True) :: ks) ((TyVar n) :: as2) =
  n :: patternArgVarNames ks as2
patternArgVarNames ((KAuth _ True) :: ks) ((TyAuth ps _) :: as2) =
  authTermNames ps ++ patternArgVarNames ks as2
patternArgVarNames (_ :: ks) (_ :: as2) = patternArgVarNames ks as2
patternArgVarNames _ _ = []

kauthArgVarNames : GraphCtx -> List Kind -> List Ty -> List (String, Param)
kauthArgVarNames gctx ((KAuth l _) :: ks) ((TyVar n) :: as2) =
  (n, dtopFor gctx l) :: kauthArgVarNames gctx ks as2
kauthArgVarNames gctx ((KAuth l _) :: ks) ((TyAuth ps _) :: as2) =
  map (n => (n, dtopFor gctx l)) (authTermNames ps)
    ++ kauthArgVarNames gctx ks as2
-- A join of names only parses as a row (`authArgOf` refuses it there); its
-- names are still authorities the slot's label ranges over.
kauthArgVarNames gctx ((KAuth l _) :: ks) ((TyRow [] names _) :: as2) =
  map (n => (n, dtopFor gctx l)) names ++ kauthArgVarNames gctx ks as2
kauthArgVarNames gctx (_ :: ks) (_ :: as2) = kauthArgVarNames gctx ks as2
kauthArgVarNames gctx _ _ = []

export
namedAtomBinders : GraphCtx -> Ty -> List (String, Param)
namedAtomBinders gctx ty = atomBindersIn (namedAtomBinder gctx) ty

-- The names an atom's parameter binds, each with its domain: the label's for
-- the whole parameter, and for a product's axis that axis's own. An axis the
-- schema does not declare binds nothing; it is reported as unknown.
namedAtomBinder : GraphCtx -> EffAtomTy -> List (String, Param)
namedAtomBinder gctx a = match a.eatParam
  EPName n => [(n, dtopFor gctx (EffLabel a.eatLabel a.eatOrigin))]
  _ => axisAtomBinders gctx a

axisAtomBinders : GraphCtx -> EffAtomTy -> List (String, Param)
axisAtomBinders gctx a = match (
  a.eatParam,
  dtopFor gctx (EffLabel a.eatLabel a.eatOrigin),
)
  (EPProduct axes, PProduct schema) =>
    flatMap
      (ax => match (snd ax, lookupAxis (fst ax) schema)
        (EPName n, Some top) => [(n, subTopOf top)]
        _ => [])
      axes
  _ => []

-- build a row from an arrow's return-position AST type; a named tail resolves
-- through [etbl] for sharing, an absent/anonymous one is closed
astEffrowE : GraphCtx -> SigVars -> Ty -> EffRow
astEffrowE gctx etbl (TyEffect labels tail _) =
  EffRow (atomsOfWrittenIn gctx etbl labels) (tailCell gctx etbl tail)
astEffrowE gctx _ _ = pureRow

-- Only a leading row describes forcing a binding. Rows reached through an
-- arrow remain that arrow's latent effects, even for a function-valued binding.
export
bindingForceFromAst : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Ty ->
  EffRow
bindingForceFromAst mctx etbl tvs ty =
  optionOr pureRow (writtenBindingForce mctx etbl tvs ty)

-- The leading row of a binding's written type.  An alias means its expansion
-- here as everywhere a type is written: `v : SS` with `type SS = <Sign> Int`
-- is bounded by `<Sign>` exactly as `v : <Sign> Int` is.
export
writtenBindingForce : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Ty ->
  Option EffRow
writtenBindingForce mctx etbl tvs (TyConstrained _ ty) =
  writtenBindingForce mctx etbl tvs ty
writtenBindingForce mctx etbl _ (ty@(TyEffect _ _ _)) =
  Some (astEffrowE mctx.mcGraph etbl ty)
writtenBindingForce mctx etbl tvs ty = match aliasScopeE mctx etbl tvs ty
  Some (etbl2, tvs2, rhs) => writtenBindingForce mctx etbl2 tvs2 rhs
  None => None

-- The row an arrow's written result performs: the `<…>` it leads with, seen
-- through aliases, so `Int -> SS` elaborates as `Int -> <Sign> Int`.  An alias
-- whose expansion is an arrow or any other unwrapped type adds no row, as the
-- written-out type would not.
returnRowE : ModuleCtx -> SigVars -> List (String, Mono) -> Ty -> EffRow
returnRowE mctx etbl _ (ty@(TyEffect _ _ _)) = astEffrowE mctx.mcGraph etbl ty
returnRowE mctx etbl tvs ty = match aliasScopeE mctx etbl tvs ty
  Some (etbl2, tvs2, rhs) => returnRowE mctx etbl2 tvs2 rhs
  None => pureRow

-- The tail cell of a written row.  No names is a closed row; one name is that
-- var's shared cell; several (#821) is their JOIN, so `<Stdout | e | e2>`
-- elaborates to the row performing Stdout plus whatever either var does.  A
-- name the table does not know contributes nothing, which is what the
-- single-name case has always done by yielding `None`.
tailCell : GraphCtx -> SigVars -> List String -> Option (Ref Effvar)
tailCell gctx _ [] = None
tailCell gctx etbl [n] = lookupAssoc n etbl.svRows
tailCell gctx etbl ns = match tailCellsOf etbl ns
  [] => None
  [cell] => Some cell
  cells => Some (joinCellOf gctx cells)

tailCellsOf : SigVars -> List String -> List (Ref Effvar)
tailCellsOf _ [] = []
tailCellsOf etbl (n :: ns) = match lookupAssoc n etbl.svRows
  Some cell => cell :: tailCellsOf etbl ns
  None => tailCellsOf etbl ns

export
fromAstType : ModuleCtx -> List (String, Mono) -> Ty -> Mono
fromAstType mctx tvs ty = fromAstTypeE mctx emptySigVars tvs ty

export
fromAstTypeE : ModuleCtx -> SigVars -> List (String, Mono) -> Ty -> Mono
-- OCCURRENCE MINT (#1110): the head Mono's identity is the identity resolve
-- stamped on the `Ty.TyCon` this conversion is reading, and the record pattern
-- puts it in scope for free — there is nowhere else it could come from and no
-- ambient module id to get it wrong from.
fromAstTypeE mctx etbl tvs (TyCon { tyConName = n, tyConOrigin = o }) =
  match lookupTab (tyTabKey o n) mctx.mcCells.aliasTableRef.value
    -- Transparent non-parameterized alias (`type Foo = Int`): expand to its RHS,
    -- recursively so alias-of-alias (`type A = Int; type B = A`) flattens.  Cycle
    -- rejection is deferred (stage 4); the non-cyclic corpus terminates.
    Some (params, rhs) if listLen params == 0 => fromAstTypeE mctx etbl tvs rhs
    -- A parameterized alias used UNAPPLIED (`x : Pair`): a type alias is not a
    -- first-class type constructor (DESIGN §3/§9 fork 2), so it must be saturated.
    -- Reject with an arity error and keep the bare TCon so inference continues.
    Some (params, _) =>
      pushTypeErrorOnce mctx TAliasArity (aliasArityMsg n (listLen params) 0)
      tconFrom o n
    _ => tconFrom o n
-- RIGID PRODUCER 1 of 2 (#1110).  A `TyVar` bound by the enclosing scheme
-- resolves to its mono; the FALLBACK — an unbound type-parameter name — is a
-- rigid variable, not a type constructor.  See `Mono.TRigid`.
fromAstTypeE mctx etbl tvs (TyVar n) = match lookupAssoc n tvs
  Some t => t
  None =>
    -- An authority binder written where a TYPE goes (`List p` for an
    -- `Authority` binder `p`): a kind error, recovered as a rigid.
    if isSome (lookupAssoc n etbl.svAuths) then
      pushTypeErrorOnce mctx TAuthorityKind (authorityAsTypeMsg n)
    TRigid n
-- A written authority term reached an ordinary (`Type`) slot: only an
-- `Authority`-kinded argument slot consumes one (`kindArgMono`).
fromAstTypeE mctx _ _ (TyAuth p loc) =
  pushTypeErrorOncePerSite mctx TAuthorityKind loc (authorityTermAsTypeMsg p)
  tconBuiltin "Unit"
fromAstTypeE mctx etbl tvs (TyApp a b) = match tyAppSpine (TyApp a b)
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    fromAstTypeApp mctx etbl tvs o n args
  -- #822: an ABSTRACT head with known kinds — an interface typaram of graded kind
  -- (`f e a`, `f : Row -> Type -> Type`).  Anything else stays opaque.
  (TyVar h, args) => fromAstTypeVarApp mctx etbl tvs h args a b
  _ => TApp (fromAstTypeE mctx etbl tvs a) (fromAstTypeE mctx etbl tvs b)
fromAstTypeE mctx etbl tvs (TyFun a b) =
  TFun
    (fromAstDomainE mctx etbl tvs a)
    (returnRowE mctx etbl tvs b)
    (fromAstTypeE mctx etbl tvs (stripEff b))
fromAstTypeE mctx etbl tvs (TyTuple ts) =
  tupleMono (map (fromAstTypeE mctx etbl tvs) ts)
fromAstTypeE mctx etbl tvs (TyEffect _ _ t) = fromAstTypeE mctx etbl tvs t
fromAstTypeE mctx etbl tvs (TyConstrained _ t) = fromAstTypeE mctx etbl tvs t
-- A binder reached outside an arrow domain is a resolve error already; its
-- type still elaborates so inference can continue.
fromAstTypeE mctx etbl tvs (TyNamed _ t _) = fromAstTypeE mctx etbl tvs t
fromAstTypeE mctx etbl tvs (TyQual t ps loc) =
  qualifyByTerms mctx etbl ps loc (fromAstTypeE mctx etbl tvs t)

-- A bare row atom (#997) reached here means it landed in an ordinary
-- (non-KRow) type slot — `kindArgMono`'s KRow branch (below) is what
-- normally consumes a `TyRow`, routing it through `rowArgOf` instead. Unlike
-- a misplaced `TyEffect` (which unwraps to a REAL user-written type and can
-- keep inferring silently), a `TyRow` has no wrapped type at all — inventing
-- one from nothing would turn a misplaced row (`List <Stdout>`,
-- `data Holder = Holder <Stdout>`) into a silent mistype (`List Unit`).  Push
-- a real diagnostic; `TCon "Unit"` is POST-error recovery only, so inference
-- can keep going, not a value anything should rely on.
fromAstTypeE mctx etbl tvs (TyRow labels tail loc) =
  pushTypeErrorOncePerSite
    mctx
    TEffectKindMismatch
    loc
    (rowKindMismatchMsg labels tail)
  tconBuiltin "Unit"

-- An arrow's domain: a named argument whose name an effect atom refers to is
-- qualified by that binder's authority; an unreferenced name binds nothing.
fromAstDomainE : ModuleCtx -> SigVars -> List (String, Mono) -> Ty -> Mono
fromAstDomainE mctx etbl tvs (TyNamed n t _) =
  qualifyBy etbl n (fromAstTypeE mctx etbl tvs t)
fromAstDomainE mctx etbl tvs t = fromAstTypeE mctx etbl tvs t

qualifyBy : SigVars -> String -> Mono -> Mono
qualifyBy etbl n t = qualifyByAll etbl [n] t

-- A written qualifier's terms: its names are bounded as `qualifyByAll` bounds
-- them, and a literal term is an element of the names' domain, or of the
-- Prefix domain (a string's own) when the qualifier names none, so
-- `String @("a.com/*" | "b.com/*")` is bounded by the set of both.
qualifyByTerms : ModuleCtx ->
  SigVars ->
  List EffParamTy ->
  Option Loc ->
  Mono ->
  Mono
qualifyByTerms mctx etbl ps loc t =
  let names = authTermNames ps
  let lits = filterList (p => not (isEPName p)) ps
  match lits
    [] => qualifyByAll etbl names t
    _ =>
      let cells =
        flatMap
          (n => match lookupAssoc n etbl.svAuths
            Some cell => [cell]
            None => [])
          names
      if listLen cells /= listLen names then
        t
      else
        let top = match cells
          cell :: _ => authvarDomain cell
          [] => literalDomainTop lits
        let src = qualifierSource escStr ps
        let problems =
          if isEmptyL cells && anyList isEPProduct lits then
            [
              "a qualifier written as axes needs a binder that names its label; write `(p : String) -> <Web p> ... String @(p | Host=\"...\")`",
            ]
          else
            writtenTermProblems "qualifier" top lits
        fold
          (_ why =>
            pushTypeErrorOncePerSite
              mctx
              TEffectParam
              loc
              "invalid authority in the qualifier `\{src}`: \{why}")
          ()
          problems
        TQual
          t
          (authJoinAll
            (map AVar cells ++ map (p => AConst (writtenParam top p)) lits))

-- The domain a qualifier that names no binder is written in, read from its
-- literals' shape: a set is a Set domain's element, and anything else a
-- Prefix pattern (a string's own domain). Product axes have no schema to
-- read without a binder, so a Product literal needs one to name its label.
literalDomainTop : List EffParamTy -> Param
literalDomainTop lits = if allList isEPSet lits then PSet None else PPrefix None

isEPSet : EffParamTy -> Bool
isEPSet (EPSet _) = True
isEPSet _ = False

-- The problems of a written authority term's literals, as elements of the
-- domain whose top is [top]: each literal as an atom's parameter is checked,
-- and all of them together as a bound (`writtenSetProblem`). A term with a
-- problem must never be read as the whole domain.
writtenTermProblems : String -> Param -> List EffParamTy -> List String
writtenTermProblems l top lits =
  let each = flatMap (effectParamProblems l top) lits
  match each
    [] => match writtenSetProblem (map (writtenParam top) lits)
      Some why => [why]
      None => []
    _ => each

isEPProduct : EffParamTy -> Bool
isEPProduct (EPProduct _) = True
isEPProduct _ = False

isEPName : EffParamTy -> Bool
isEPName (EPName _) = True
isEPName _ = False

-- A written product one of whose axes names an argument.
axisNamesArgument : List (String, EffParamTy) -> Bool
axisNamesArgument axes = anyList (a => isEPName (snd a)) axes

-- A qualifier's names are bounded by the join of their authorities.  A name
-- that is not an authority binder here is reported by
-- `reportUnboundAuthorityNames`, and the qualifier then bounds nothing.
qualifyByAll : SigVars -> List String -> Mono -> Mono
qualifyByAll etbl ns t =
  let cells =
    flatMap
      (n => match lookupAssoc n etbl.svAuths
        Some cell => [AVar cell]
        None => [])
      ns
  if isNonEmptyL cells && listLen cells == listLen ns then
    TQual t (authJoinAll cells)
  else
    t

-- the opaque fall-through for a TyCon-headed spine: keep the head as a bare
-- `TCon n` and apply the (alias-expanded) argument Monos left-nested.  This is
-- byte-identical to the legacy `TApp (fromAstTypeE a) (fromAstTypeE b)` recursion
-- for a non-alias head, but it does NOT re-dispatch the head through
-- `fromAstTypeE` — critical now that the head being an *alias* has side-effects
-- (the unapplied-alias arity error), and Medaka is strict so a pre-built fallback
-- would fire that error even on the expansion path.
--
-- The `TyConOrigin` parameter (#1110) is the head's ACQUIRED identity, carried
-- from the `Ty.TyCon` `fromAstTypeE`/`fromAstTypeApp` destructured — it is not a
-- new fact and nothing here decides it.  It sits beside the head NAME because
-- that is the one argument it must never drift away from; the spine head is the
-- only `TCon` this function mints.
appFallback : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  TyConOrigin ->
  String ->
  List Ty ->
  Mono
appFallback mctx _ _ o n [] = tconFrom o n
appFallback mctx etbl tvs o n (a :: as2) =
  foldAppFallback
    mctx
    etbl
    tvs
    (TApp (tconFrom o n) (fromAstTypeE mctx etbl tvs a))
    as2

foldAppFallback : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Mono ->
  List Ty ->
  Mono
foldAppFallback mctx _ _ acc [] = acc
foldAppFallback mctx etbl tvs acc (a :: as2) =
  foldAppFallback mctx etbl tvs (TApp acc (fromAstTypeE mctx etbl tvs a)) as2

-- a TyCon-headed type-app: a parameterized type-ALIAS head is expanded by binding
-- its params to the supplied argument Monos and recursing on the RHS (transparent,
-- transitive — an alias RHS that names another alias re-expands).  Otherwise: when
-- the head is a data type with a KRow param, refold the spine kind-directed (KRow
-- arg → TEff row); else the opaque `appFallback`.
-- (`o` is the head's acquired identity — see `appFallback`'s note.)
-- `key` is minted ONCE and shared by both lookups below (#1111 A-2.3 follow-up):
-- `tyTabKey` → `mkIdent` → `identOriginOf` allocates on the way (an `Ident`, an
-- `Option`, the `TkIdent`/`TkBare` wrapper), so minting it twice per call — once
-- for `aliasTableRef`, again for `dataParamKindsRef` in the `_ =>` arm below —
-- doubled the allocation on the COMMON path (every non-alias type application)
-- for no reason: the alias arms above the `_ =>` arm never reach the second
-- lookup at all, so they pay for the hoisted `let` exactly what they always
-- paid for the first one. This is a redundant-allocation removal, not a
-- measured perf win — `test/bench.sh` does not run on this box (#1187) and
-- `diff_compiler_perf_scaling` grades a growth ratio, which cannot see a
-- constant factor either way.
fromAstTypeApp : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  TyConOrigin ->
  String ->
  List Ty ->
  Mono
fromAstTypeApp mctx etbl tvs o n args =
  let key = tyTabKey o n
  match lookupTab key mctx.mcCells.aliasTableRef.value
    -- Saturated parameterized alias: bind params → arg Monos (alias params shadow
    -- outer tvs of the same name) and expand the RHS through the same seam.
    -- #2121 / §6.2: each argument elaborates at the alias parameter's DECLARED
    -- kind — an `Effect` parameter binds a row cell in the effect table so the
    -- RHS's own occurrence of it (`Later e Int`) reads the written row.
    Some (params, rhs) if listLen params == listLen args =>
      let (etbl2, tvs2) = aliasArgScope mctx etbl tvs key params args
      fromAstTypeE mctx etbl2 tvs2 rhs
    -- Alias applied to the wrong arity: reject, keep the opaque fallback.
    Some (params, _) =>
      pushTypeErrorOnce
        mctx
        TAliasArity
        (aliasArityMsg n (listLen params) (listLen args))
      appFallback mctx etbl tvs o n args
    _ => match lookupTab key mctx.mcCells.dataParamKindsRef.value
      Some kinds if listLen kinds == listLen args =>
        foldAppKinds mctx etbl tvs (tconFrom o n) kinds args
      _ => appFallback mctx etbl tvs o n args

-- The scope an applied alias's right-hand side elaborates in: the caller's,
-- with the alias's parameters bound to the arguments (alias parameters shadow
-- the caller's names).
aliasArgScope : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  TabKey ->
  List String ->
  List Ty ->
  (SigVars, List (String, Mono))
aliasArgScope mctx etbl tvs key params args =
  let kinds =
    optionOrElse
      (_ => map (_ => KType) params)
      (lookupTab key mctx.mcCells.dataParamKindsRef.value)
  let bound = aliasArgBindings mctx etbl tvs params kinds args
  (sigVarsUnion (fst bound) etbl, snd bound ++ tvs)

-- A saturated alias's right-hand side with the scope it elaborates in, or
-- `None` when the written type is not one.  The readers of a written row
-- (`writtenBindingForce`, `returnRowE`) look through an alias with this, so
-- they read the row `fromAstTypeE` elaborates.  A misapplied alias is not
-- looked through; `fromAstTypeApp` reports it.
aliasScopeE : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Ty ->
  Option (SigVars, List (String, Mono), Ty)
aliasScopeE mctx etbl tvs ty =
  if isEmptyL mctx.mcCells.aliasTableRef.value then
    None
  else match tyAppSpine ty
    (TyCon { tyConName = n, tyConOrigin = o }, args) =>
      let key = tyTabKey o n
      match lookupTab key mctx.mcCells.aliasTableRef.value
        Some (params, rhs) if listLen params == listLen args =>
          let (etbl2, tvs2) = aliasArgScope mctx etbl tvs key params args
          Some (etbl2, tvs2, rhs)
        _ => None
    _ => None

-- the alias parameters bound positionally at their declared kinds: (effect
-- table additions, type table additions).  Expansion is a substitution: each
-- parameter denotes its argument, elaborated once in the caller's scope, so
-- the right-hand side reads exactly what the caller would have written in its
-- place.  A KType parameter binds the elaborated Mono; a KRow parameter binds
-- the argument row itself (`aliasRowParamCell`).  Nothing is unified, so no
-- variable the signature does not quantify can stand in for one it does.
aliasArgBindings : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  List String ->
  List Kind ->
  List Ty ->
  (SigVars, List (String, Mono))
aliasArgBindings mctx etbl tvs (p :: ps) (KRow :: ks) (arg :: args) =
  let cell = aliasRowParamCell mctx.mcGraph (rowArgOf mctx etbl arg)
  let rest = aliasArgBindings mctx etbl tvs ps ks args
  (sigVarsWithRows [(p, cell)] (fst rest), snd rest)
-- An `Authority` alias parameter stands for the written argument wherever
-- the right-hand side names it: a cell linked to the term, so expansion is a
-- substitution and records no obligation.
aliasArgBindings mctx etbl tvs (p :: ps) ((KAuth l pat) :: ks) (arg :: args) =
  let cell = freshAuthvarRanged mctx (dtopFor mctx.mcGraph l) pat (Some p)
  linkAuthvar cell (authArgOf mctx etbl tvs l pat arg)
  let rest = aliasArgBindings mctx etbl tvs ps ks args
  (sigVarsWithAuths [(p, cell)] (fst rest), snd rest)
aliasArgBindings mctx etbl tvs (p :: ps) (_ :: ks) (arg :: args) =
  let rest = aliasArgBindings mctx etbl tvs ps ks args
  (fst rest, (p, fromAstTypeE mctx etbl tvs arg) :: snd rest)
aliasArgBindings mctx _ _ _ _ _ = (emptySigVars, [])

-- The effect-table cell an `Effect` alias parameter reads as.  A bare row
-- variable argument (`S e Int`) is the caller's own cell for `e`, the one the
-- written-out signature reads.  Any other row (`S <Net | e> Int`, `S <> Int`)
-- is a cell already solved to that row, the indirection every solved row
-- variable already is.
aliasRowParamCell : GraphCtx -> EffRow -> Ref Effvar
aliasRowParamCell gctx (EffRow [] (Some cell)) = cell
aliasRowParamCell gctx row = Ref (ELink (newEffvarId gctx ()) row)

-- #822: a spine headed by an interface typaram of GRADED kind — `f e b` must yield
-- the SAME Mono shape a row-indexed data head does (`Async e b` =
-- `TApp (TApp (TCon Async) (TEff row)) b`), which is exactly what lets the instance
-- head unify with the method's abstract one.  The head itself still elaborates as an
-- ordinary tyvar: the grade rides the type INDEX, never the dictionary
-- (EFFECTS-SEMANTICS §6 "Erasure and dispatch are untouched").
--
-- This reads the CALLER'S OWN CLASSIFICATION out of [etbl]/[tvs] rather than
-- re-deriving it from a kind table, and that is the point.  Every seam builds the
-- pair as `etbl = freshEffMap (effTailNames ty ++ rowArgNamesIn scope ty)` and
-- `tvs = freshTvMap (tyVarNames ty MINUS rowArgNamesIn scope ty)`, so "seeded into
-- etbl AND withheld from tvs" is precisely "this seam called it a row" — the two
-- cannot disagree, and there is no name-keyed global to leak.
--
-- It fires at seams with NO graded scope, and that is CORRECT — an earlier version
-- of this comment claimed the opposite ("an unscoped seam withholds nothing, so this
-- arm never fires there"), which was simply false.  A KROW DATA slot withholds too:
-- `rowArgNamesIn` reports the `e` of `D e f` from `dataParamKindsRef` with no interface
-- in the file at all, and `registerVariants`' payload seam withholds by construction
-- (`tvs = ktypeTvs` is KType-only, `etbl = krowEtbl` is KRow-only).  So in
-- `data D e f = MkD (Unit -> <e> Unit) (f e Int)`, the `e` of the abstract-headed
-- `f e Int` reaches this arm unscoped.
-- The result is a FIX, not a leak: pre-#822 that `e` was withheld from tvs and then
-- elaborated by `fromAstTypeE (TyVar n)`'s `optionOr (TCon n)` fallback into a
-- FABRICATED RIGID `TCon "e"` — `getInner : D e f -> f e Int` inferred as
-- `D a b -> b e Int`, an opaque constant no caller can ever satisfy.  It now infers
-- `D a b -> b a Int`.  Pinned by typecheck_error_fixtures/graded_krow_data_slot_abstract_head.mdk.
fromAstTypeVarApp : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  String ->
  List Ty ->
  Ty ->
  Ty ->
  Mono
fromAstTypeVarApp mctx etbl tvs h args a b
  | anyRowSlotArg etbl tvs args =
    foldRowSlotArgs mctx etbl tvs (fromAstTypeE mctx etbl tvs (TyVar h)) args
  | otherwise =
    TApp (fromAstTypeE mctx etbl tvs a) (fromAstTypeE mctx etbl tvs b)

-- A bare NAME is a row slot arg iff the caller seeded it into [etbl] and deliberately
-- kept it out of [tvs].
isRowSlotArg : SigVars -> List (String, Mono) -> Ty -> Bool
isRowSlotArg etbl tvs (TyVar n) =
  isSome (lookupAssoc n etbl.svRows) && isNone (lookupAssoc n tvs)
-- A WRITTEN row (#997) is a row, full stop — no name test, and in particular no `Some n`
-- test.  `<Stdout | e>` and `<>` are the same construct with and without a tail, and a
-- `TyRow` is only ever legal in a row-kinded position anyway (that is what
-- `fromAstTypeE`'s TyRow clause exists to say).
--
-- Requiring an open tail here was an S1: it made the SPEC'S OWN `gpure : a -> f <> a`
-- (EFFECTS-SEMANTICS §6, one of the four canonical graded signatures) unspellable — the
-- closed row fell to the opaque fallback and drew `T-EFFECT-KIND-MISMATCH`, a message
-- asserting the slot "isn't row-kinded" when slot 0 of `f` had just been INFERRED KRow
-- from a sibling method.  The same `<>` on a concrete head (`Async <> a`) was accepted,
-- so the two halves of the feature disagreed on one spelling with the abstract half
-- misdiagnosing why.  #823 cannot add the graded core interfaces without this.
isRowSlotArg _ _ (TyRow _ _ _) = True
isRowSlotArg _ _ _ = False

-- monomorphic and short-circuiting on purpose (compiler/AGENTS.md): this runs on
-- every var-headed type-application node the elaborator meets.
anyRowSlotArg : SigVars -> List (String, Mono) -> List Ty -> Bool
anyRowSlotArg _ _ [] = False
anyRowSlotArg etbl tvs (t :: rest) =
  isRowSlotArg etbl tvs t || anyRowSlotArg etbl tvs rest

foldRowSlotArgs : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Mono ->
  List Ty ->
  Mono
foldRowSlotArgs mctx _ _ acc [] = acc
foldRowSlotArgs mctx etbl tvs acc (arg :: rest) =
  foldRowSlotArgs
    mctx
    etbl
    tvs
    (TApp acc (rowSlotArgMono mctx etbl tvs arg))
    rest

rowSlotArgMono : ModuleCtx -> SigVars -> List (String, Mono) -> Ty -> Mono
rowSlotArgMono mctx etbl tvs arg
  | isRowSlotArg etbl tvs arg = TEff (rowArgOf mctx etbl arg)
  | otherwise = fromAstTypeE mctx etbl tvs arg

-- refold a kinded type-app spine: a KType arg recurses, a KRow arg becomes a
-- TEff row (resolved through the shared etbl, so it aliases the field/sig tail).
foldAppKinds : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Mono ->
  List Kind ->
  List Ty ->
  Mono
foldAppKinds mctx _ _ acc [] [] = acc
foldAppKinds mctx etbl tvs acc (k :: ks) (a :: as2) =
  foldAppKinds mctx etbl tvs (TApp acc (kindArgMono mctx etbl tvs k a)) ks as2
foldAppKinds mctx _ _ acc _ _ = acc

kindArgMono : ModuleCtx -> SigVars -> List (String, Mono) -> Kind -> Ty -> Mono
kindArgMono mctx etbl tvs KType arg = fromAstTypeE mctx etbl tvs arg
kindArgMono mctx etbl tvs KRow arg = TEff (rowArgOf mctx etbl arg)
-- A pattern slot holds a pattern whatever was written in it: a term outside
-- the range is reported (`authArgOf`) and read as the least pattern above it,
-- so the report is not repeated at every use of the type.
kindArgMono mctx etbl tvs (KAuth l pat) arg =
  let q = authArgOf mctx etbl tvs l pat arg
  TAuth (if pat then authPatternClose q else q)

-- An authority sitting in an `Authority`-kinded slot: a bare name resolves
-- through the signature's binders (a named argument, another index slot, or
-- the enclosing data declaration's parameter); a written term is the
-- element of the slot's domain it spells (`*` the top); anything else is a
-- kind error recovered as the top.
authArgOf : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  EffLabel ->
  Bool ->
  Ty ->
  Authority
authArgOf mctx etbl tvs l pat (TyVar n) = match lookupAssoc n etbl.svAuths
  Some cell =>
    if pat && not (authvarIsPattern cell) then
      pushTypeErrorOnce
        mctx
        TAuthorityPattern
        (ordinaryInPatternSlotMsg n (effLabelName l))
    AVar cell
  None =>
    pushTypeErrorOnce mctx TAuthorityKind (if isSome (lookupAssoc n tvs) then
      typeVarAsAuthorityMsg n (effLabelName l)
    else
      nameNotAuthorityMsg n)
    authTop (dtopFor mctx.mcGraph l)
authArgOf mctx etbl tvs l pat (TyAuth ps loc) =
  let top = dtopFor mctx.mcGraph l
  let lits = filterList (p => not (isEPName p)) ps
  let problems = writtenTermProblems (effLabelName l) top lits
  fold
    (_ why =>
      pushTypeErrorOncePerSite
        mctx
        TEffectParam
        loc
        (effectParamMsg (effLabelName l) why))
    ()
    problems
  if pat && isEmptyL problems then
    fold
      (_ lit =>
        let written = writtenParam top lit
        if isPatternParam written then
          ()
        else
          pushTypeErrorOncePerSite
            mctx
            TAuthorityPattern
            loc
            (exactInPatternSlotMsg
              (effLabelName l)
              (authTermsSurface escStr [lit])
              (ppAuthArg (Ref []) (Ref 0) (AConst (extendParam written)))))
      ()
      lits
  authJoinAll (map (authTermOf mctx etbl tvs l pat) ps)
authArgOf mctx etbl _ l pat ty =
  match ordinaryBinderIn etbl pat ty
    Some n =>
      pushTypeErrorOncePerSite
        mctx
        TAuthorityPattern
        (firstTyLoc ty)
        (ordinaryInPatternSlotMsg n (effLabelName l))
    None =>
      pushTypeErrorOncePerSite
        mctx
        TAuthorityKind
        (firstTyLoc ty)
        (typeAsAuthorityMsg (ppTy ty) (effLabelName l ++ patternMark pat))
  authTop (dtopFor mctx.mcGraph l)

-- An ordinary authority binder a malformed argument of a pattern slot names
-- (`(p | q)`, a join of names, is read as a row): that it ranges over the
-- whole domain is the more specific report.
ordinaryBinderIn : SigVars -> Bool -> Ty -> Option String
ordinaryBinderIn etbl True (TyRow [] names _) =
  match filterList (n => isOrdinaryBinder etbl n) names
    n :: _ => Some n
    [] => None
ordinaryBinderIn _ _ _ = None

isOrdinaryBinder : SigVars -> String -> Bool
isOrdinaryBinder etbl n = match lookupAssoc n etbl.svAuths
  Some cell => not (authvarIsPattern cell)
  None => False

-- One term of a written index join: a name through the signature's binders,
-- a literal as the slot's domain element.
authTermOf : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  EffLabel ->
  Bool ->
  EffParamTy ->
  Authority
authTermOf mctx etbl tvs l pat (EPName n) =
  authArgOf mctx etbl tvs l pat (TyVar n)
authTermOf mctx _ _ l _ p = AConst (writtenParam (dtopFor mctx.mcGraph l) p)

-- a row sitting in a KRow type-app slot: a bare name resolves through the shared
-- etbl (seeded by the caller so the cell aliases the field/sig tail); an explicit
-- `<…>` builds directly; anything else is the pure closed row.
rowArgOf : ModuleCtx -> SigVars -> Ty -> EffRow
rowArgOf mctx etbl (TyVar n) = match lookupAssoc n etbl.svRows
  Some cell => EffRow [] (Some cell)
  None => pureRow
rowArgOf mctx etbl (TyEffect labels tail _) =
  EffRow
    (atomsOfWrittenIn mctx.mcGraph etbl labels)
    (tailCell mctx.mcGraph etbl tail)
-- The primary shape #997 exists for: `Async <Stdout> Unit`'s `<Stdout>` IS a
-- `TyRow`, not a `TyEffect` — this arm is what makes the bare row spelling
-- carry the SAME effect information as the pre-existing degenerate spelling
-- `Async (<Stdout> Unit) Unit` (a `TyEffect`, caught by the arm above).
-- Without it, a written row here would silently fall through to the
-- catch-all `pureRow` below and every bare-row-written effect would be
-- DISCARDED for dict-passing purposes.
rowArgOf mctx etbl (TyRow labels tail _) =
  EffRow
    (atomsOfWrittenIn mctx.mcGraph etbl labels)
    (tailCell mctx.mcGraph etbl tail)
-- Catch-all: an ordinary type written into a row-kinded slot (`Box Int Int`) is
-- diagnosed here rather than silently coerced. Mirrors the use-site check in
-- `fromAstTypeE`'s `TyRow` arm; `pureRow` stays the inert continuation so inference
-- proceeds, exactly as `fromAstTypeE` continues with `TCon "Unit"`. See
-- compiler/TYPECHECK-TARGET-ARCHITECTURE.md, Stage D, bullet "D-1. Index invariance +
-- row-arm fixes" (§6, line 2765 -- a bolded bullet, not a heading).
rowArgOf mctx _ ty =
  pushTypeErrorOncePerSite
    mctx
    TEffectKindMismatch
    (firstTyLoc ty)
    (typeInRowSlotMsg ty)
  pureRow

-- names a type uses in a KRow type-app argument slot (so a caller can seed them
-- into an etbl with shared effvars before elaborating).  Walks the whole type.
-- General elaboration obtains abstract head kinds from this type's predicates;
-- concrete data heads additionally use their registered parameter kinds.
export
rowArgNames : ModuleCtx -> Ty -> List String
rowArgNames mctx ty = rowArgNamesIn mctx (qualifiedKindScope mctx [] ty) ty

-- This scope belongs to one signature, never to a source variable spelling across
-- declarations. Interface lookup uses both declaration identity and visibility.
export
qualifiedKindScope : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  List (String, List Kind)
qualifiedKindScope mctx scope ty =
  qualifiedConstraintKinds mctx (firstTyLoc ty) scope (sigConstraintsOf ty)

qualifiedConstraintKinds : ModuleCtx ->
  Option Loc ->
  List (String, List Kind) ->
  List Constraint ->
  List (String, List Kind)
qualifiedConstraintKinds mctx _ scope [] = scope
qualifiedConstraintKinds mctx loc scope ((Constraint { constraintHead, constraintOrigin, constraintArgs }) :: rest) =
  let envs = mctx.mcGraph.declEnvsRef.value
  let cur = declEnvsOrdOf mctx.mcCells.currentModuleRef.value envs
  let key = regKeyOfTab (ifaceTabKey constraintOrigin constraintHead)
  let next = match ceLookupAt key cur envs.deIfaces
    None => scope
    Some row =>
      qualifiedArgumentKinds mctx loc scope (ceRowParamKinds row) constraintArgs
  qualifiedConstraintKinds mctx loc next rest

qualifiedArgumentKinds : ModuleCtx ->
  Option Loc ->
  List (String, List Kind) ->
  List (List Kind) ->
  List Ty ->
  List (String, List Kind)
qualifiedArgumentKinds mctx loc scope (kinds :: restKinds) ((TyVar name) :: restArgs) =
  let next = match lookupAssoc name scope
    None => (name, kinds) :: scope
    Some previous =>
      if kindsEq previous kinds then
        ()
      else
        pushTypeErrorOncePerSite
          mctx
          TEffectKindMismatch
          loc
          "signature parameter `\{name}` has incompatible required kinds `\{renderKindArrow previous}` and `\{renderKindArrow kinds}`; use separate parameters, or constraints requiring one kind"
      scope
  qualifiedArgumentKinds mctx loc next restKinds restArgs
qualifiedArgumentKinds mctx loc scope (_ :: restKinds) (_ :: restArgs) =
  qualifiedArgumentKinds mctx loc scope restKinds restArgs
qualifiedArgumentKinds mctx _ scope _ _ = scope

-- [scope] comes from the enclosing interface or the signature's own predicates.
-- Abstract heads have no ambient name-keyed kind lookup.
--
-- The split walk over [a] and [b] runs only when the head has no kinds to read.
-- Evaluated eagerly beside the kinded walk, it visits every nested argument twice
-- per level, so `Wrap^25 Int` costs 2^25 visits (#1837).
export
rowArgNamesIn : ModuleCtx -> List (String, List Kind) -> Ty -> List String
rowArgNamesIn mctx scope (TyApp a b) =
  let kinded = match tyAppSpine (TyApp a b)
    -- OCCURRENCE MINT (#1110/#1111 A-2.3), same source as `fromAstTypeE`'s.
    (TyCon { tyConName = n, tyConOrigin = o }, args) =>
      rowArgNamesApp mctx scope o n args
    -- #822: the abstract-head half — an interface typaram of graded kind, in scope.
    (TyVar h, args) => rowArgNamesVarApp mctx scope h args
    _ => None
  match kinded
    Some names => names
    None => rowArgNamesIn mctx scope a ++ rowArgNamesIn mctx scope b
rowArgNamesIn mctx scope (TyFun a b) =
  rowArgNamesIn mctx scope a ++ rowArgNamesIn mctx scope b
rowArgNamesIn mctx scope (TyTuple ts) = flatMap (rowArgNamesIn mctx scope) ts
rowArgNamesIn mctx scope (TyEffect _ _ t) = rowArgNamesIn mctx scope t
rowArgNamesIn mctx scope (TyConstrained _ t) = rowArgNamesIn mctx scope t
rowArgNamesIn mctx _ _ = []

rowArgNamesApp : ModuleCtx ->
  List (String, List Kind) ->
  TyConOrigin ->
  String ->
  List Ty ->
  Option (List String)
rowArgNamesApp mctx scope o n args =
  match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
    Some kinds if listLen kinds == listLen args =>
      Some
        (krowArgVarNames kinds args ++ flatMap (rowArgNamesIn mctx scope) args)
    _ => None

rowArgNamesVarApp : ModuleCtx ->
  List (String, List Kind) ->
  String ->
  List Ty ->
  Option (List String)
rowArgNamesVarApp mctx scope h args = match lookupAssoc h scope
  Some kinds if listLen kinds == listLen args =>
    Some (krowArgVarNames kinds args ++ flatMap (rowArgNamesIn mctx scope) args)
  _ => None

krowArgVarNames : List Kind -> List Ty -> List String
krowArgVarNames [] _ = []
krowArgVarNames _ [] = []
krowArgVarNames (KRow :: ks) ((TyVar n) :: as2) = n :: krowArgVarNames ks as2
-- A KRow slot filled with a WRITTEN row carrying an open tail var (#997,
-- `Box <Stdout | e> Int`) pins `e` exactly like a bare `Box e Int` does —
-- same var-name contribution, just spelled with labels attached. A CLOSED
-- written row (`Box <Stdout> Int`, no tail var) pins no name and falls
-- through to the catch-all below, same as any other non-`TyVar` arg.
krowArgVarNames (KRow :: ks) ((TyRow _ tails _) :: as2) =
  tails ++ krowArgVarNames ks as2
krowArgVarNames (_ :: ks) (_ :: as2) = krowArgVarNames ks as2

-- every `=>` constraint in the signature.  Recurses the spine like constraintVarNamesTy
-- rather than matching only the top node, so an effect-annotated sig still yields them.
export
sigConstraintsOf : Ty -> List Constraint
sigConstraintsOf (TyConstrained cs t) = cs ++ sigConstraintsOf t
sigConstraintsOf (TyEffect _ _ t) = sigConstraintsOf t
sigConstraintsOf _ = []

export
recFieldMono : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  Field ->
  (String, Mono)
recFieldMono mctx etbl tvs (Field fn ty) = (fn, fromAstTypeE mctx etbl tvs ty)

-- A kind that is not `Type` and must therefore be written (§6.3): `Effect`
-- or `Authority`.
kindAnnHasEffect : KindAnn -> Bool
kindAnnHasEffect KindEffect = True
kindAnnHasEffect (KindAuthority _ _ _ _) = True
kindAnnHasEffect (KindArrow a b) = kindAnnHasEffect a || kindAnnHasEffect b
kindAnnHasEffect _ = False

export
kindsEq : List Kind -> List Kind -> Bool
kindsEq [] [] = True
kindsEq (KType :: a) (KType :: b) = kindsEq a b
kindsEq (KRow :: a) (KRow :: b) = kindsEq a b
kindsEq ((KAuth l1 p1) :: a) ((KAuth l2 p2) :: b) =
  labelKey l1 == labelKey l2 && p1 == p2 && kindsEq a b
kindsEq _ _ = False

export
reportUnboundAuthorityNamesIn : ModuleCtx -> List Ty -> SigVars -> Unit
reportUnboundAuthorityNamesIn mctx tys sv =
  each (t => reportUnboundAuthorityNames mctx t sv) tys

export
payloadTypesE : ModuleCtx ->
  SigVars ->
  List (String, Mono) ->
  ConPayload ->
  List Mono
payloadTypesE mctx etbl tvs (ConPos tys) = map (fromAstTypeE mctx etbl tvs) tys
payloadTypesE mctx etbl tvs (ConNamed fields _) =
  map (fieldTypeE mctx etbl tvs) fields

fieldTypeE : ModuleCtx -> SigVars -> List (String, Mono) -> Field -> Mono
fieldTypeE mctx etbl tvs (Field _ ty) = fromAstTypeE mctx etbl tvs ty

-- Convert a `Require`'s declared type arg to a mono under the head-match subst.
-- Impl-typaram vars (the common case, `Display a`) resolve to their bound mono; an
-- unbound name gets a fresh var (defers, never a spurious concrete head).
export
reqTyToMono : ModuleCtx -> List (String, Mono) -> Ty -> Mono
reqTyToMono mctx sub (TyVar n) =
  optionOrElse (_ => freshVar mctx ()) (lookupAssoc n sub)
reqTyToMono mctx _ (TyCon { tyConName = n, tyConOrigin = o }) = tconFrom o n
reqTyToMono mctx sub (TyApp a b) =
  TApp (reqTyToMono mctx sub a) (reqTyToMono mctx sub b)
reqTyToMono mctx sub (TyFun a b) =
  TFun (reqTyToMono mctx sub a) (openRow mctx ()) (reqTyToMono mctx sub b)
reqTyToMono mctx sub (TyTuple ts) =
  tupleSpineOf (tconTupleHead (listLen ts)) (map (reqTyToMono mctx sub) ts)
reqTyToMono mctx sub (TyEffect _ _ t) = reqTyToMono mctx sub t
reqTyToMono mctx sub (TyConstrained _ t) = reqTyToMono mctx sub t
-- Same diagnostic + recovery as `fromAstTypeE`'s `TyRow` arm: `reqTyToMono`
-- has no kind-directed KRow branch at all (its `TyApp` arm is unconditional),
-- so a row written in a `requires` clause's type argument was ALREADY a
-- silent `Unit` mistype before #997 for the degenerate spelling — push the
-- same diagnostic rather than let #997's new syntax spelling reach it in
-- silence too.
reqTyToMono mctx _ (TyRow labels tail loc) =
  pushTypeErrorOncePerSite
    mctx
    TEffectKindMismatch
    loc
    (rowKindMismatchMsg labels tail)
  tconBuiltin "Unit"

-- Make an alias-NAMED arrow structurally visible, at the `Ty` (pre-`Mono`) level.
--
-- `type CFn = Int -> <> Int; extern cCall : CFn` declares `cCall`'s `Ty` as a
-- bare `TyCon "CFn"`, so the SYNTACTIC walk over the extern's declared `Ty`
-- (`ffiDeclaredRow` today, a stamping walk when this was first written) fell
-- straight through its catch-all: the extern typed as a pure `Int -> Int` with no
-- `FFI` anywhere, and any caller could reach the foreign call invisibly.  With the
-- walk now READING rather than writing, the same blindness would silently EXEMPT
-- the declaration from the label rule — same hole, quieter.  That is not the
-- nullary residual below (there, no arrow exists at all); here the arrow exists
-- and the walk just could not see through the name.
--
-- This is a straight `Ty`-level MIRROR of `fromAstTypeE`'s `TyCon` arm and
-- `fromAstTypeApp` — same two `Some` branches, same `_ => unchanged` fallback —
-- with one deliberate difference: NO arity diagnostic.  An unapplied parameterized
-- alias or an arity mismatch falls through unchanged here, because the real
-- `T-ALIAS-ARITY` error already fires once from the `fromAstTypeE` conversion that
-- runs later on this same signature.  This helper's only job is to expose an arrow
-- that is genuinely there; duplicating error reporting is not its business.
--
-- No cycle guard: `rejectCyclicAliases` has already removed every cyclic entry
-- from `aliasTableRef` before `userExternSchemes` is ever reached, so the
-- recursion terminates on the surviving table.
export
expandAliasHeadTy : ModuleCtx -> Ty -> Ty
expandAliasHeadTy mctx ty =
  expandAliasHeadTyWith mctx.mcCells.aliasTableRef.value ty

-- The explicit-table form is the carrier seam for post-typecheck consumers.  The
-- live declaration checks in `tc_foreign` call `expandAliasHeadTy`, whose table is the
-- current module's `ModuleCells.mcCells.aliasTableRef`; the emitter-side FFI index calls this
-- same function body with stage K's module-scoped alias projection.  Keeping the
-- table as an argument here means lowering does not grow a second alias expander
-- (or a third alias registry) merely because it runs after the per-module Ref has
-- been reset.  It expands the head position only; an impl head's alias normal form,
-- arguments included, is `tyAliasNormalForm`'s.
export
expandAliasHeadTyWith : List (TabKey, (List String, Ty)) -> Ty -> Ty
expandAliasHeadTyWith aliases (t@(TyCon { tyConName = n, tyConOrigin = o })) =
  match lookupTab (tyTabKey o n) aliases
    Some (params, rhs) if listLen params == 0 =>
      expandAliasHeadTyWith aliases rhs
    _ => t
expandAliasHeadTyWith aliases (t@(TyApp _ _)) = match tyAppSpine t
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    match lookupTab (tyTabKey o n) aliases
      Some (params, rhs) if listLen params == listLen args =>
        expandAliasHeadTyWith aliases (substAliasArgs (zipL params args) rhs)
      _ => t
  _ => t
expandAliasHeadTyWith _ t = t

-- substitute interface-typaram NAMES → impl type PATTERNS inside a declared Ty.
--
-- The `TyCon` arm preserves the matched node and clears only the span:
-- rebuilding it from its name alone would silently destroy the `tyConOrigin`
-- identity resolve already acquired, and re-stamping here is not an option
-- because this function does not know an identity and would be guessing one.
--
-- The span clear is deliberate and must STAY: a substituted head is no longer
-- at the source position the interface's declared type named it at, and the
-- located-diagnostic paths downstream would otherwise squiggle the interface
-- declaration for an error in the impl.  Preserving `tyConLoc` here is NOT a
-- byte-identical change; preserving `tyConOrigin` is.
substTyVars : List (String, Ty) -> Ty -> Ty
substTyVars sub (TyVar n) = optionOr (TyVar n) (lookupAssoc n sub)
substTyVars _ (t@(TyCon {  })) = TyCon { t | tyConLoc = None }
substTyVars sub (TyApp a b) = TyApp (substTyVars sub a) (substTyVars sub b)
substTyVars sub (TyFun a b) = TyFun (substTyVars sub a) (substTyVars sub b)
substTyVars sub (TyTuple ts) = TyTuple (map (substTyVars sub) ts)
substTyVars sub (TyEffect es eff t) = TyEffect es eff (substTyVars sub t)
substTyVars sub (TyConstrained cs t) = TyConstrained cs (substTyVars sub t)
-- No wrapped type to recurse into, and (like `TyEffect`'s `eff` above,
-- untouched by this substitution) a row's tail var is never one of `sub`'s
-- ordinary type-var names — a bare row atom substitutes to itself.
substTyVars _ (TyRow es eff l) = TyRow es eff l
substTyVars _ (TyAuth p l) = TyAuth p l
substTyVars sub (TyNamed n t d) = TyNamed n (substTyVars sub t) d
substTyVars sub (TyQual t ns l) = TyQual (substTyVars sub t) ns l

-- An alias's arguments substituted into its right-hand side.  A type parameter
-- occurs as a `TyVar` (`substTyVars`); an `Effect` parameter also occurs as a
-- row tail (`<Stdout | e>`), where the written argument row is spliced in: its
-- atoms join the row's and its tails replace the parameter's name, as
-- `fromAstTypeApp` binds it.  Tails go first, so a tail name inside an argument
-- that `substTyVars` then inserts is the caller's, never read as a parameter.
-- An `Authority` parameter named in an atom stays a name, which these `Ty`
-- walks read as the label's whole domain, as they read a signature's own binder.
export
substAliasArgs : List (String, Ty) -> Ty -> Ty
substAliasArgs sub rhs =
  substTyVars sub (fst (mapTyFull (substRowTailsAt sub) rhs))

substRowTailsAt : List (String, Ty) -> Ty -> (Ty, Bool)
substRowTailsAt sub (TyEffect atoms tails t) =
  let (extra, tails2) = spliceRowTails sub tails
  (TyEffect (atoms ++ extra) tails2 t, False)
substRowTailsAt sub (TyRow atoms tails l) =
  let (extra, tails2) = spliceRowTails sub tails
  (TyRow (atoms ++ extra) tails2 l, False)
substRowTailsAt _ t = (t, False)

-- A row argument is written bare (`T <Net>`), in the degenerate wrapped
-- spelling (`T (<Net> Unit)`), or as a signature's own row name (`T e2`).
-- Anything else is ill-kinded, diagnosed where the signature elaborates, and
-- keeps the parameter's name.
spliceRowTails : List (String, Ty) ->
  List String ->
  (List EffAtomTy, List String)
spliceRowTails _ [] = ([], [])
spliceRowTails sub (n :: rest) =
  let (atoms, names) = spliceRowTails sub rest
  match lookupAssoc n sub
    Some (TyRow written tails _) => (written ++ atoms, tails ++ names)
    Some (TyEffect written tails _) => (written ++ atoms, tails ++ names)
    Some (TyVar v) => (atoms, v :: names)
    _ => (atoms, n :: names)
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "Kind" true) (mem "SigVars" true) (mem "GraphCtx" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "joinCellOf" false) (mem "newEffvarId" false) (mem "stripEff" false) (mem "tconBuiltin" false) (mem "tconFrom" false) (mem "tconTupleHead" false) (mem "tupleMono" false) (mem "tupleSpineOf" false) (mem "tyAppSpine" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "aliasArityMsg" false) (mem "authorityAsTypeMsg" false) (mem "authorityAtomicLabelMsg" false) (mem "authorityParamAsRowMsg" false) (mem "authorityParamAsTypeMsg" false) (mem "authorityTermAsTypeMsg" false) (mem "binderDomainMsg" false) (mem "binderDomainTypeMsg" false) (mem "binderNoDomainMsg" false) (mem "binderTypeMsg" false) (mem "effectArrowOnDataHeadMsg" false) (mem "effectParamAsTypeMsg" false) (mem "exactInPatternSlotMsg" false) (mem "ifaceParamAuthorityKindMsg" false) (mem "ifaceParamEffectKindMsg" false) (mem "ifaceSlotDeclaredTypeMsg" false) (mem "joinDomainMsg" false) (mem "nameNotAuthorityMsg" false) (mem "ordinaryInPatternSlotMsg" false) (mem "patternDomainMsg" false) (mem "phantomExportMsg" false) (mem "qualifierBinderTypeMsg" false) (mem "renderKindArrow" false) (mem "requiresKindMsg" false) (mem "rowKindMismatchMsg" false) (mem "typeAsAuthorityMsg" false) (mem "typeInRowSlotMsg" false) (mem "typeParamAsRowMsg" false) (mem "typeVarAsAuthorityMsg" false) (mem "unannotatedGradedParamMsg" false) (mem "unannotatedRowParamMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "emptySigVars" false) (mem "mctxAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyKRow" false) (mem "ceLookupAt" false) (mem "ceRowParamKinds" false) (mem "declEnvsOrdOf" false) (mem "domainHasPatterns" false) (mem "dtopFor" false) (mem "effTailNames" false) (mem "ifaceParamKindsDeclAll" false) (mem "ifaceParamKindsFor" false) (mem "ifaceParamKindsOf" false) (mem "ifaceTabKey" false) (mem "kindAnnSlots" false) (mem "padAnns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnce" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomBindersIn" false) (mem "authSlotNamesIn" false) (mem "freshAuthvarRanged" false) (mem "freshVar" false) (mem "openRow" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "payloadAstTypes" false) (mem "variantPayload" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authJoinAll" false) (mem "authPatternClose" false) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarIsPattern" false) (mem "isPatternParam" false) (mem "linkAuthvar" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomsNorm" false) (mem "atomWith" false) (mem "effLabelName" false) (mem "labelKey" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternDecl" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "KindAnn" true) (mem "Loc" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "authTermNames" false) (mem "authTermsSurface" false) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "lookupTab" false) (mem "mapTyFull" false) (mem "orElseLoc" false) (mem "patternMark" false) (mem "qualifierSource" false) (mem "tabKeyEq" false) (mem "variantName" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "ppAuthArg" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "domainKey" false) (mem "extendParam" false) (mem "lookupAxis" false) (mem "subTopOf" false) (mem "writtenSetProblem" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "escStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "atomicLabelParamText" false) (mem "effectParamMsg" false) (mem "effectParamProblems" false) (mem "repeatedNames" false) (mem "writtenAxis" false) (mem "writtenParam" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false))))
(DTypeSig false "seedEffectDomains" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "seedEffectDomains" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "builtins") (EListLit (ETuple (ELit (LString "Net")) (EApp (EVar "PPrefix") (EVar "None"))) (ETuple (ELit (LString "FileRead")) (EApp (EVar "PPath") (EVar "None"))) (ETuple (ELit (LString "FileWrite")) (EApp (EVar "PPath") (EVar "None"))) (ETuple (ELit (LString "Env")) (EApp (EVar "PSet") (EVar "None"))) (ETuple (ELit (LString "Exec")) (EApp (EVar "PPrefix") (EVar "None"))) (ETuple (ELit (LString "FFI")) (EApp (EVar "PPrefix") (EVar "None"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "effectDomains")) (EVar "builtins")))))
(DTypeSig false "registerEffectDomain" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "registerEffectDomain" ((PVar "gctx") (PVar "label") (PVar "domain") (PVar "axes")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EVar "labelKey") (EVar "label")) (EApp (EApp (EVar "domainParamWith") (EVar "domain")) (EVar "axes")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "effectDomains")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value"))))))
(DTypeSig false "checkDomainAxes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") (PCon "Some" (PLit (LString "Product"))) (PList)) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "a Product label declares its axes; write `effect ")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " Product (Host : Prefix, Method : Set)`"))))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") (PCon "Some" (PLit (LString "Product"))) (PVar "axes")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "name")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` is declared twice"))))))) (ELit LUnit)) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "axes"))) (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "a")) (EMatch (EApp (EVar "snd") (EVar "a")) (arm (PLit (LString "Prefix")) () (ELit LUnit)) (arm (PLit (LString "Set")) () (ELit LUnit)) (arm (PVar "other") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` names the domain `"))) (EApp (EVar "display") (EVar "other"))) (ELit (LString "`; an axis is `Prefix` or `Set`"))))))))) (ELit LUnit)) (EVar "axes")))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") PWild PWild) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (ELit (LString "only a `Product` label declares axes")))))
(DTypeSig false "domainParam" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Param")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Prefix")))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Set")))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Product")))) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "domainParam" (PWild) (EVar "PUnit"))
(DTypeSig false "domainParamWith" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Param"))))
(DFunDef false "domainParamWith" ((PCon "Some" (PLit (LString "Product"))) (PVar "axes")) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "domainParam") (EApp (EVar "Some") (EApp (EVar "snd") (EVar "a"))))))) (EVar "axes"))))
(DFunDef false "domainParamWith" ((PVar "domain") PWild) (EApp (EVar "domainParam") (EVar "domain")))
(DTypeSig true "populateEffectDomainsGraph" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))))
(DFunDef false "populateEffectDomainsGraph" ((PVar "gctx") (PVar "coreDecls") (PVar "modules")) (EBlock (DoExpr (EApp (EApp (EVar "seedEffectDomains") (EVar "gctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "coreDecls"))) (DoExpr (EApp (EApp (EVar "populateUnitsGo") (EVar "gctx")) (EVar "modules")))))
(DTypeSig false "populateUnitsGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "populateUnitsGo" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "populateUnitsGo" ((PVar "gctx") (PCons (PTuple PWild (PVar "prog")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "populateUnitsGo") (EVar "gctx")) (EVar "rest")))))
(DTypeSig false "populateGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "populateGo" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "populateGo" ((PVar "gctx") (PCons (PCon "DEffect" PWild (PVar "name") (PVar "domain") (PVar "axes") (PVar "origin") PWild) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "registerEffectDomain") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "name")) (EVar "origin"))) (EVar "domain")) (EVar "axes"))) (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "rest")))))
(DFunDef false "populateGo" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "rest")))
(DTypeSig false "atomOfWrittenIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "EffAtomTy") (TyCon "Atom")))))
(DFunDef false "atomOfWrittenIn" ((PVar "gctx") (PVar "sv") (PVar "a")) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoExpr (EMatch (ETuple (EFieldAccess (EVar "a") "eatParam") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))) (arm (PTuple (PCon "EPName" (PVar "n")) (PVar "top")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (EApp (EApp (EVar "atomWith") (EVar "l")) (EVar "top"))))) (arm (PTuple (PCon "EPProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) ((GBool (EApp (EVar "axisNamesArgument") (EVar "axes")))) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AProduct") (EApp (EApp (EVar "map") (EApp (EApp (EVar "writtenAxisTerm") (EVar "sv")) (EVar "axes"))) (EVar "schema"))))) (arm (PTuple (PVar "p") (PVar "top")) () (EApp (EApp (EVar "atomWith") (EVar "l")) (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))))))
(DTypeSig false "writtenAxisTerm" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Authority"))))))
(DFunDef false "writtenAxisTerm" ((PVar "sv") (PVar "written") (PTuple (PVar "name") (PVar "top"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "written")) (arm (PCon "Some" (PCon "EPName" (PVar "n"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (ETuple (EVar "name") (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top")))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "writtenAxis") (ETuple (EVar "name") (EVar "p"))) (arm (PTuple PWild (PCon "PUnit")) () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top")))) (arm (PTuple PWild (PVar "v")) () (ETuple (EVar "name") (EApp (EVar "AConst") (EApp (EVar "canonParam") (EVar "v"))))))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top"))))))
(DTypeSig true "atomsOfWritten" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsOfWritten" ((PVar "gctx") (PVar "ls")) (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EVar "gctx")) (EVar "emptySigVars")) (EVar "ls")))
(DTypeSig true "atomsOfWrittenIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsOfWrittenIn" ((PVar "gctx") (PVar "sv") (PVar "ls")) (EApp (EVar "atomsNorm") (EApp (EApp (EVar "map") (EApp (EApp (EVar "atomOfWrittenIn") (EVar "gctx")) (EVar "sv"))) (EVar "ls"))))
(DTypeSig true "checkEffectParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkEffectParams" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEffectParams" ((PVar "mctx") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsDecl") (EVar "mctx")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkEffectParams") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkEffectParamsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DTypeSig" PWild PWild (PVar "t") PWild)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DExtern" (PRec "ExternDecl" ((rf "edTy" (PVar "t"))) true))) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkEffectParamsDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DData" ((rf "dataCtors" (PVar "ctors"))) false)) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "v")) (EMatch (EVar "v") (arm (PCon "Variant" PWild (PVar "payload")) () (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EApp (EVar "payloadAstTypes") (EVar "payload"))))))) (ELit LUnit)) (EVar "ctors")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DTypeAlias" ((rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "rhs")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypeFieldTy" (PVar "t"))) false)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DInterface" ((rf "methods" (PVar "ms"))) false)) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" PWild (PVar "t") PWild PWild) () (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))))) (ELit LUnit)) (EVar "ms")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig true "checkDeclAuthorityUses" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkDeclAuthorityUses" ((PVar "mctx") (PVar "ds")) (EApp (EApp (EVar "each") (EApp (EVar "checkDeclAuthorityUsesDecl") (EVar "mctx"))) (EVar "ds")))
(DTypeSig false "checkDeclAuthorityUsesDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkDeclAuthorityUsesDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DData" ((rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "ctors")) (rf "dataCtorBinders" (PVar "bss"))) false)) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cb")) (EMatch (EVar "cb") (arm (PTuple (PCon "Variant" PWild (PVar "payload")) (PVar "bs")) () (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EVar "heads")) (EVar "bs")) (EApp (EVar "payloadAstTypes") (EVar "payload"))))))) (ELit LUnit)) (EApp (EApp (EVar "zipCtorBinders") (EVar "ctors")) (EVar "bss"))))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DTypeAlias" ((rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EApp (EApp (EVar "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (EListLit)) (EListLit (EVar "rhs"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeCtorBinders" (PVar "bs")) (rf "newtypeFieldTy" (PVar "t"))) false)) (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EApp (EApp (EVar "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (EVar "bs")) (EListLit (EVar "t"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkDeclAuthorityDomains" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit"))))))
(DFunDef false "checkDeclAuthorityDomains" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkDeclAuthorityDomains" ((PVar "mctx") (PVar "heads") (PVar "bs") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PVar "declared") (EBinOp "++" (EVar "heads") (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "b"))))))) (EVar "bs")))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "declared"))) (DoLet false false (PVar "uses") (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "u"))) (EVar "names")))) (EApp (EApp (EVar "flatMap") (EApp (EVar "authorityUsesOf") (EVar "mctx"))) (EBinOp "::" (EVar "t") (EVar "ts"))))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "uses")) (ELit LUnit) (EApp (EApp (EApp (EVar "reportBinderDomains") (EVar "mctx")) (EVar "t")) (EBinOp "++" (EVar "declared") (EVar "uses")))))))
(DTypeSig false "declaredAuthority" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "declaredAuthority" ((PVar "gctx") (PTuple (PVar "p") (PCon "Some" (PCon "KindAuthority" (PVar "l") (PVar "o") PWild PWild)))) (EListLit (ETuple (EVar "p") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))))))
(DFunDef false "declaredAuthority" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "zipCtorBinders" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))))
(DFunDef false "zipCtorBinders" ((PList) PWild) (EListLit))
(DFunDef false "zipCtorBinders" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (ETuple (EVar "v") (EVar "b")) (EApp (EApp (EVar "zipCtorBinders") (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipCtorBinders" ((PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "::" (ETuple (EVar "v") (EListLit)) (EApp (EApp (EVar "zipCtorBinders") (EVar "vs")) (EListLit))))
(DTypeSig false "zipParamKinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))))))
(DFunDef false "zipParamKinds" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "k") (PVar "ks"))) (EBinOp "::" (ETuple (EVar "p") (EVar "k")) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks"))))
(DFunDef false "zipParamKinds" (PWild PWild) (EListLit))
(DTypeSig true "checkDeclaredKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkDeclaredKinds" ((PVar "mctx") (PVar "prog")) (EApp (EApp (EApp (EVar "checkDeclaredKindsGo") (EVar "mctx")) (EVar "prog")) (EVar "prog")))
(DTypeSig false "checkDeclaredKindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "checkDeclaredKindsGo" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "checkDeclaredKindsGo" ((PVar "mctx") (PVar "prog") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkDeclaredKindsDecl") (EVar "mctx")) (EVar "prog")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EVar "checkDeclaredKindsGo") (EVar "mctx")) (EVar "prog")) (EVar "rest")))))
(DTypeSig false "checkDeclaredKindsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyCon "Unit")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") (PVar "prog") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "checkDeclaredKindsDecl") (EVar "mctx")) (EVar "prog")) (EVar "d")))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PCon "DEffect" PWild (PVar "name") (PVar "domain") (PVar "axes") PWild (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkDomainAxes") (EVar "mctx")) (EVar "loc")) (EVar "name")) (EVar "domain")) (EVar "axes")))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "vs")) (rf "dataCtorBinders" (PVar "bs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EBinOp "++" (EVar "ks") (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "x"))))) (EVar "b")))) (EVar "bs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "vs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkPhantomAuthorityExport") (EVar "mctx")) (EVar "vis")) (EVar "n")) (EApp (EApp (EVar "authorityParamNames") (EVar "ps")) (EVar "ks"))) (EVar "vs")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeCtorBinders" (PVar "bs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EBinOp "++" (EVar "ks") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "b"))))) (EVar "bs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EListLit (EVar "fty"))))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EVar "ks"))) (DoExpr (EApp (EApp (EApp (EVar "checkAliasPatternSlots") (EVar "mctx")) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks"))) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EListLit (EVar "rhs"))))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") (PVar "prog") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None)) true)) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIfaceHeadKinds") (EVar "mctx")) (EVar "name")) (EVar "typarams")) (EApp (EApp (EVar "padAnns") (EVar "typarams")) (EVar "typaramKinds"))) (EVar "methods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperKinds") (EVar "mctx")) (EVar "prog")) (EVar "name")) (EVar "typarams")) (EApp (EApp (EVar "padAnns") (EVar "typarams")) (EVar "typaramKinds"))) (EVar "methods")) (EVar "supers")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild PWild) (ELit LUnit))
(DTypeSig false "checkAliasPatternSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))) (TyFun (TyCon "Ty") (TyCon "Unit")))))
(DFunDef false "checkAliasPatternSlots" ((PVar "mctx") (PVar "params") (PVar "rhs")) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "patternSlotNamesIn") (EVar "mctx")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "pk")) (EMatch (EVar "pk") (arm (PTuple (PVar "p") (PCon "Some" (PCon "KindAuthority" (PVar "l") PWild (PCon "False") (PVar "loc")))) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "slots")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "p")) (EVar "l"))) (ELit LUnit))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EVar "params")))))
(DTypeSig false "checkAuthorityKindLabels" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Unit"))))
(DFunDef false "checkAuthorityKindLabels" ((PVar "mctx") (PVar "anns")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "a")) (EMatch (EVar "a") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "k"))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EVar "anns")))
(DTypeSig false "checkAuthorityKindLabel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "KindAnn") (TyCon "Unit"))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") (PVar "loc"))) (EMatch (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (arm (PCon "PUnit") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "authorityAtomicLabelMsg") (EVar "l")))) (arm (PVar "top") () (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "not") (EApp (EVar "domainHasPatterns") (EVar "top")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EVar "patternDomainMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "Authority ")) (EVar "l")) (ELit (LString "*")))) (EVar "l"))) (ELit LUnit)))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") (PCon "KindArrow" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkPhantomAuthorityExport" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit")))))))
(DFunDef false "checkPhantomAuthorityExport" ((PVar "mctx") (PCon "VisPublic") (PVar "tyName") (PCons (PVar "p") (PVar "ps")) (PVar "variants")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "v")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EFieldAccess (EVar "mctx") "mcGraph")) (EListLit)) (EVar "p"))) (EVar "tys")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityPhantomExport")) (EApp (EVar "firstTyLocList") (EVar "tys"))) (EApp (EApp (EApp (EVar "phantomExportMsg") (EVar "tyName")) (EApp (EVar "variantName") (EVar "v"))) (EVar "p")))))))) (ELit LUnit)) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkPhantomAuthorityExport") (EVar "mctx")) (EVar "VisPublic")) (EVar "tyName")) (EVar "ps")) (EVar "variants")))))
(DFunDef false "checkPhantomAuthorityExport" ((PVar "mctx") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "authorityParamNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "authorityParamNames" ((PVar "params") (PVar "anns")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "pk")) (EMatch (EApp (EVar "snd") (EVar "pk")) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EListLit (EApp (EVar "fst") (EVar "pk")))) (arm PWild () (EListLit))))) (EApp (EApp (EVar "zipL") (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns")))))
(DTypeSig false "tyCarries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "tyCarries" ((PVar "gctx") PWild (PVar "p") (PCon "TyVar" (PVar "n"))) (EBinOp "==" (EVar "n") (EVar "p")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyQual" (PVar "t") (PVar "ps") PWild)) (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "ps")) (EApp (EApp (EVar "allList") (ELam ((PVar "q")) (EBinOp "==" (EApp (EVar "authTermNames") (EListLit (EVar "q"))) (EListLit (EVar "p"))))) (EVar "ps"))) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t"))))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p"))) (EVar "ts")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argsCarry") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (ELit (LInt 0))) (EVar "args"))) (arm PWild () (EVar "False"))))
(DFunDef false "tyCarries" ((PVar "gctx") PWild PWild PWild) (EVar "False"))
(DTypeSig false "argsCarry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))))
(DFunDef false "argsCarry" ((PVar "gctx") PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "argsCarry" ((PVar "gctx") (PVar "seen") (PVar "p") (PVar "key") (PVar "i") (PCons (PVar "arg") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "paramCarries") (EVar "gctx")) (EVar "seen")) (EVar "key")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "arg"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argsCarry") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "key")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "paramCarries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "paramCarries" ((PVar "gctx") (PVar "seen") (PVar "key") (PVar "i")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "seen")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors") "value")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PCon "VisPublic") (PVar "params") (PVar "variants"))) () (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "params")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "q")) () (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EBinOp "::" (EVar "key") (EVar "seen"))) (EVar "q"))) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v")))))) (EVar "variants"))))) (arm (PCon "Some" PWild) () (EVar "True"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))))
(DFunDef false "checkHeadKinds" ((PVar "mctx") (PVar "name") (PVar "params") (PVar "anns") (PVar "fieldTys")) (EBlock (DoLet false false (PVar "rowNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "effTailNames")) (EVar "fieldTys")) (EApp (EApp (EVar "flatMap") (EApp (EVar "rowArgNames") (EVar "mctx"))) (EVar "fieldTys"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKindsGo") (EVar "mctx")) (EVar "name")) (EVar "rowNames")) (EVar "fieldTys")) (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns"))))))
(DTypeSig false "checkHeadKindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Unit"))))))))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") PWild PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") (PVar "name") (PVar "rowNames") (PVar "fieldTys") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns"))) (EBlock (DoLet false false (PVar "loc") (EApp (EVar "firstTyLocList") (EVar "fieldTys"))) (DoExpr (EMatch (EVar "a") (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "unannotatedRowParamMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindEffect")) () (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "fieldTys")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "effectParamAsTypeMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PAs "k" (PCon "KindArrow" PWild PWild))) () (EIf (EApp (EVar "kindAnnHasEffect") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "effectArrowOnDataHeadMsg") (EVar "name")) (EVar "p")) (EVar "k"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindType")) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "typeParamAsRowMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "authorityParamAsRowMsg") (EVar "name")) (EVar "p"))) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "fieldTys")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "authorityParamAsTypeMsg") (EVar "name")) (EVar "p"))) (ELit LUnit)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKindsGo") (EVar "mctx")) (EVar "name")) (EVar "rowNames")) (EVar "fieldTys")) (EVar "ps")) (EVar "anns")))))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DTypeSig false "tyVarTypeOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyVar" (PVar "n"))) (EBinOp "==" (EVar "n") (EVar "p")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") PWild (PCon "TyRow" PWild PWild PWild)) (EVar "False"))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "ts")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "kinds")) (EVar "args"))) (arm PWild () (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "args"))))) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "hd")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "args"))))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") PWild PWild) (EVar "False"))
(DTypeSig false "tyVarTypeOccSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyVar" PWild) (PVar "ts"))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts")))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons (PCon "KAuth" PWild PWild) (PVar "ks")) (PCons (PCon "TyVar" PWild) (PVar "ts"))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts")))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons PWild (PVar "ks")) (PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts"))))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") PWild PWild PWild) (EVar "False"))
(DTypeSig false "checkIfaceHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") PWild (PList) PWild PWild) (ELit LUnit))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") (PVar "name") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EBlock (DoLet false false (PVar "inferred") (EApp (EApp (EVar "ifaceParamKindsOf") (EVar "p")) (EVar "methods"))) (DoLet false false (PVar "loc") (EApp (EVar "firstIfaceMethodLoc") (EVar "methods"))) (DoExpr (EMatch (EVar "a") (arm (PCon "Some" (PAs "k" (PCon "KindArrow" PWild PWild))) () (EBlock (DoLet false false (PVar "want") (EApp (EApp (EVar "kindAnnSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "inferred")) (EBinOp "==" (EApp (EVar "listLen") (EVar "inferred")) (EApp (EVar "listLen") (EVar "want")))) (EApp (EApp (EVar "anyRowDeclaredType") (EVar "inferred")) (EVar "want"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "ifaceSlotDeclaredTypeMsg") (EVar "name")) (EVar "p")) (EVar "k"))) (ELit LUnit))))) (arm (PCon "Some" (PCon "KindEffect")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "ifaceParamEffectKindMsg") (EVar "name")) (EVar "p")))) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "ifaceParamAuthorityKindMsg") (EVar "name")) (EVar "p")))) (arm PWild () (EIf (EApp (EVar "anyKRow") (EVar "inferred")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "unannotatedGradedParamMsg") (EVar "name")) (EVar "p")) (EVar "inferred"))) (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIfaceHeadKinds") (EVar "mctx")) (EVar "name")) (EVar "ps")) (EVar "anns")) (EVar "methods")))))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DTypeSig false "anyRowDeclaredType" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool"))))
(DFunDef false "anyRowDeclaredType" ((PCons (PCon "KRow") PWild) (PCons (PCon "KType") PWild)) (EVar "True"))
(DFunDef false "anyRowDeclaredType" ((PCons PWild (PVar "gs")) (PCons PWild (PVar "ws"))) (EApp (EApp (EVar "anyRowDeclaredType") (EVar "gs")) (EVar "ws")))
(DFunDef false "anyRowDeclaredType" (PWild PWild) (EVar "False"))
(DTypeSig false "firstIfaceMethodLoc" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstIfaceMethodLoc" ((PList)) (EVar "None"))
(DFunDef false "firstIfaceMethodLoc" ((PCons (PCon "IfaceMethod" PWild (PVar "mty") PWild PWild) PWild)) (EApp (EVar "firstTyLoc") (EVar "mty")))
(DTypeSig false "checkSuperKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Unit")))))))))
(DFunDef false "checkSuperKinds" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkSuperKinds" ((PVar "mctx") (PVar "prog") (PVar "name") (PVar "typarams") (PVar "anns") (PVar "methods") (PCons (PRec "Super" ((rf "superHead" (PVar "sh")) (rf "superParams" (PVar "sps"))) false) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "findIfaceDecl") (EVar "prog")) (EVar "sh")) (arm (PCon "Some" (PTuple (PVar "stps") (PVar "sanns") (PVar "smethods"))) () (EBlock (DoLet false false (PVar "subKinds") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "anns")) (EVar "methods")) (EVar "p")))) (EVar "sps"))) (DoLet false false (PVar "superKinds") (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "stps")) (EApp (EApp (EVar "padAnns") (EVar "stps")) (EVar "sanns"))) (EVar "smethods"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "subKinds")) (EApp (EVar "listLen") (EVar "superKinds"))) (EApp (EVar "not") (EApp (EApp (EVar "allList") (ELam ((PVar "pair")) (EApp (EApp (EVar "kindsEq") (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (EApp (EApp (EVar "zipKinds") (EVar "subKinds")) (EVar "superKinds"))))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EApp (EVar "firstIfaceMethodLoc") (EVar "methods"))) (EApp (EApp (EVar "requiresKindMsg") (EVar "name")) (EVar "sh"))) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperKinds") (EVar "mctx")) (EVar "prog")) (EVar "name")) (EVar "typarams")) (EVar "anns")) (EVar "methods")) (EVar "rest")))))
(DTypeSig false "zipKinds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Kind")) (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "zipKinds" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "a") (EVar "b")) (EApp (EApp (EVar "zipKinds") (EVar "xs")) (EVar "ys"))))
(DFunDef false "zipKinds" (PWild PWild) (EListLit))
(DTypeSig false "findIfaceDecl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))))
(DFunDef false "findIfaceDecl" ((PList) PWild) (EVar "None"))
(DFunDef false "findIfaceDecl" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "findIfaceDecl") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "n")))
(DFunDef false "findIfaceDecl" ((PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) true) (PVar "rest")) (PVar "n")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (ETuple (EVar "typarams") (EVar "typaramKinds") (EVar "methods"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findIfaceDecl") (EVar "rest")) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "findIfaceDecl" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "findIfaceDecl") (EVar "rest")) (EVar "n")))
(DTypeSig false "checkEffectParamsTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Unit"))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyFun" (PCon "TyNamed" (PVar "n") (PVar "a") (PVar "d")) (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkAuthorityBinder") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLoc") (EVar "a"))) (EVar "mctx"))) (EVar "n")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkBinderDomain") (EVar "mctx")) (EVar "n")) (EVar "a")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyAuth" PWild PWild)) (ELit LUnit))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EVar "ts")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectAtoms") (EVar "mctx")) (EVar "labels"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyRow" (PVar "labels") PWild PWild)) (EApp (EApp (EVar "checkEffectAtoms") (EVar "mctx")) (EVar "labels")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkEffectParamsTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit"))))
(DFunDef false "checkEffectParamsTys" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEffectParamsTys" ((PVar "mctx") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EVar "ts")))))
(DTypeSig false "checkEffectAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkEffectAtoms" ((PVar "mctx") (PVar "atoms")) (EBlock (DoExpr (EApp (EApp (EVar "checkEachEffectAtom") (EVar "mctx")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "checkWrittenElementCap") (EVar "mctx")) (EVar "atoms")))))
(DTypeSig false "checkEachEffectAtom" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkEachEffectAtom" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEachEffectAtom" ((PVar "mctx") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPTop") () (ELit LUnit)) (arm (PVar "p") () (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkOneEffectParam") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "a") "eatLoc")) (EVar "mctx"))) (EFieldAccess (EVar "a") "eatLabel")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "p"))))))) (DoExpr (EApp (EApp (EVar "checkEachEffectAtom") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkWrittenElementCap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkWrittenElementCap" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkWrittenElementCap" ((PVar "mctx") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoLet false true (PVar "onLabel") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "labelKey") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "b") "eatLabel")) (EFieldAccess (EVar "b") "eatOrigin"))) (EApp (EVar "labelKey") (EVar "l"))))) (DoLet false false (PVar "same") (EApp (EApp (EVar "filterList") (EVar "onLabel")) (EVar "rest"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "onLabel") (EVar "b"))))) (EVar "rest"))) (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (DoExpr (EMatch (EApp (EVar "writtenSetProblem") (EApp (EApp (EVar "flatMap") (EApp (EVar "writtenElement") (EVar "top"))) (EBinOp "::" (EVar "a") (EVar "same")))) (arm (PCon "Some" (PVar "why")) () (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "a") "eatLoc")) (EVar "mctx"))) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EFieldAccess (EVar "a") "eatLabel")) (EVar "why")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "checkWrittenElementCap") (EVar "mctx")) (EVar "others")))))
(DTypeSig false "writtenElement" (TyFun (TyCon "Param") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "writtenElement" ((PVar "top") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" PWild) () (EListLit)) (arm (PCon "EPProduct" (PVar "axes")) ((GBool (EApp (EVar "axisNamesArgument") (EVar "axes")))) (EListLit (EApp (EApp (EVar "writtenParam") (EVar "top")) (EApp (EVar "EPProduct") (EApp (EApp (EVar "filterList") (ELam ((PVar "ax")) (EApp (EVar "not") (EApp (EVar "isEPName") (EApp (EVar "snd") (EVar "ax")))))) (EVar "axes")))))) (arm (PVar "p") () (EListLit (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))))
(DTypeSig false "checkOneEffectParam" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyCon "Unit"))))))
(DFunDef false "checkOneEffectParam" ((PVar "mctx") (PVar "l") (PVar "top") (PVar "p")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "m")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EVar "m"))))) (ELit LUnit)) (EApp (EApp (EApp (EVar "effectParamProblems") (EVar "l")) (EVar "top")) (EVar "p"))))
(DTypeSig false "checkAuthorityBinder" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "checkAuthorityBinder" ((PVar "mctx") (PVar "n") (PVar "a") (PVar "rest")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EBinOp "==" (EApp (EVar "fst") (EVar "u")) (EVar "n")))) (EApp (EApp (EVar "authorityUsesOf") (EVar "mctx")) (EVar "rest"))) (arm (PList) () (ELit LUnit)) (arm (PCons (PTuple PWild (PVar "top")) (PVar "others")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "binderTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a"))))))))
(DTypeSig false "checkBinderDomain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyCon "EffAtomTy")) (TyCon "Unit"))))))
(DFunDef false "checkBinderDomain" ((PVar "mctx") PWild PWild (PCon "None")) (ELit LUnit))
(DFunDef false "checkBinderDomain" ((PVar "outer") (PVar "n") (PVar "a") (PCon "Some" (PVar "l"))) (EBlock (DoLet false false (PVar "mctx") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "l") "eatLoc")) (EVar "outer"))) (DoExpr (EIf (EApp (EVar "isStringTy") (EVar "a")) (EMatch (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "l") "eatLabel")) (EFieldAccess (EVar "l") "eatOrigin"))) (arm (PCon "PUnit") () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EFieldAccess (EVar "l") "eatLabel")) (EApp (EVar "atomicLabelParamText") (EFieldAccess (EVar "l") "eatLabel"))))) (arm (PVar "top") () (EIf (EBinOp "&&" (EFieldAccess (EVar "l") "eatPattern") (EApp (EVar "not") (EApp (EVar "domainHasPatterns") (EVar "top")))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EApp (EVar "patternDomainMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "@")) (EFieldAccess (EVar "l") "eatLabel")) (ELit (LString "*")))) (EFieldAccess (EVar "l") "eatLabel"))) (ELit LUnit)))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "binderDomainTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a"))))))))
(DTypeSig false "isStringTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isStringTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "==" (EVar "n") (ELit (LString "String"))))
(DFunDef false "isStringTy" (PWild) (EVar "False"))
(DTypeSig false "sameDomainTop" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "sameDomainTop" ((PVar "p") (PVar "q")) (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))))
(DTypeSig false "sigVarsWithRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsWithRows" ((PVar "rows") (PVar "sv")) (EVariantUpdate "SigVars" (EVar "sv") ((fa "svRows" (EBinOp "++" (EVar "rows") (EFieldAccess (EVar "sv") "svRows"))))))
(DTypeSig true "sigVarsWithAuths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsWithAuths" ((PVar "auths") (PVar "sv")) (EVariantUpdate "SigVars" (EVar "sv") ((fa "svAuths" (EBinOp "++" (EVar "auths") (EFieldAccess (EVar "sv") "svAuths"))))))
(DTypeSig false "sigVarsUnion" (TyFun (TyCon "SigVars") (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsUnion" ((PVar "inner") (PVar "outer")) (ERecordCreate "SigVars" ((fa "svRows" (EBinOp "++" (EFieldAccess (EVar "inner") "svRows") (EFieldAccess (EVar "outer") "svRows"))) (fa "svAuths" (EBinOp "++" (EFieldAccess (EVar "inner") "svAuths") (EFieldAccess (EVar "outer") "svAuths"))))))
(DTypeSig true "reportBinderDomains" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Unit")))))
(DFunDef false "reportBinderDomains" ((PVar "mctx") (PVar "ty") (PVar "uses")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "u")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "v")) (EApp (EVar "fst") (EVar "u"))) (EApp (EVar "not") (EApp (EApp (EVar "sameDomainTop") (EApp (EVar "snd") (EVar "u"))) (EApp (EVar "snd") (EVar "v"))))))) (EVar "uses")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EVar "binderDomainMsg") (EApp (EVar "fst") (EVar "u")))) (ELit LUnit)))) (ELit LUnit)) (EVar "uses")))
(DTypeSig true "authorityBinderBound" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "authorityBinderBound" ((PVar "named") (PVar "authNames") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "isStringTy") (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EVar "contains") (EVar "n")) (EVar "authNames")))))
(DTypeSig true "reportUnboundAuthorityNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyCon "SigVars") (TyCon "Unit")))))
(DFunDef false "reportUnboundAuthorityNames" ((PVar "mctx") (PVar "ty") (PVar "sv")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "namedArgTypes") (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "use")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "fst") (EVar "use"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "use"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths"))) (ELit LUnit) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EVar "loc")) (EApp (EVar "binderNoDomainMsg") (EVar "n"))) (ELit LUnit))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "nameNotAuthorityMsg") (EVar "n")))))))))) (ELit LUnit)) (EApp (EApp (EVar "dedupLocated") (EApp (EApp (EVar "authorityNamesWritten") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "q")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "q"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (EApp (EApp (EVar "qualifierBinderTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a")))))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "fst") (EVar "q"))))) (ELit LUnit)) (EApp (EVar "writtenQualifiers") (EVar "ty")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "q")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EApp (EVar "authvarDomain") (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "fst") (EVar "q")))) (DoExpr (EMatch (EVar "tops") (arm (PCons (PVar "top") (PVar "rest")) () (EIf (EApp (EApp (EVar "allList") (EApp (EVar "sameDomainTop") (EVar "top"))) (EVar "rest")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "q"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (EApp (EVar "joinDomainMsg") (EApp (EVar "fst") (EVar "q")))))) (arm (PList) () (ELit LUnit))))))) (ELit LUnit)) (EApp (EVar "writtenQualifiers") (EVar "ty"))))))
(DTypeSig false "dedupLocated" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "dedupLocated" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "dedupLocated" ((PCons (PTuple (PVar "n") (PVar "l")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "acc"))) (EApp (EApp (EVar "dedupLocated") (EVar "rest")) (EVar "acc")) (EApp (EApp (EVar "dedupLocated") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EVar "l")) (EVar "acc")))))
(DTypeSig false "writtenQualifiers" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "writtenQualifiers" ((PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EBinOp "::" (ETuple (EApp (EVar "authTermNames") (EVar "ps")) (EVar "l")) (EApp (EVar "writtenQualifiers") (EVar "t"))))
(DFunDef false "writtenQualifiers" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "writtenQualifiers") (EVar "a")) (EApp (EVar "writtenQualifiers") (EVar "b"))))
(DFunDef false "writtenQualifiers" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "writtenQualifiers") (EVar "a")) (EApp (EVar "writtenQualifiers") (EVar "b"))))
(DFunDef false "writtenQualifiers" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "writtenQualifiers")) (EVar "ts")))
(DFunDef false "writtenQualifiers" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" (PWild) (EListLit))
(DTypeSig false "authorityNamesWritten" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "l")))) (EApp (EVar "authTermNames") (EVar "ps"))) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyEffect" (PVar "atoms") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "atomAuthorityName") (EVar "gctx"))) (EVar "atoms")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyRow" (PVar "atoms") PWild PWild)) (EApp (EApp (EVar "flatMap") (EApp (EVar "atomAuthorityName") (EVar "gctx"))) (EVar "atoms")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "b"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "b"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "authorityNamesWritten") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "atomAuthorityName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "atomAuthorityName" ((PVar "gctx") (PVar "a")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EFieldAccess (EVar "a") "eatLoc")))) (EApp (EApp (EVar "namedAtomBinder") (EVar "gctx")) (EVar "a"))))
(DTypeSig true "namedArgTypes" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "namedArgTypes" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (ETuple (EVar "n") (EVar "a")) (EApp (EVar "namedArgTypes") (EVar "b"))))
(DFunDef false "namedArgTypes" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "namedArgTypes") (EVar "b")))
(DFunDef false "namedArgTypes" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "namedArgTypes") (EVar "t")))
(DFunDef false "namedArgTypes" (PWild) (EListLit))
(DTypeSig false "authorityUsesOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "authorityUsesOf" ((PVar "mctx") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty")) (EApp (EApp (EVar "namedAtomBinders") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))))
(DTypeSig true "binderDomainsIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyNamed" (PVar "n") (PVar "t") (PCon "Some" (PVar "l")))) (EBlock (DoLet false false (PVar "own") (EMatch (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "l") "eatLabel")) (EFieldAccess (EVar "l") "eatOrigin"))) (arm (PCon "PUnit") () (EListLit)) (arm (PCon "PProduct" (PCons (PTuple PWild (PVar "axis")) PWild)) () (EListLit (ETuple (EVar "n") (EApp (EVar "subTopOf") (EVar "axis"))))) (arm (PVar "top") () (EListLit (ETuple (EVar "n") (EVar "top")))))) (DoExpr (EBinOp "++" (EVar "own") (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t"))))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyNamed" PWild (PVar "t") (PCon "None"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "b"))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "b"))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "binderDomainsIn") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") PWild) (EListLit))
(DTypeSig true "authArgBindersIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "authArgBindersIn" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EApp (EVar "kauthArgVarNames") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "ty")))
(DTypeSig true "patternSlotNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "patternSlotNamesIn" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "patternArgVarNames")) (EVar "ty")))
(DTypeSig false "patternArgVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "patternArgVarNames" ((PCons (PCon "KAuth" PWild (PCon "True")) (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "patternArgVarNames" ((PCons (PCon "KAuth" PWild (PCon "True")) (PVar "ks")) (PCons (PCon "TyAuth" (PVar "ps") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EVar "authTermNames") (EVar "ps")) (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "patternArgVarNames" ((PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2")))
(DFunDef false "patternArgVarNames" (PWild PWild) (EListLit))
(DTypeSig false "kauthArgVarNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyAuth" (PVar "ps") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))))) (EApp (EVar "authTermNames") (EVar "ps"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyRow" (PList) (PVar "names") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))))) (EVar "names")) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2")))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") PWild PWild) (EListLit))
(DTypeSig true "namedAtomBinders" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "namedAtomBinders" ((PVar "gctx") (PVar "ty")) (EApp (EApp (EVar "atomBindersIn") (EApp (EVar "namedAtomBinder") (EVar "gctx"))) (EVar "ty")))
(DTypeSig false "namedAtomBinder" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "namedAtomBinder" ((PVar "gctx") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "n")) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")))))) (arm PWild () (EApp (EApp (EVar "axisAtomBinders") (EVar "gctx")) (EVar "a")))))
(DTypeSig false "axisAtomBinders" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "axisAtomBinders" ((PVar "gctx") (PVar "a")) (EMatch (ETuple (EFieldAccess (EVar "a") "eatParam") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")))) (arm (PTuple (PCon "EPProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "ax")) (EMatch (ETuple (EApp (EVar "snd") (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EApp (EVar "fst") (EVar "ax"))) (EVar "schema"))) (arm (PTuple (PCon "EPName" (PVar "n")) (PCon "Some" (PVar "top"))) () (EListLit (ETuple (EVar "n") (EApp (EVar "subTopOf") (EVar "top"))))) (arm PWild () (EListLit))))) (EVar "axes"))) (arm PWild () (EListLit))))
(DTypeSig false "astEffrowE" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "Ty") (TyCon "EffRow")))))
(DFunDef false "astEffrowE" ((PVar "gctx") (PVar "etbl") (PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EVar "gctx")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EVar "gctx")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "astEffrowE" ((PVar "gctx") PWild PWild) (EVar "pureRow"))
(DTypeSig true "bindingForceFromAst" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "EffRow"))))))
(DFunDef false "bindingForceFromAst" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))
(DTypeSig true "writtenBindingForce" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "EffRow")))))))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyConstrained" PWild (PVar "ty"))) (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") PWild (PAs "ty" (PCon "TyEffect" PWild PWild PWild))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "astEffrowE") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "ty"))))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "aliasScopeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "etbl2") (PVar "tvs2") (PVar "rhs"))) () (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "returnRowE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "EffRow"))))))
(DFunDef false "returnRowE" ((PVar "mctx") (PVar "etbl") PWild (PAs "ty" (PCon "TyEffect" PWild PWild PWild))) (EApp (EApp (EApp (EVar "astEffrowE") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "ty")))
(DFunDef false "returnRowE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "aliasScopeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "etbl2") (PVar "tvs2") (PVar "rhs"))) () (EApp (EApp (EApp (EApp (EVar "returnRowE") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))) (arm (PCon "None") () (EVar "pureRow"))))
(DTypeSig false "tailCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "tailCell" ((PVar "gctx") PWild (PList)) (EVar "None"))
(DFunDef false "tailCell" ((PVar "gctx") (PVar "etbl") (PList (PVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")))
(DFunDef false "tailCell" ((PVar "gctx") (PVar "etbl") (PVar "ns")) (EMatch (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")) (arm (PList) () (EVar "None")) (arm (PList (PVar "cell")) () (EApp (EVar "Some") (EVar "cell"))) (arm (PVar "cells") () (EApp (EVar "Some") (EApp (EApp (EVar "joinCellOf") (EVar "gctx")) (EVar "cells"))))))
(DTypeSig false "tailCellsOf" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "tailCellsOf" (PWild (PList)) (EListLit))
(DFunDef false "tailCellsOf" ((PVar "etbl") (PCons (PVar "n") (PVar "ns"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")) (arm (PCon "Some" (PVar "cell")) () (EBinOp "::" (EVar "cell") (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")))) (arm (PCon "None") () (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")))))
(DTypeSig true "fromAstType" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "fromAstType" ((PVar "mctx") (PVar "tvs") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "emptySigVars")) (EVar "tvs")) (EVar "ty")))
(DTypeSig true "fromAstTypeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (ELit (LInt 0))))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PVar "params") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAliasArity")) (EApp (EApp (EApp (EVar "aliasArityMsg") (EVar "n")) (EApp (EVar "listLen") (EVar "params"))) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))))) (arm PWild () (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBlock (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths"))) (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityKind")) (EApp (EVar "authorityAsTypeMsg") (EVar "n"))) (ELit LUnit))) (DoExpr (EApp (EVar "TRigid") (EVar "n")))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") PWild PWild (PCon "TyAuth" (PVar "p") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "authorityTermAsTypeMsg") (EVar "p")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fromAstTypeApp") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fromAstTypeVarApp") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "h")) (EVar "args")) (EVar "a")) (EVar "b"))) (arm PWild () (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EApp (EVar "fromAstDomainE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "returnRowE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EVar "stripEff") (EVar "b")))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "tupleMono") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "ts"))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "qualifyByTerms") (EVar "mctx")) (EVar "etbl")) (EVar "ps")) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t"))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyRow" (PVar "labels") (PVar "tail") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "rowKindMismatchMsg") (EVar "labels")) (EVar "tail")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig false "fromAstDomainE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "fromAstDomainE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyNamed" (PVar "n") (PVar "t") PWild)) (EApp (EApp (EApp (EVar "qualifyBy") (EVar "etbl")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t"))))
(DFunDef false "fromAstDomainE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DTypeSig false "qualifyBy" (TyFun (TyCon "SigVars") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "qualifyBy" ((PVar "etbl") (PVar "n") (PVar "t")) (EApp (EApp (EApp (EVar "qualifyByAll") (EVar "etbl")) (EListLit (EVar "n"))) (EVar "t")))
(DTypeSig false "qualifyByTerms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "qualifyByTerms" ((PVar "mctx") (PVar "etbl") (PVar "ps") (PVar "loc") (PVar "t")) (EBlock (DoLet false false (PVar "names") (EApp (EVar "authTermNames") (EVar "ps"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isEPName") (EVar "p"))))) (EVar "ps"))) (DoExpr (EMatch (EVar "lits") (arm (PList) () (EApp (EApp (EApp (EVar "qualifyByAll") (EVar "etbl")) (EVar "names")) (EVar "t"))) (arm PWild () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EVar "cell"))) (arm (PCon "None") () (EListLit))))) (EVar "names"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "cells")) (EApp (EVar "listLen") (EVar "names"))) (EVar "t") (EBlock (DoLet false false (PVar "top") (EMatch (EVar "cells") (arm (PCons (PVar "cell") PWild) () (EApp (EVar "authvarDomain") (EVar "cell"))) (arm (PList) () (EApp (EVar "literalDomainTop") (EVar "lits"))))) (DoLet false false (PVar "src") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ps"))) (DoLet false false (PVar "problems") (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "cells")) (EApp (EApp (EVar "anyList") (EVar "isEPProduct")) (EVar "lits"))) (EListLit (ELit (LString "a qualifier written as axes needs a binder that names its label; write `(p : String) -> <Web p> ... String @(p | Host=\"...\")`"))) (EApp (EApp (EApp (EVar "writtenTermProblems") (ELit (LString "qualifier"))) (EVar "top")) (EVar "lits")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "why")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid authority in the qualifier `")) (EApp (EVar "display") (EVar "src"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString "")))))) (ELit LUnit)) (EVar "problems"))) (DoExpr (EApp (EApp (EVar "TQual") (EVar "t")) (EApp (EVar "authJoinAll") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "AVar")) (EVar "cells")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "AConst") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))) (EVar "lits")))))))))))))))
(DTypeSig false "literalDomainTop" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyCon "Param")))
(DFunDef false "literalDomainTop" ((PVar "lits")) (EIf (EApp (EApp (EVar "allList") (EVar "isEPSet")) (EVar "lits")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PPrefix") (EVar "None"))))
(DTypeSig false "isEPSet" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPSet" ((PCon "EPSet" PWild)) (EVar "True"))
(DFunDef false "isEPSet" (PWild) (EVar "False"))
(DTypeSig false "writtenTermProblems" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "writtenTermProblems" ((PVar "l") (PVar "top") (PVar "lits")) (EBlock (DoLet false false (PVar "each") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "effectParamProblems") (EVar "l")) (EVar "top"))) (EVar "lits"))) (DoExpr (EMatch (EVar "each") (arm (PList) () (EMatch (EApp (EVar "writtenSetProblem") (EApp (EApp (EVar "map") (EApp (EVar "writtenParam") (EVar "top"))) (EVar "lits"))) (arm (PCon "Some" (PVar "why")) () (EListLit (EVar "why"))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EVar "each"))))))
(DTypeSig false "isEPProduct" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPProduct" ((PCon "EPProduct" PWild)) (EVar "True"))
(DFunDef false "isEPProduct" (PWild) (EVar "False"))
(DTypeSig false "isEPName" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPName" ((PCon "EPName" PWild)) (EVar "True"))
(DFunDef false "isEPName" (PWild) (EVar "False"))
(DTypeSig false "axisNamesArgument" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Bool")))
(DFunDef false "axisNamesArgument" ((PVar "axes")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "isEPName") (EApp (EVar "snd") (EVar "a"))))) (EVar "axes")))
(DTypeSig false "qualifyByAll" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "qualifyByAll" ((PVar "etbl") (PVar "ns") (PVar "t")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EVar "ns"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "cells")) (EBinOp "==" (EApp (EVar "listLen") (EVar "cells")) (EApp (EVar "listLen") (EVar "ns")))) (EApp (EApp (EVar "TQual") (EVar "t")) (EApp (EVar "authJoinAll") (EVar "cells"))) (EVar "t")))))
(DTypeSig false "appFallback" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "appFallback" ((PVar "mctx") PWild PWild (PVar "o") (PVar "n") (PList)) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))
(DFunDef false "appFallback" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "o") (PVar "n") (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldAppFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a")))) (EVar "as2")))
(DTypeSig false "foldAppFallback" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono")))))))
(DFunDef false "foldAppFallback" ((PVar "mctx") PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldAppFallback" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldAppFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a")))) (EVar "as2")))
(DTypeSig false "fromAstTypeApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "fromAstTypeApp" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "o") (PVar "n") (PVar "args")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EBlock (DoLet false false (PTuple (PVar "etbl2") (PVar "tvs2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgScope") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "key")) (EVar "params")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))))) (arm (PCon "Some" (PTuple (PVar "params") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAliasArity")) (EApp (EApp (EApp (EVar "aliasArityMsg") (EVar "n")) (EApp (EVar "listLen") (EVar "params"))) (EApp (EVar "listLen") (EVar "args"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "appFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args"))))) (arm PWild () (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldAppKinds") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))) (EVar "kinds")) (EVar "args"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "appFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args")))))))))
(DTypeSig false "aliasArgScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))))))
(DFunDef false "aliasArgScope" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "key") (PVar "params") (PVar "args")) (EBlock (DoLet false false (PVar "kinds") (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "KType"))) (EVar "params")))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")))) (DoLet false false (PVar "bound") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "params")) (EVar "kinds")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsUnion") (EApp (EVar "fst") (EVar "bound"))) (EVar "etbl")) (EBinOp "++" (EApp (EVar "snd") (EVar "bound")) (EVar "tvs"))))))
(DTypeSig false "aliasScopeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Ty"))))))))
(DFunDef false "aliasScopeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "None") (EMatch (EApp (EVar "tyAppSpine") (EVar "ty")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EBlock (DoLet false false (PTuple (PVar "etbl2") (PVar "tvs2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgScope") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "key")) (EVar "params")) (EVar "args"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "etbl2") (EVar "tvs2") (EVar "rhs")))))) (arm PWild () (EVar "None")))))) (arm PWild () (EVar "None")))))
(DTypeSig false "aliasArgBindings" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KRow") (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "aliasRowParamCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg")))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsWithRows") (EListLit (ETuple (EVar "p") (EVar "cell")))) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "pat")) (EApp (EVar "Some") (EVar "p")))) (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EVar "arg")))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsWithAuths") (EListLit (ETuple (EVar "p") (EVar "cell")))) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "rest")) (EBinOp "::" (ETuple (EVar "p") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg"))) (EApp (EVar "snd") (EVar "rest")))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") PWild PWild PWild PWild PWild) (ETuple (EVar "emptySigVars") (EListLit)))
(DTypeSig false "aliasRowParamCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "aliasRowParamCell" ((PVar "gctx") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell")))) (EVar "cell"))
(DFunDef false "aliasRowParamCell" ((PVar "gctx") (PVar "row")) (EApp (EVar "Ref") (EApp (EApp (EVar "ELink") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EVar "row"))))
(DTypeSig false "fromAstTypeVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Mono")))))))))
(DFunDef false "fromAstTypeVarApp" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "h") (PVar "args") (PVar "a") (PVar "b")) (EIf (EApp (EApp (EApp (EVar "anyRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "foldRowSlotArgs") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EVar "TyVar") (EVar "h")))) (EVar "args")) (EIf (EVar "otherwise") (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRowSlotArg" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "isRowSlotArg" ((PVar "etbl") (PVar "tvs") (PCon "TyVar" (PVar "n"))) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows"))) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")))))
(DFunDef false "isRowSlotArg" (PWild PWild (PCon "TyRow" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRowSlotArg" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyRowSlotArg" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "anyRowSlotArg" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyRowSlotArg" ((PVar "etbl") (PVar "tvs") (PCons (PVar "t") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "isRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "t")) (EApp (EApp (EApp (EVar "anyRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "rest"))))
(DTypeSig false "foldRowSlotArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono")))))))
(DFunDef false "foldRowSlotArgs" ((PVar "mctx") PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldRowSlotArgs" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "arg") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldRowSlotArgs") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EVar "rowSlotArgMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")))) (EVar "rest")))
(DTypeSig false "rowSlotArgMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "rowSlotArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "arg")) (EIf (EApp (EApp (EApp (EVar "isRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "arg")) (EApp (EVar "TEff") (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAppKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "foldAppKinds" ((PVar "mctx") PWild PWild (PVar "acc") (PList) (PList)) (EVar "acc"))
(DFunDef false "foldAppKinds" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "k") (PVar "ks")) (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldAppKinds") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "kindArgMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "k")) (EVar "a")))) (EVar "ks")) (EVar "as2")))
(DFunDef false "foldAppKinds" ((PVar "mctx") PWild PWild (PVar "acc") PWild PWild) (EVar "acc"))
(DTypeSig false "kindArgMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Kind") (TyFun (TyCon "Ty") (TyCon "Mono")))))))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KType") (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KRow") (PVar "arg")) (EApp (EVar "TEff") (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg"))))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "arg")) (EBlock (DoLet false false (PVar "q") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EVar "arg"))) (DoExpr (EApp (EVar "TAuth") (EIf (EVar "pat") (EApp (EVar "authPatternClose") (EVar "q")) (EVar "q"))))))
(DTypeSig false "authArgOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyCon "Authority"))))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "cell")))) (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l")))) (ELit LUnit))) (DoExpr (EApp (EVar "AVar") (EVar "cell"))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityKind")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs"))) (EApp (EApp (EVar "typeVarAsAuthorityMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l"))) (EApp (EVar "nameNotAuthorityMsg") (EVar "n"))))) (DoExpr (EApp (EVar "authTop") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "TyAuth" (PVar "ps") (PVar "loc"))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isEPName") (EVar "p"))))) (EVar "ps"))) (DoLet false false (PVar "problems") (EApp (EApp (EApp (EVar "writtenTermProblems") (EApp (EVar "effLabelName") (EVar "l"))) (EVar "top")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "why")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EApp (EVar "effLabelName") (EVar "l"))) (EVar "why"))))) (ELit LUnit)) (EVar "problems"))) (DoExpr (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "isEmptyL") (EVar "problems"))) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "lit")) (EBlock (DoLet false false (PVar "written") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "lit"))) (DoExpr (EIf (EApp (EVar "isPatternParam") (EVar "written")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EApp (EVar "exactInPatternSlotMsg") (EApp (EVar "effLabelName") (EVar "l"))) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EListLit (EVar "lit")))) (EApp (EApp (EApp (EVar "ppAuthArg") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EApp (EVar "AConst") (EApp (EVar "extendParam") (EVar "written"))))))))))) (ELit LUnit)) (EVar "lits")) (ELit LUnit))) (DoExpr (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "authTermOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat"))) (EVar "ps"))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") PWild (PVar "l") (PVar "pat") (PVar "ty")) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "ordinaryBinderIn") (EVar "etbl")) (EVar "pat")) (EVar "ty")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EVar "typeAsAuthorityMsg") (EApp (EVar "ppTy") (EVar "ty"))) (EBinOp "++" (EApp (EVar "effLabelName") (EVar "l")) (EApp (EVar "patternMark") (EVar "pat")))))))) (DoExpr (EApp (EVar "authTop") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))))))
(DTypeSig false "ordinaryBinderIn" (TyFun (TyCon "SigVars") (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "ordinaryBinderIn" ((PVar "etbl") (PCon "True") (PCon "TyRow" (PList) (PVar "names") PWild)) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "isOrdinaryBinder") (EVar "etbl")) (EVar "n")))) (EVar "names")) (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None"))))
(DFunDef false "ordinaryBinderIn" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "isOrdinaryBinder" (TyFun (TyCon "SigVars") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isOrdinaryBinder" ((PVar "etbl") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "cell")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "authTermOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyFun (TyCon "EffParamTy") (TyCon "Authority"))))))))
(DFunDef false "authTermOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "EPName" (PVar "n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EApp (EVar "TyVar") (EVar "n"))))
(DFunDef false "authTermOf" ((PVar "mctx") PWild PWild (PVar "l") PWild (PVar "p")) (EApp (EVar "AConst") (EApp (EApp (EVar "writtenParam") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "p"))))
(DTypeSig false "rowArgOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "Ty") (TyCon "EffRow")))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell")))) (arm (PCon "None") () (EVar "pureRow"))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyRow" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "rowArgOf" ((PVar "mctx") PWild (PVar "ty")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EVar "typeInRowSlotMsg") (EVar "ty")))) (DoExpr (EVar "pureRow"))))
(DTypeSig true "rowArgNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rowArgNames" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EApp (EApp (EApp (EVar "qualifiedKindScope") (EVar "mctx")) (EListLit)) (EVar "ty"))) (EVar "ty")))
(DTypeSig true "qualifiedKindScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "qualifiedKindScope" ((PVar "mctx") (PVar "scope") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "qualifiedConstraintKinds") (EVar "mctx")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "scope")) (EApp (EVar "sigConstraintsOf") (EVar "ty"))))
(DTypeSig false "qualifiedConstraintKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))
(DFunDef false "qualifiedConstraintKinds" ((PVar "mctx") PWild (PVar "scope") (PList)) (EVar "scope"))
(DFunDef false "qualifiedConstraintKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons (PRec "Constraint" ((rf "constraintHead" None) (rf "constraintOrigin" None) (rf "constraintArgs" None)) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value")) (DoLet false false (PVar "cur") (EApp (EApp (EVar "declEnvsOrdOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (EVar "envs"))) (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "constraintOrigin")) (EVar "constraintHead")))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EFieldAccess (EVar "envs") "deIfaces")) (arm (PCon "None") () (EVar "scope")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "scope")) (EApp (EVar "ceRowParamKinds") (EVar "row"))) (EVar "constraintArgs"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "qualifiedConstraintKinds") (EVar "mctx")) (EVar "loc")) (EVar "next")) (EVar "rest")))))
(DTypeSig false "qualifiedArgumentKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons (PVar "kinds") (PVar "restKinds")) (PCons (PCon "TyVar" (PVar "name")) (PVar "restArgs"))) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "scope")) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "name") (EVar "kinds")) (EVar "scope"))) (arm (PCon "Some" (PVar "previous")) () (EBlock (DoExpr (EIf (EApp (EApp (EVar "kindsEq") (EVar "previous")) (EVar "kinds")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "signature parameter `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` has incompatible required kinds `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "previous")))) (ELit (LString "` and `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "kinds")))) (ELit (LString "`; use separate parameters, or constraints requiring one kind")))))) (DoExpr (EVar "scope")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "next")) (EVar "restKinds")) (EVar "restArgs")))))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons PWild (PVar "restKinds")) (PCons PWild (PVar "restArgs"))) (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "scope")) (EVar "restKinds")) (EVar "restArgs")))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") PWild (PVar "scope") PWild PWild) (EVar "scope"))
(DTypeSig true "rowArgNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "kinded") (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "rowArgNamesApp") (EVar "mctx")) (EVar "scope")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "rowArgNamesVarApp") (EVar "mctx")) (EVar "scope")) (EVar "h")) (EVar "args"))) (arm PWild () (EVar "None")))) (DoExpr (EMatch (EVar "kinded") (arm (PCon "Some" (PVar "names")) () (EVar "names")) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "ts")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "rowArgNamesApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "rowArgNamesApp" ((PVar "mctx") (PVar "scope") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "krowArgVarNames") (EVar "kinds")) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "rowArgNamesVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "rowArgNamesVarApp" ((PVar "mctx") (PVar "scope") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "krowArgVarNames") (EVar "kinds")) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "krowArgVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "krowArgVarNames" ((PList) PWild) (EListLit))
(DFunDef false "krowArgVarNames" (PWild (PList)) (EListLit))
(DFunDef false "krowArgVarNames" ((PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "krowArgVarNames" ((PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyRow" PWild (PVar "tails") PWild) (PVar "as2"))) (EBinOp "++" (EVar "tails") (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "krowArgVarNames" ((PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2")))
(DTypeSig true "sigConstraintsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "sigConstraintsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EVar "cs") (EApp (EVar "sigConstraintsOf") (EVar "t"))))
(DFunDef false "sigConstraintsOf" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "sigConstraintsOf") (EVar "t")))
(DFunDef false "sigConstraintsOf" (PWild) (EListLit))
(DTypeSig true "recFieldMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "recFieldMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "Field" (PVar "fn") (PVar "ty"))) (ETuple (EVar "fn") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))
(DTypeSig false "kindAnnHasEffect" (TyFun (TyCon "KindAnn") (TyCon "Bool")))
(DFunDef false "kindAnnHasEffect" ((PCon "KindEffect")) (EVar "True"))
(DFunDef false "kindAnnHasEffect" ((PCon "KindAuthority" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "kindAnnHasEffect" ((PCon "KindArrow" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EVar "kindAnnHasEffect") (EVar "a")) (EApp (EVar "kindAnnHasEffect") (EVar "b"))))
(DFunDef false "kindAnnHasEffect" (PWild) (EVar "False"))
(DTypeSig true "kindsEq" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool"))))
(DFunDef false "kindsEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "kindsEq" ((PCons (PCon "KType") (PVar "a")) (PCons (PCon "KType") (PVar "b"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b")))
(DFunDef false "kindsEq" ((PCons (PCon "KRow") (PVar "a")) (PCons (PCon "KRow") (PVar "b"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b")))
(DFunDef false "kindsEq" ((PCons (PCon "KAuth" (PVar "l1") (PVar "p1")) (PVar "a")) (PCons (PCon "KAuth" (PVar "l2") (PVar "p2")) (PVar "b"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "labelKey") (EVar "l1")) (EApp (EVar "labelKey") (EVar "l2"))) (EBinOp "==" (EVar "p1") (EVar "p2"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b"))))
(DFunDef false "kindsEq" (PWild PWild) (EVar "False"))
(DTypeSig true "reportUnboundAuthorityNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "SigVars") (TyCon "Unit")))))
(DFunDef false "reportUnboundAuthorityNamesIn" ((PVar "mctx") (PVar "tys") (PVar "sv")) (EApp (EApp (EVar "each") (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "reportUnboundAuthorityNames") (EVar "mctx")) (EVar "t")) (EVar "sv")))) (EVar "tys")))
(DTypeSig true "payloadTypesE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "payloadTypesE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "ConPos" (PVar "tys"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "tys")))
(DFunDef false "payloadTypesE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "fieldTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "fields")))
(DTypeSig false "fieldTypeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Field") (TyCon "Mono"))))))
(DFunDef false "fieldTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "Field" PWild (PVar "ty"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")))
(DTypeSig true "reqTyToMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyVar" (PVar "n"))) (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sub"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") PWild (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "a"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "b"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "a"))) (EApp (EApp (EVar "openRow") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "b"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "tupleSpineOf") (EApp (EVar "tconTupleHead") (EApp (EVar "listLen") (EVar "ts")))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub"))) (EVar "ts"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "t")))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "sub")) (EVar "t")))
(DFunDef false "reqTyToMono" ((PVar "mctx") PWild (PCon "TyRow" (PVar "labels") (PVar "tail") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "rowKindMismatchMsg") (EVar "labels")) (EVar "tail")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig true "expandAliasHeadTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandAliasHeadTy" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EVar "expandAliasHeadTyWith") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "ty")))
(DTypeSig true "expandAliasHeadTyWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandAliasHeadTyWith" ((PVar "aliases") (PAs "t" (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false))) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (ELit (LInt 0))))) (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "rhs"))) (arm PWild () (EVar "t"))))
(DFunDef false "expandAliasHeadTyWith" ((PVar "aliases") (PAs "t" (PCon "TyApp" PWild PWild))) (EMatch (EApp (EVar "tyAppSpine") (EVar "t")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EApp (EApp (EVar "substAliasArgs") (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "rhs")))) (arm PWild () (EVar "t")))) (arm PWild () (EVar "t"))))
(DFunDef false "expandAliasHeadTyWith" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "substTyVars" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyVar" (PVar "n"))) (EApp (EApp (EVar "optionOr") (EApp (EVar "TyVar") (EVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sub"))))
(DFunDef false "substTyVars" (PWild (PAs "t" (PRec "TyCon" () false))) (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConLoc" (EVar "None")))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "a"))) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "b"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "a"))) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "b"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EApp (EVar "substTyVars") (EVar "sub"))) (EVar "ts"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyEffect" (PVar "es") (PVar "eff") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "eff")) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "t"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "t"))))
(DFunDef false "substTyVars" (PWild (PCon "TyRow" (PVar "es") (PVar "eff") (PVar "l"))) (EApp (EApp (EApp (EVar "TyRow") (EVar "es")) (EVar "eff")) (EVar "l")))
(DFunDef false "substTyVars" (PWild (PCon "TyAuth" (PVar "p") (PVar "l"))) (EApp (EApp (EVar "TyAuth") (EVar "p")) (EVar "l")))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "t"))) (EVar "d")))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyQual" (PVar "t") (PVar "ns") (PVar "l"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EVar "t"))) (EVar "ns")) (EVar "l")))
(DTypeSig true "substAliasArgs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substAliasArgs" ((PVar "sub") (PVar "rhs")) (EApp (EApp (EVar "substTyVars") (EVar "sub")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (EApp (EVar "substRowTailsAt") (EVar "sub"))) (EVar "rhs")))))
(DTypeSig false "substRowTailsAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "substRowTailsAt" ((PVar "sub") (PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "extra") (PVar "tails2")) (EApp (EApp (EVar "spliceRowTails") (EVar "sub")) (EVar "tails"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EBinOp "++" (EVar "atoms") (EVar "extra"))) (EVar "tails2")) (EVar "t")) (EVar "False")))))
(DFunDef false "substRowTailsAt" ((PVar "sub") (PCon "TyRow" (PVar "atoms") (PVar "tails") (PVar "l"))) (EBlock (DoLet false false (PTuple (PVar "extra") (PVar "tails2")) (EApp (EApp (EVar "spliceRowTails") (EVar "sub")) (EVar "tails"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyRow") (EBinOp "++" (EVar "atoms") (EVar "extra"))) (EVar "tails2")) (EVar "l")) (EVar "False")))))
(DFunDef false "substRowTailsAt" (PWild (PVar "t")) (ETuple (EVar "t") (EVar "False")))
(DTypeSig false "spliceRowTails" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "spliceRowTails" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spliceRowTails" ((PVar "sub") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "names")) (EApp (EApp (EVar "spliceRowTails") (EVar "sub")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sub")) (arm (PCon "Some" (PCon "TyRow" (PVar "written") (PVar "tails") PWild)) () (ETuple (EBinOp "++" (EVar "written") (EVar "atoms")) (EBinOp "++" (EVar "tails") (EVar "names")))) (arm (PCon "Some" (PCon "TyEffect" (PVar "written") (PVar "tails") PWild)) () (ETuple (EBinOp "++" (EVar "written") (EVar "atoms")) (EBinOp "++" (EVar "tails") (EVar "names")))) (arm (PCon "Some" (PCon "TyVar" (PVar "v"))) () (ETuple (EVar "atoms") (EBinOp "::" (EVar "v") (EVar "names")))) (arm PWild () (ETuple (EVar "atoms") (EBinOp "::" (EVar "n") (EVar "names"))))))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "Kind" true) (mem "SigVars" true) (mem "GraphCtx" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "joinCellOf" false) (mem "newEffvarId" false) (mem "stripEff" false) (mem "tconBuiltin" false) (mem "tconFrom" false) (mem "tconTupleHead" false) (mem "tupleMono" false) (mem "tupleSpineOf" false) (mem "tyAppSpine" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "aliasArityMsg" false) (mem "authorityAsTypeMsg" false) (mem "authorityAtomicLabelMsg" false) (mem "authorityParamAsRowMsg" false) (mem "authorityParamAsTypeMsg" false) (mem "authorityTermAsTypeMsg" false) (mem "binderDomainMsg" false) (mem "binderDomainTypeMsg" false) (mem "binderNoDomainMsg" false) (mem "binderTypeMsg" false) (mem "effectArrowOnDataHeadMsg" false) (mem "effectParamAsTypeMsg" false) (mem "exactInPatternSlotMsg" false) (mem "ifaceParamAuthorityKindMsg" false) (mem "ifaceParamEffectKindMsg" false) (mem "ifaceSlotDeclaredTypeMsg" false) (mem "joinDomainMsg" false) (mem "nameNotAuthorityMsg" false) (mem "ordinaryInPatternSlotMsg" false) (mem "patternDomainMsg" false) (mem "phantomExportMsg" false) (mem "qualifierBinderTypeMsg" false) (mem "renderKindArrow" false) (mem "requiresKindMsg" false) (mem "rowKindMismatchMsg" false) (mem "typeAsAuthorityMsg" false) (mem "typeInRowSlotMsg" false) (mem "typeParamAsRowMsg" false) (mem "typeVarAsAuthorityMsg" false) (mem "unannotatedGradedParamMsg" false) (mem "unannotatedRowParamMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "emptySigVars" false) (mem "mctxAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyKRow" false) (mem "ceLookupAt" false) (mem "ceRowParamKinds" false) (mem "declEnvsOrdOf" false) (mem "domainHasPatterns" false) (mem "dtopFor" false) (mem "effTailNames" false) (mem "ifaceParamKindsDeclAll" false) (mem "ifaceParamKindsFor" false) (mem "ifaceParamKindsOf" false) (mem "ifaceTabKey" false) (mem "kindAnnSlots" false) (mem "padAnns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnce" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomBindersIn" false) (mem "authSlotNamesIn" false) (mem "freshAuthvarRanged" false) (mem "freshVar" false) (mem "openRow" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "payloadAstTypes" false) (mem "variantPayload" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authJoinAll" false) (mem "authPatternClose" false) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarIsPattern" false) (mem "isPatternParam" false) (mem "linkAuthvar" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomsNorm" false) (mem "atomWith" false) (mem "effLabelName" false) (mem "labelKey" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternDecl" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "KindAnn" true) (mem "Loc" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "authTermNames" false) (mem "authTermsSurface" false) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "lookupTab" false) (mem "mapTyFull" false) (mem "orElseLoc" false) (mem "patternMark" false) (mem "qualifierSource" false) (mem "tabKeyEq" false) (mem "variantName" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "ppAuthArg" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "domainKey" false) (mem "extendParam" false) (mem "lookupAxis" false) (mem "subTopOf" false) (mem "writtenSetProblem" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "escStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "atomicLabelParamText" false) (mem "effectParamMsg" false) (mem "effectParamProblems" false) (mem "repeatedNames" false) (mem "writtenAxis" false) (mem "writtenParam" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false))))
(DTypeSig false "seedEffectDomains" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "seedEffectDomains" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "builtins") (EListLit (ETuple (ELit (LString "Net")) (EApp (EVar "PPrefix") (EVar "None"))) (ETuple (ELit (LString "FileRead")) (EApp (EVar "PPath") (EVar "None"))) (ETuple (ELit (LString "FileWrite")) (EApp (EVar "PPath") (EVar "None"))) (ETuple (ELit (LString "Env")) (EApp (EVar "PSet") (EVar "None"))) (ETuple (ELit (LString "Exec")) (EApp (EVar "PPrefix") (EVar "None"))) (ETuple (ELit (LString "FFI")) (EApp (EVar "PPrefix") (EVar "None"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "effectDomains")) (EVar "builtins")))))
(DTypeSig false "registerEffectDomain" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "registerEffectDomain" ((PVar "gctx") (PVar "label") (PVar "domain") (PVar "axes")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EVar "labelKey") (EVar "label")) (EApp (EApp (EVar "domainParamWith") (EVar "domain")) (EVar "axes")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "effectDomains")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value"))))))
(DTypeSig false "checkDomainAxes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") (PCon "Some" (PLit (LString "Product"))) (PList)) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "a Product label declares its axes; write `effect ")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " Product (Host : Prefix, Method : Set)`"))))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") (PCon "Some" (PLit (LString "Product"))) (PVar "axes")) (EBlock (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "name")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` is declared twice"))))))) (ELit LUnit)) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "axes"))) (EListLit)))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "a")) (EMatch (EApp (EVar "snd") (EVar "a")) (arm (PLit (LString "Prefix")) () (ELit LUnit)) (arm (PLit (LString "Set")) () (ELit LUnit)) (arm (PVar "other") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` names the domain `"))) (EApp (EMethodRef "display") (EVar "other"))) (ELit (LString "`; an axis is `Prefix` or `Set`"))))))))) (ELit LUnit)) (EVar "axes")))))
(DFunDef false "checkDomainAxes" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkDomainAxes" ((PVar "mctx") (PVar "loc") (PVar "l") PWild PWild) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (ELit (LString "only a `Product` label declares axes")))))
(DTypeSig false "domainParam" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Param")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Prefix")))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Set")))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "domainParam" ((PCon "Some" (PLit (LString "Product")))) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "domainParam" (PWild) (EVar "PUnit"))
(DTypeSig false "domainParamWith" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Param"))))
(DFunDef false "domainParamWith" ((PCon "Some" (PLit (LString "Product"))) (PVar "axes")) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "domainParam") (EApp (EVar "Some") (EApp (EVar "snd") (EVar "a"))))))) (EVar "axes"))))
(DFunDef false "domainParamWith" ((PVar "domain") PWild) (EApp (EVar "domainParam") (EVar "domain")))
(DTypeSig true "populateEffectDomainsGraph" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))))
(DFunDef false "populateEffectDomainsGraph" ((PVar "gctx") (PVar "coreDecls") (PVar "modules")) (EBlock (DoExpr (EApp (EApp (EVar "seedEffectDomains") (EVar "gctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "coreDecls"))) (DoExpr (EApp (EApp (EVar "populateUnitsGo") (EVar "gctx")) (EVar "modules")))))
(DTypeSig false "populateUnitsGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "populateUnitsGo" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "populateUnitsGo" ((PVar "gctx") (PCons (PTuple PWild (PVar "prog")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "populateUnitsGo") (EVar "gctx")) (EVar "rest")))))
(DTypeSig false "populateGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "populateGo" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "populateGo" ((PVar "gctx") (PCons (PCon "DEffect" PWild (PVar "name") (PVar "domain") (PVar "axes") (PVar "origin") PWild) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "registerEffectDomain") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "name")) (EVar "origin"))) (EVar "domain")) (EVar "axes"))) (DoExpr (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "rest")))))
(DFunDef false "populateGo" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "populateGo") (EVar "gctx")) (EVar "rest")))
(DTypeSig false "atomOfWrittenIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "EffAtomTy") (TyCon "Atom")))))
(DFunDef false "atomOfWrittenIn" ((PVar "gctx") (PVar "sv") (PVar "a")) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoExpr (EMatch (ETuple (EFieldAccess (EVar "a") "eatParam") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))) (arm (PTuple (PCon "EPName" (PVar "n")) (PVar "top")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (EApp (EApp (EVar "atomWith") (EVar "l")) (EVar "top"))))) (arm (PTuple (PCon "EPProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) ((GBool (EApp (EVar "axisNamesArgument") (EVar "axes")))) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AProduct") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "writtenAxisTerm") (EVar "sv")) (EVar "axes"))) (EVar "schema"))))) (arm (PTuple (PVar "p") (PVar "top")) () (EApp (EApp (EVar "atomWith") (EVar "l")) (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))))))
(DTypeSig false "writtenAxisTerm" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Authority"))))))
(DFunDef false "writtenAxisTerm" ((PVar "sv") (PVar "written") (PTuple (PVar "name") (PVar "top"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "written")) (arm (PCon "Some" (PCon "EPName" (PVar "n"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (ETuple (EVar "name") (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top")))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "writtenAxis") (ETuple (EVar "name") (EVar "p"))) (arm (PTuple PWild (PCon "PUnit")) () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top")))) (arm (PTuple PWild (PVar "v")) () (ETuple (EVar "name") (EApp (EVar "AConst") (EApp (EVar "canonParam") (EVar "v"))))))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "authTop") (EVar "top"))))))
(DTypeSig true "atomsOfWritten" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsOfWritten" ((PVar "gctx") (PVar "ls")) (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EVar "gctx")) (EVar "emptySigVars")) (EVar "ls")))
(DTypeSig true "atomsOfWrittenIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsOfWrittenIn" ((PVar "gctx") (PVar "sv") (PVar "ls")) (EApp (EVar "atomsNorm") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "atomOfWrittenIn") (EVar "gctx")) (EVar "sv"))) (EVar "ls"))))
(DTypeSig true "checkEffectParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkEffectParams" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEffectParams" ((PVar "mctx") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsDecl") (EVar "mctx")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkEffectParams") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkEffectParamsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DTypeSig" PWild PWild (PVar "t") PWild)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DExtern" (PRec "ExternDecl" ((rf "edTy" (PVar "t"))) true))) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkEffectParamsDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DData" ((rf "dataCtors" (PVar "ctors"))) false)) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "v")) (EMatch (EVar "v") (arm (PCon "Variant" PWild (PVar "payload")) () (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EApp (EVar "payloadAstTypes") (EVar "payload"))))))) (ELit LUnit)) (EVar "ctors")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DTypeAlias" ((rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "rhs")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypeFieldTy" (PVar "t"))) false)) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") (PRec "DInterface" ((rf "methods" (PVar "ms"))) false)) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" PWild (PVar "t") PWild PWild) () (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))))) (ELit LUnit)) (EVar "ms")))
(DFunDef false "checkEffectParamsDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig true "checkDeclAuthorityUses" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkDeclAuthorityUses" ((PVar "mctx") (PVar "ds")) (EApp (EApp (EVar "each") (EApp (EVar "checkDeclAuthorityUsesDecl") (EVar "mctx"))) (EVar "ds")))
(DTypeSig false "checkDeclAuthorityUsesDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkDeclAuthorityUsesDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DData" ((rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "ctors")) (rf "dataCtorBinders" (PVar "bss"))) false)) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cb")) (EMatch (EVar "cb") (arm (PTuple (PCon "Variant" PWild (PVar "payload")) (PVar "bs")) () (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EVar "heads")) (EVar "bs")) (EApp (EVar "payloadAstTypes") (EVar "payload"))))))) (ELit LUnit)) (EApp (EApp (EVar "zipCtorBinders") (EVar "ctors")) (EVar "bss"))))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DTypeAlias" ((rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (EListLit)) (EListLit (EVar "rhs"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeCtorBinders" (PVar "bs")) (rf "newtypeFieldTy" (PVar "t"))) false)) (EApp (EApp (EApp (EApp (EVar "checkDeclAuthorityDomains") (EVar "mctx")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks")))) (EVar "bs")) (EListLit (EVar "t"))))
(DFunDef false "checkDeclAuthorityUsesDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkDeclAuthorityDomains" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit"))))))
(DFunDef false "checkDeclAuthorityDomains" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkDeclAuthorityDomains" ((PVar "mctx") (PVar "heads") (PVar "bs") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PVar "declared") (EBinOp "++" (EVar "heads") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "declaredAuthority") (EFieldAccess (EVar "mctx") "mcGraph")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "b"))))))) (EVar "bs")))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "declared"))) (DoLet false false (PVar "uses") (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "u"))) (EVar "names")))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "authorityUsesOf") (EVar "mctx"))) (EBinOp "::" (EVar "t") (EVar "ts"))))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "uses")) (ELit LUnit) (EApp (EApp (EApp (EVar "reportBinderDomains") (EVar "mctx")) (EVar "t")) (EBinOp "++" (EVar "declared") (EVar "uses")))))))
(DTypeSig false "declaredAuthority" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "declaredAuthority" ((PVar "gctx") (PTuple (PVar "p") (PCon "Some" (PCon "KindAuthority" (PVar "l") (PVar "o") PWild PWild)))) (EListLit (ETuple (EVar "p") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))))))
(DFunDef false "declaredAuthority" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "zipCtorBinders" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))))
(DFunDef false "zipCtorBinders" ((PList) PWild) (EListLit))
(DFunDef false "zipCtorBinders" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (ETuple (EVar "v") (EVar "b")) (EApp (EApp (EVar "zipCtorBinders") (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipCtorBinders" ((PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "::" (ETuple (EVar "v") (EListLit)) (EApp (EApp (EVar "zipCtorBinders") (EVar "vs")) (EListLit))))
(DTypeSig false "zipParamKinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))))))
(DFunDef false "zipParamKinds" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "k") (PVar "ks"))) (EBinOp "::" (ETuple (EVar "p") (EVar "k")) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks"))))
(DFunDef false "zipParamKinds" (PWild PWild) (EListLit))
(DTypeSig true "checkDeclaredKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkDeclaredKinds" ((PVar "mctx") (PVar "prog")) (EApp (EApp (EApp (EVar "checkDeclaredKindsGo") (EVar "mctx")) (EVar "prog")) (EVar "prog")))
(DTypeSig false "checkDeclaredKindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "checkDeclaredKindsGo" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "checkDeclaredKindsGo" ((PVar "mctx") (PVar "prog") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkDeclaredKindsDecl") (EVar "mctx")) (EVar "prog")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EVar "checkDeclaredKindsGo") (EVar "mctx")) (EVar "prog")) (EVar "rest")))))
(DTypeSig false "checkDeclaredKindsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyCon "Unit")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") (PVar "prog") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "checkDeclaredKindsDecl") (EVar "mctx")) (EVar "prog")) (EVar "d")))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PCon "DEffect" PWild (PVar "name") (PVar "domain") (PVar "axes") PWild (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkDomainAxes") (EVar "mctx")) (EVar "loc")) (EVar "name")) (EVar "domain")) (EVar "axes")))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataCtors" (PVar "vs")) (rf "dataCtorBinders" (PVar "bs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EBinOp "++" (EVar "ks") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "x"))))) (EVar "b")))) (EVar "bs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "vs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkPhantomAuthorityExport") (EVar "mctx")) (EVar "vis")) (EVar "n")) (EApp (EApp (EVar "authorityParamNames") (EVar "ps")) (EVar "ks"))) (EVar "vs")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeCtorBinders" (PVar "bs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EBinOp "++" (EVar "ks") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "b"))))) (EVar "bs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EListLit (EVar "fty"))))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabels") (EVar "mctx")) (EVar "ks"))) (DoExpr (EApp (EApp (EApp (EVar "checkAliasPatternSlots") (EVar "mctx")) (EApp (EApp (EVar "zipParamKinds") (EVar "ps")) (EVar "ks"))) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKinds") (EVar "mctx")) (EVar "n")) (EVar "ps")) (EVar "ks")) (EListLit (EVar "rhs"))))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") (PVar "prog") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None)) true)) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIfaceHeadKinds") (EVar "mctx")) (EVar "name")) (EVar "typarams")) (EApp (EApp (EVar "padAnns") (EVar "typarams")) (EVar "typaramKinds"))) (EVar "methods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperKinds") (EVar "mctx")) (EVar "prog")) (EVar "name")) (EVar "typarams")) (EApp (EApp (EVar "padAnns") (EVar "typarams")) (EVar "typaramKinds"))) (EVar "methods")) (EVar "supers")))))
(DFunDef false "checkDeclaredKindsDecl" ((PVar "mctx") PWild PWild) (ELit LUnit))
(DTypeSig false "checkAliasPatternSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))) (TyFun (TyCon "Ty") (TyCon "Unit")))))
(DFunDef false "checkAliasPatternSlots" ((PVar "mctx") (PVar "params") (PVar "rhs")) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "patternSlotNamesIn") (EVar "mctx")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "pk")) (EMatch (EVar "pk") (arm (PTuple (PVar "p") (PCon "Some" (PCon "KindAuthority" (PVar "l") PWild (PCon "False") (PVar "loc")))) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "slots")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "p")) (EVar "l"))) (ELit LUnit))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EVar "params")))))
(DTypeSig false "checkAuthorityKindLabels" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Unit"))))
(DFunDef false "checkAuthorityKindLabels" ((PVar "mctx") (PVar "anns")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "a")) (EMatch (EVar "a") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "k"))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EVar "anns")))
(DTypeSig false "checkAuthorityKindLabel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "KindAnn") (TyCon "Unit"))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") (PVar "loc"))) (EMatch (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (arm (PCon "PUnit") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "authorityAtomicLabelMsg") (EVar "l")))) (arm (PVar "top") () (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "not") (EApp (EVar "domainHasPatterns") (EVar "top")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EVar "patternDomainMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "Authority ")) (EVar "l")) (ELit (LString "*")))) (EVar "l"))) (ELit LUnit)))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") (PCon "KindArrow" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkAuthorityKindLabel") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkAuthorityKindLabel" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkPhantomAuthorityExport" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit")))))))
(DFunDef false "checkPhantomAuthorityExport" ((PVar "mctx") (PCon "VisPublic") (PVar "tyName") (PCons (PVar "p") (PVar "ps")) (PVar "variants")) (EBlock (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "v")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EFieldAccess (EVar "mctx") "mcGraph")) (EListLit)) (EVar "p"))) (EVar "tys")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityPhantomExport")) (EApp (EVar "firstTyLocList") (EVar "tys"))) (EApp (EApp (EApp (EVar "phantomExportMsg") (EVar "tyName")) (EApp (EVar "variantName") (EVar "v"))) (EVar "p")))))))) (ELit LUnit)) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkPhantomAuthorityExport") (EVar "mctx")) (EVar "VisPublic")) (EVar "tyName")) (EVar "ps")) (EVar "variants")))))
(DFunDef false "checkPhantomAuthorityExport" ((PVar "mctx") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "authorityParamNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "authorityParamNames" ((PVar "params") (PVar "anns")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "pk")) (EMatch (EApp (EVar "snd") (EVar "pk")) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EListLit (EApp (EVar "fst") (EVar "pk")))) (arm PWild () (EListLit))))) (EApp (EApp (EVar "zipL") (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns")))))
(DTypeSig false "tyCarries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "tyCarries" ((PVar "gctx") PWild (PVar "p") (PCon "TyVar" (PVar "n"))) (EBinOp "==" (EVar "n") (EVar "p")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyQual" (PVar "t") (PVar "ps") PWild)) (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "ps")) (EApp (EApp (EVar "allList") (ELam ((PVar "q")) (EBinOp "==" (EApp (EVar "authTermNames") (EListLit (EVar "q"))) (EListLit (EVar "p"))))) (EVar "ps"))) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t"))))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p"))) (EVar "ts")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "t")))
(DFunDef false "tyCarries" ((PVar "gctx") (PVar "seen") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argsCarry") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (ELit (LInt 0))) (EVar "args"))) (arm PWild () (EVar "False"))))
(DFunDef false "tyCarries" ((PVar "gctx") PWild PWild PWild) (EVar "False"))
(DTypeSig false "argsCarry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))))
(DFunDef false "argsCarry" ((PVar "gctx") PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "argsCarry" ((PVar "gctx") (PVar "seen") (PVar "p") (PVar "key") (PVar "i") (PCons (PVar "arg") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "paramCarries") (EVar "gctx")) (EVar "seen")) (EVar "key")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "arg"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argsCarry") (EVar "gctx")) (EVar "seen")) (EVar "p")) (EVar "key")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "paramCarries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "paramCarries" ((PVar "gctx") (PVar "seen") (PVar "key") (PVar "i")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "seen")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors") "value")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PCon "VisPublic") (PVar "params") (PVar "variants"))) () (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "params")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "q")) () (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "tyCarries") (EVar "gctx")) (EBinOp "::" (EVar "key") (EVar "seen"))) (EVar "q"))) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v")))))) (EVar "variants"))))) (arm (PCon "Some" PWild) () (EVar "True"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))))
(DFunDef false "checkHeadKinds" ((PVar "mctx") (PVar "name") (PVar "params") (PVar "anns") (PVar "fieldTys")) (EBlock (DoLet false false (PVar "rowNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "effTailNames")) (EVar "fieldTys")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "rowArgNames") (EVar "mctx"))) (EVar "fieldTys"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKindsGo") (EVar "mctx")) (EVar "name")) (EVar "rowNames")) (EVar "fieldTys")) (EVar "params")) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns"))))))
(DTypeSig false "checkHeadKindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Unit"))))))))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") PWild PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") (PVar "name") (PVar "rowNames") (PVar "fieldTys") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns"))) (EBlock (DoLet false false (PVar "loc") (EApp (EVar "firstTyLocList") (EVar "fieldTys"))) (DoExpr (EMatch (EVar "a") (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "unannotatedRowParamMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindEffect")) () (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "fieldTys")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "effectParamAsTypeMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PAs "k" (PCon "KindArrow" PWild PWild))) () (EIf (EApp (EVar "kindAnnHasEffect") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "effectArrowOnDataHeadMsg") (EVar "name")) (EVar "p")) (EVar "k"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindType")) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "typeParamAsRowMsg") (EVar "name")) (EVar "p"))) (ELit LUnit))) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "contains") (EVar "p")) (EVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "authorityParamAsRowMsg") (EVar "name")) (EVar "p"))) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "fieldTys")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "authorityParamAsTypeMsg") (EVar "name")) (EVar "p"))) (ELit LUnit)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkHeadKindsGo") (EVar "mctx")) (EVar "name")) (EVar "rowNames")) (EVar "fieldTys")) (EVar "ps")) (EVar "anns")))))
(DFunDef false "checkHeadKindsGo" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DTypeSig false "tyVarTypeOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyVar" (PVar "n"))) (EBinOp "==" (EVar "n") (EVar "p")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") PWild (PCon "TyRow" PWild PWild PWild)) (EVar "False"))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "ts")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "kinds")) (EVar "args"))) (arm PWild () (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "args"))))) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "hd")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p"))) (EVar "args"))))))
(DFunDef false "tyVarTypeOcc" ((PVar "mctx") PWild PWild) (EVar "False"))
(DTypeSig false "tyVarTypeOccSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyVar" PWild) (PVar "ts"))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts")))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons (PCon "KAuth" PWild PWild) (PVar "ks")) (PCons (PCon "TyVar" PWild) (PVar "ts"))) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts")))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") (PVar "p") (PCons PWild (PVar "ks")) (PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EApp (EApp (EApp (EVar "tyVarTypeOcc") (EVar "mctx")) (EVar "p")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tyVarTypeOccSlots") (EVar "mctx")) (EVar "p")) (EVar "ks")) (EVar "ts"))))
(DFunDef false "tyVarTypeOccSlots" ((PVar "mctx") PWild PWild PWild) (EVar "False"))
(DTypeSig false "checkIfaceHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") PWild (PList) PWild PWild) (ELit LUnit))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") (PVar "name") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EBlock (DoLet false false (PVar "inferred") (EApp (EApp (EVar "ifaceParamKindsOf") (EVar "p")) (EVar "methods"))) (DoLet false false (PVar "loc") (EApp (EVar "firstIfaceMethodLoc") (EVar "methods"))) (DoExpr (EMatch (EVar "a") (arm (PCon "Some" (PAs "k" (PCon "KindArrow" PWild PWild))) () (EBlock (DoLet false false (PVar "want") (EApp (EApp (EVar "kindAnnSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "inferred")) (EBinOp "==" (EApp (EVar "listLen") (EVar "inferred")) (EApp (EVar "listLen") (EVar "want")))) (EApp (EApp (EVar "anyRowDeclaredType") (EVar "inferred")) (EVar "want"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "ifaceSlotDeclaredTypeMsg") (EVar "name")) (EVar "p")) (EVar "k"))) (ELit LUnit))))) (arm (PCon "Some" (PCon "KindEffect")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "ifaceParamEffectKindMsg") (EVar "name")) (EVar "p")))) (arm (PCon "Some" (PCon "KindAuthority" PWild PWild PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EApp (EVar "ifaceParamAuthorityKindMsg") (EVar "name")) (EVar "p")))) (arm PWild () (EIf (EApp (EVar "anyKRow") (EVar "inferred")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EApp (EVar "unannotatedGradedParamMsg") (EVar "name")) (EVar "p")) (EVar "inferred"))) (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIfaceHeadKinds") (EVar "mctx")) (EVar "name")) (EVar "ps")) (EVar "anns")) (EVar "methods")))))
(DFunDef false "checkIfaceHeadKinds" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DTypeSig false "anyRowDeclaredType" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool"))))
(DFunDef false "anyRowDeclaredType" ((PCons (PCon "KRow") PWild) (PCons (PCon "KType") PWild)) (EVar "True"))
(DFunDef false "anyRowDeclaredType" ((PCons PWild (PVar "gs")) (PCons PWild (PVar "ws"))) (EApp (EApp (EVar "anyRowDeclaredType") (EVar "gs")) (EVar "ws")))
(DFunDef false "anyRowDeclaredType" (PWild PWild) (EVar "False"))
(DTypeSig false "firstIfaceMethodLoc" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstIfaceMethodLoc" ((PList)) (EVar "None"))
(DFunDef false "firstIfaceMethodLoc" ((PCons (PCon "IfaceMethod" PWild (PVar "mty") PWild PWild) PWild)) (EApp (EVar "firstTyLoc") (EVar "mty")))
(DTypeSig false "checkSuperKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Unit")))))))))
(DFunDef false "checkSuperKinds" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkSuperKinds" ((PVar "mctx") (PVar "prog") (PVar "name") (PVar "typarams") (PVar "anns") (PVar "methods") (PCons (PRec "Super" ((rf "superHead" (PVar "sh")) (rf "superParams" (PVar "sps"))) false) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "findIfaceDecl") (EVar "prog")) (EVar "sh")) (arm (PCon "Some" (PTuple (PVar "stps") (PVar "sanns") (PVar "smethods"))) () (EBlock (DoLet false false (PVar "subKinds") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "anns")) (EVar "methods")) (EVar "p")))) (EVar "sps"))) (DoLet false false (PVar "superKinds") (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "stps")) (EApp (EApp (EVar "padAnns") (EVar "stps")) (EVar "sanns"))) (EVar "smethods"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "subKinds")) (EApp (EVar "listLen") (EVar "superKinds"))) (EApp (EVar "not") (EApp (EApp (EVar "allList") (ELam ((PVar "pair")) (EApp (EApp (EVar "kindsEq") (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (EApp (EApp (EVar "zipKinds") (EVar "subKinds")) (EVar "superKinds"))))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EApp (EVar "firstIfaceMethodLoc") (EVar "methods"))) (EApp (EApp (EVar "requiresKindMsg") (EVar "name")) (EVar "sh"))) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperKinds") (EVar "mctx")) (EVar "prog")) (EVar "name")) (EVar "typarams")) (EVar "anns")) (EVar "methods")) (EVar "rest")))))
(DTypeSig false "zipKinds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Kind")) (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "zipKinds" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "a") (EVar "b")) (EApp (EApp (EVar "zipKinds") (EVar "xs")) (EVar "ys"))))
(DFunDef false "zipKinds" (PWild PWild) (EListLit))
(DTypeSig false "findIfaceDecl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))))
(DFunDef false "findIfaceDecl" ((PList) PWild) (EVar "None"))
(DFunDef false "findIfaceDecl" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "findIfaceDecl") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "n")))
(DFunDef false "findIfaceDecl" ((PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) true) (PVar "rest")) (PVar "n")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (ETuple (EVar "typarams") (EVar "typaramKinds") (EVar "methods"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findIfaceDecl") (EVar "rest")) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "findIfaceDecl" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "findIfaceDecl") (EVar "rest")) (EVar "n")))
(DTypeSig false "checkEffectParamsTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Unit"))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyFun" (PCon "TyNamed" (PVar "n") (PVar "a") (PVar "d")) (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkAuthorityBinder") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLoc") (EVar "a"))) (EVar "mctx"))) (EVar "n")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkBinderDomain") (EVar "mctx")) (EVar "n")) (EVar "a")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "b")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyAuth" PWild PWild)) (ELit LUnit))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EVar "ts")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectAtoms") (EVar "mctx")) (EVar "labels"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyRow" (PVar "labels") PWild PWild)) (EApp (EApp (EVar "checkEffectAtoms") (EVar "mctx")) (EVar "labels")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t")))
(DFunDef false "checkEffectParamsTy" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkEffectParamsTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit"))))
(DFunDef false "checkEffectParamsTys" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEffectParamsTys" ((PVar "mctx") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoExpr (EApp (EApp (EVar "checkEffectParamsTy") (EVar "mctx")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "checkEffectParamsTys") (EVar "mctx")) (EVar "ts")))))
(DTypeSig false "checkEffectAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkEffectAtoms" ((PVar "mctx") (PVar "atoms")) (EBlock (DoExpr (EApp (EApp (EVar "checkEachEffectAtom") (EVar "mctx")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "checkWrittenElementCap") (EVar "mctx")) (EVar "atoms")))))
(DTypeSig false "checkEachEffectAtom" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkEachEffectAtom" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkEachEffectAtom" ((PVar "mctx") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPTop") () (ELit LUnit)) (arm (PVar "p") () (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkOneEffectParam") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "a") "eatLoc")) (EVar "mctx"))) (EFieldAccess (EVar "a") "eatLabel")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "p"))))))) (DoExpr (EApp (EApp (EVar "checkEachEffectAtom") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkWrittenElementCap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit"))))
(DFunDef false "checkWrittenElementCap" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkWrittenElementCap" ((PVar "mctx") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin"))) (DoLet false true (PVar "onLabel") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "labelKey") (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "b") "eatLabel")) (EFieldAccess (EVar "b") "eatOrigin"))) (EApp (EVar "labelKey") (EVar "l"))))) (DoLet false false (PVar "same") (EApp (EApp (EVar "filterList") (EVar "onLabel")) (EVar "rest"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "onLabel") (EVar "b"))))) (EVar "rest"))) (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (DoExpr (EMatch (EApp (EVar "writtenSetProblem") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "writtenElement") (EVar "top"))) (EBinOp "::" (EVar "a") (EVar "same")))) (arm (PCon "Some" (PVar "why")) () (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "a") "eatLoc")) (EVar "mctx"))) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EFieldAccess (EVar "a") "eatLabel")) (EVar "why")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "checkWrittenElementCap") (EVar "mctx")) (EVar "others")))))
(DTypeSig false "writtenElement" (TyFun (TyCon "Param") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "writtenElement" ((PVar "top") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" PWild) () (EListLit)) (arm (PCon "EPProduct" (PVar "axes")) ((GBool (EApp (EVar "axisNamesArgument") (EVar "axes")))) (EListLit (EApp (EApp (EVar "writtenParam") (EVar "top")) (EApp (EVar "EPProduct") (EApp (EApp (EVar "filterList") (ELam ((PVar "ax")) (EApp (EVar "not") (EApp (EVar "isEPName") (EApp (EVar "snd") (EVar "ax")))))) (EVar "axes")))))) (arm (PVar "p") () (EListLit (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))))
(DTypeSig false "checkOneEffectParam" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyCon "Unit"))))))
(DFunDef false "checkOneEffectParam" ((PVar "mctx") (PVar "l") (PVar "top") (PVar "p")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "m")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EVar "l")) (EVar "m"))))) (ELit LUnit)) (EApp (EApp (EApp (EVar "effectParamProblems") (EVar "l")) (EVar "top")) (EVar "p"))))
(DTypeSig false "checkAuthorityBinder" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "checkAuthorityBinder" ((PVar "mctx") (PVar "n") (PVar "a") (PVar "rest")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EBinOp "==" (EApp (EVar "fst") (EVar "u")) (EVar "n")))) (EApp (EApp (EVar "authorityUsesOf") (EVar "mctx")) (EVar "rest"))) (arm (PList) () (ELit LUnit)) (arm (PCons (PTuple PWild (PVar "top")) (PVar "others")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "binderTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a"))))))))
(DTypeSig false "checkBinderDomain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyCon "EffAtomTy")) (TyCon "Unit"))))))
(DFunDef false "checkBinderDomain" ((PVar "mctx") PWild PWild (PCon "None")) (ELit LUnit))
(DFunDef false "checkBinderDomain" ((PVar "outer") (PVar "n") (PVar "a") (PCon "Some" (PVar "l"))) (EBlock (DoLet false false (PVar "mctx") (EApp (EApp (EVar "mctxAtIfSome") (EFieldAccess (EVar "l") "eatLoc")) (EVar "outer"))) (DoExpr (EIf (EApp (EVar "isStringTy") (EVar "a")) (EMatch (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "l") "eatLabel")) (EFieldAccess (EVar "l") "eatOrigin"))) (arm (PCon "PUnit") () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TEffectParam")) (EApp (EApp (EVar "effectParamMsg") (EFieldAccess (EVar "l") "eatLabel")) (EApp (EVar "atomicLabelParamText") (EFieldAccess (EVar "l") "eatLabel"))))) (arm (PVar "top") () (EIf (EBinOp "&&" (EFieldAccess (EVar "l") "eatPattern") (EApp (EVar "not") (EApp (EVar "domainHasPatterns") (EVar "top")))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EApp (EVar "patternDomainMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "@")) (EFieldAccess (EVar "l") "eatLabel")) (ELit (LString "*")))) (EFieldAccess (EVar "l") "eatLabel"))) (ELit LUnit)))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "binderDomainTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a"))))))))
(DTypeSig false "isStringTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isStringTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "==" (EVar "n") (ELit (LString "String"))))
(DFunDef false "isStringTy" (PWild) (EVar "False"))
(DTypeSig false "sameDomainTop" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "sameDomainTop" ((PVar "p") (PVar "q")) (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))))
(DTypeSig false "sigVarsWithRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsWithRows" ((PVar "rows") (PVar "sv")) (EVariantUpdate "SigVars" (EVar "sv") ((fa "svRows" (EBinOp "++" (EVar "rows") (EFieldAccess (EVar "sv") "svRows"))))))
(DTypeSig true "sigVarsWithAuths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsWithAuths" ((PVar "auths") (PVar "sv")) (EVariantUpdate "SigVars" (EVar "sv") ((fa "svAuths" (EBinOp "++" (EVar "auths") (EFieldAccess (EVar "sv") "svAuths"))))))
(DTypeSig false "sigVarsUnion" (TyFun (TyCon "SigVars") (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "sigVarsUnion" ((PVar "inner") (PVar "outer")) (ERecordCreate "SigVars" ((fa "svRows" (EBinOp "++" (EFieldAccess (EVar "inner") "svRows") (EFieldAccess (EVar "outer") "svRows"))) (fa "svAuths" (EBinOp "++" (EFieldAccess (EVar "inner") "svAuths") (EFieldAccess (EVar "outer") "svAuths"))))))
(DTypeSig true "reportBinderDomains" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Unit")))))
(DFunDef false "reportBinderDomains" ((PVar "mctx") (PVar "ty") (PVar "uses")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "u")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "v")) (EApp (EVar "fst") (EVar "u"))) (EApp (EVar "not") (EApp (EApp (EVar "sameDomainTop") (EApp (EVar "snd") (EVar "u"))) (EApp (EVar "snd") (EVar "v"))))))) (EVar "uses")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EVar "binderDomainMsg") (EApp (EVar "fst") (EVar "u")))) (ELit LUnit)))) (ELit LUnit)) (EVar "uses")))
(DTypeSig true "authorityBinderBound" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "authorityBinderBound" ((PVar "named") (PVar "authNames") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "isStringTy") (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EVar "contains") (EVar "n")) (EVar "authNames")))))
(DTypeSig true "reportUnboundAuthorityNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyCon "SigVars") (TyCon "Unit")))))
(DFunDef false "reportUnboundAuthorityNames" ((PVar "mctx") (PVar "ty") (PVar "sv")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "namedArgTypes") (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "use")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "fst") (EVar "use"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "use"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths"))) (ELit LUnit) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EVar "loc")) (EApp (EVar "binderNoDomainMsg") (EVar "n"))) (ELit LUnit))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "nameNotAuthorityMsg") (EVar "n")))))))))) (ELit LUnit)) (EApp (EApp (EVar "dedupLocated") (EApp (EApp (EVar "authorityNamesWritten") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EListLit)))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "q")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "named")) (arm (PCon "Some" (PVar "a")) () (EIf (EApp (EVar "isStringTy") (EVar "a")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityBinder")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "q"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (EApp (EApp (EVar "qualifierBinderTypeMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "a")))))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "fst") (EVar "q"))))) (ELit LUnit)) (EApp (EVar "writtenQualifiers") (EVar "ty")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "q")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "sv") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EApp (EVar "authvarDomain") (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "fst") (EVar "q")))) (DoExpr (EMatch (EVar "tops") (arm (PCons (PVar "top") (PVar "rest")) () (EIf (EApp (EApp (EVar "allList") (EApp (EVar "sameDomainTop") (EVar "top"))) (EVar "rest")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TAuthorityDomain")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "snd") (EVar "q"))) (EApp (EVar "firstTyLoc") (EVar "ty")))) (EApp (EVar "joinDomainMsg") (EApp (EVar "fst") (EVar "q")))))) (arm (PList) () (ELit LUnit))))))) (ELit LUnit)) (EApp (EVar "writtenQualifiers") (EVar "ty"))))))
(DTypeSig false "dedupLocated" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "dedupLocated" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "dedupLocated" ((PCons (PTuple (PVar "n") (PVar "l")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "acc"))) (EApp (EApp (EVar "dedupLocated") (EVar "rest")) (EVar "acc")) (EApp (EApp (EVar "dedupLocated") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EVar "l")) (EVar "acc")))))
(DTypeSig false "writtenQualifiers" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "writtenQualifiers" ((PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EBinOp "::" (ETuple (EApp (EVar "authTermNames") (EVar "ps")) (EVar "l")) (EApp (EVar "writtenQualifiers") (EVar "t"))))
(DFunDef false "writtenQualifiers" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "writtenQualifiers") (EVar "a")) (EApp (EVar "writtenQualifiers") (EVar "b"))))
(DFunDef false "writtenQualifiers" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "writtenQualifiers") (EVar "a")) (EApp (EVar "writtenQualifiers") (EVar "b"))))
(DFunDef false "writtenQualifiers" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "writtenQualifiers")) (EVar "ts")))
(DFunDef false "writtenQualifiers" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "writtenQualifiers") (EVar "t")))
(DFunDef false "writtenQualifiers" (PWild) (EListLit))
(DTypeSig false "authorityNamesWritten" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "l")))) (EApp (EVar "authTermNames") (EVar "ps"))) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyEffect" (PVar "atoms") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "atomAuthorityName") (EVar "gctx"))) (EVar "atoms")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyRow" (PVar "atoms") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "atomAuthorityName") (EVar "gctx"))) (EVar "atoms")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "b"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "b"))))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "authorityNamesWritten") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "authorityNamesWritten") (EVar "gctx")) (EVar "t")))
(DFunDef false "authorityNamesWritten" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "atomAuthorityName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "atomAuthorityName" ((PVar "gctx") (PVar "a")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EFieldAccess (EVar "a") "eatLoc")))) (EApp (EApp (EVar "namedAtomBinder") (EVar "gctx")) (EVar "a"))))
(DTypeSig true "namedArgTypes" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "namedArgTypes" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (ETuple (EVar "n") (EVar "a")) (EApp (EVar "namedArgTypes") (EVar "b"))))
(DFunDef false "namedArgTypes" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "namedArgTypes") (EVar "b")))
(DFunDef false "namedArgTypes" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "namedArgTypes") (EVar "t")))
(DFunDef false "namedArgTypes" (PWild) (EListLit))
(DTypeSig false "authorityUsesOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "authorityUsesOf" ((PVar "mctx") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty")) (EApp (EApp (EVar "namedAtomBinders") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))))
(DTypeSig true "binderDomainsIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyNamed" (PVar "n") (PVar "t") (PCon "Some" (PVar "l")))) (EBlock (DoLet false false (PVar "own") (EMatch (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "l") "eatLabel")) (EFieldAccess (EVar "l") "eatOrigin"))) (arm (PCon "PUnit") () (EListLit)) (arm (PCon "PProduct" (PCons (PTuple PWild (PVar "axis")) PWild)) () (EListLit (ETuple (EVar "n") (EApp (EVar "subTopOf") (EVar "axis"))))) (arm (PVar "top") () (EListLit (ETuple (EVar "n") (EVar "top")))))) (DoExpr (EBinOp "++" (EVar "own") (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t"))))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyNamed" PWild (PVar "t") (PCon "None"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "b"))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "b"))))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "binderDomainsIn") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "binderDomainsIn") (EVar "gctx")) (EVar "t")))
(DFunDef false "binderDomainsIn" ((PVar "gctx") PWild) (EListLit))
(DTypeSig true "authArgBindersIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "authArgBindersIn" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EApp (EVar "kauthArgVarNames") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "ty")))
(DTypeSig true "patternSlotNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "patternSlotNamesIn" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "patternArgVarNames")) (EVar "ty")))
(DTypeSig false "patternArgVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "patternArgVarNames" ((PCons (PCon "KAuth" PWild (PCon "True")) (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "patternArgVarNames" ((PCons (PCon "KAuth" PWild (PCon "True")) (PVar "ks")) (PCons (PCon "TyAuth" (PVar "ps") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EVar "authTermNames") (EVar "ps")) (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "patternArgVarNames" ((PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EVar "patternArgVarNames") (EVar "ks")) (EVar "as2")))
(DFunDef false "patternArgVarNames" (PWild PWild) (EListLit))
(DTypeSig false "kauthArgVarNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyAuth" (PVar "ps") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))))) (EApp (EVar "authTermNames") (EVar "ps"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyRow" (PList) (PVar "names") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l"))))) (EVar "names")) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") (PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EVar "kauthArgVarNames") (EVar "gctx")) (EVar "ks")) (EVar "as2")))
(DFunDef false "kauthArgVarNames" ((PVar "gctx") PWild PWild) (EListLit))
(DTypeSig true "namedAtomBinders" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "namedAtomBinders" ((PVar "gctx") (PVar "ty")) (EApp (EApp (EVar "atomBindersIn") (EApp (EVar "namedAtomBinder") (EVar "gctx"))) (EVar "ty")))
(DTypeSig false "namedAtomBinder" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "namedAtomBinder" ((PVar "gctx") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "n")) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")))))) (arm PWild () (EApp (EApp (EVar "axisAtomBinders") (EVar "gctx")) (EVar "a")))))
(DTypeSig false "axisAtomBinders" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "axisAtomBinders" ((PVar "gctx") (PVar "a")) (EMatch (ETuple (EFieldAccess (EVar "a") "eatParam") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")))) (arm (PTuple (PCon "EPProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "ax")) (EMatch (ETuple (EApp (EVar "snd") (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EApp (EVar "fst") (EVar "ax"))) (EVar "schema"))) (arm (PTuple (PCon "EPName" (PVar "n")) (PCon "Some" (PVar "top"))) () (EListLit (ETuple (EVar "n") (EApp (EVar "subTopOf") (EVar "top"))))) (arm PWild () (EListLit))))) (EVar "axes"))) (arm PWild () (EListLit))))
(DTypeSig false "astEffrowE" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "Ty") (TyCon "EffRow")))))
(DFunDef false "astEffrowE" ((PVar "gctx") (PVar "etbl") (PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EVar "gctx")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EVar "gctx")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "astEffrowE" ((PVar "gctx") PWild PWild) (EVar "pureRow"))
(DTypeSig true "bindingForceFromAst" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "EffRow"))))))
(DFunDef false "bindingForceFromAst" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))
(DTypeSig true "writtenBindingForce" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "EffRow")))))))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyConstrained" PWild (PVar "ty"))) (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") PWild (PAs "ty" (PCon "TyEffect" PWild PWild PWild))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "astEffrowE") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "ty"))))
(DFunDef false "writtenBindingForce" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "aliasScopeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "etbl2") (PVar "tvs2") (PVar "rhs"))) () (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "returnRowE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "EffRow"))))))
(DFunDef false "returnRowE" ((PVar "mctx") (PVar "etbl") PWild (PAs "ty" (PCon "TyEffect" PWild PWild PWild))) (EApp (EApp (EApp (EVar "astEffrowE") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "ty")))
(DFunDef false "returnRowE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "aliasScopeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "etbl2") (PVar "tvs2") (PVar "rhs"))) () (EApp (EApp (EApp (EApp (EVar "returnRowE") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))) (arm (PCon "None") () (EVar "pureRow"))))
(DTypeSig false "tailCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "tailCell" ((PVar "gctx") PWild (PList)) (EVar "None"))
(DFunDef false "tailCell" ((PVar "gctx") (PVar "etbl") (PList (PVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")))
(DFunDef false "tailCell" ((PVar "gctx") (PVar "etbl") (PVar "ns")) (EMatch (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")) (arm (PList) () (EVar "None")) (arm (PList (PVar "cell")) () (EApp (EVar "Some") (EVar "cell"))) (arm (PVar "cells") () (EApp (EVar "Some") (EApp (EApp (EVar "joinCellOf") (EVar "gctx")) (EVar "cells"))))))
(DTypeSig false "tailCellsOf" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "tailCellsOf" (PWild (PList)) (EListLit))
(DFunDef false "tailCellsOf" ((PVar "etbl") (PCons (PVar "n") (PVar "ns"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")) (arm (PCon "Some" (PVar "cell")) () (EBinOp "::" (EVar "cell") (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")))) (arm (PCon "None") () (EApp (EApp (EVar "tailCellsOf") (EVar "etbl")) (EVar "ns")))))
(DTypeSig true "fromAstType" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "fromAstType" ((PVar "mctx") (PVar "tvs") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "emptySigVars")) (EVar "tvs")) (EVar "ty")))
(DTypeSig true "fromAstTypeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (ELit (LInt 0))))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PVar "params") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAliasArity")) (EApp (EApp (EApp (EVar "aliasArityMsg") (EVar "n")) (EApp (EVar "listLen") (EVar "params"))) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))))) (arm PWild () (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBlock (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths"))) (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityKind")) (EApp (EVar "authorityAsTypeMsg") (EVar "n"))) (ELit LUnit))) (DoExpr (EApp (EVar "TRigid") (EVar "n")))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") PWild PWild (PCon "TyAuth" (PVar "p") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EVar "loc")) (EApp (EVar "authorityTermAsTypeMsg") (EVar "p")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fromAstTypeApp") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fromAstTypeVarApp") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "h")) (EVar "args")) (EVar "a")) (EVar "b"))) (arm PWild () (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EApp (EVar "fromAstDomainE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "returnRowE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EVar "stripEff") (EVar "b")))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "tupleMono") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "ts"))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "qualifyByTerms") (EVar "mctx")) (EVar "etbl")) (EVar "ps")) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t"))))
(DFunDef false "fromAstTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyRow" (PVar "labels") (PVar "tail") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "rowKindMismatchMsg") (EVar "labels")) (EVar "tail")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig false "fromAstDomainE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "fromAstDomainE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "TyNamed" (PVar "n") (PVar "t") PWild)) (EApp (EApp (EApp (EVar "qualifyBy") (EVar "etbl")) (EVar "n")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t"))))
(DFunDef false "fromAstDomainE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "t")))
(DTypeSig false "qualifyBy" (TyFun (TyCon "SigVars") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "qualifyBy" ((PVar "etbl") (PVar "n") (PVar "t")) (EApp (EApp (EApp (EVar "qualifyByAll") (EVar "etbl")) (EListLit (EVar "n"))) (EVar "t")))
(DTypeSig false "qualifyByTerms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "qualifyByTerms" ((PVar "mctx") (PVar "etbl") (PVar "ps") (PVar "loc") (PVar "t")) (EBlock (DoLet false false (PVar "names") (EApp (EVar "authTermNames") (EVar "ps"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isEPName") (EVar "p"))))) (EVar "ps"))) (DoExpr (EMatch (EVar "lits") (arm (PList) () (EApp (EApp (EApp (EVar "qualifyByAll") (EVar "etbl")) (EVar "names")) (EVar "t"))) (arm PWild () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EVar "cell"))) (arm (PCon "None") () (EListLit))))) (EVar "names"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "cells")) (EApp (EVar "listLen") (EVar "names"))) (EVar "t") (EBlock (DoLet false false (PVar "top") (EMatch (EVar "cells") (arm (PCons (PVar "cell") PWild) () (EApp (EVar "authvarDomain") (EVar "cell"))) (arm (PList) () (EApp (EVar "literalDomainTop") (EVar "lits"))))) (DoLet false false (PVar "src") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ps"))) (DoLet false false (PVar "problems") (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "cells")) (EApp (EApp (EVar "anyList") (EVar "isEPProduct")) (EVar "lits"))) (EListLit (ELit (LString "a qualifier written as axes needs a binder that names its label; write `(p : String) -> <Web p> ... String @(p | Host=\"...\")`"))) (EApp (EApp (EApp (EVar "writtenTermProblems") (ELit (LString "qualifier"))) (EVar "top")) (EVar "lits")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "why")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid authority in the qualifier `")) (EApp (EMethodRef "display") (EVar "src"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString "")))))) (ELit LUnit)) (EVar "problems"))) (DoExpr (EApp (EApp (EVar "TQual") (EVar "t")) (EApp (EVar "authJoinAll") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "AVar")) (EVar "cells")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "AConst") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p"))))) (EVar "lits")))))))))))))))
(DTypeSig false "literalDomainTop" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyCon "Param")))
(DFunDef false "literalDomainTop" ((PVar "lits")) (EIf (EApp (EApp (EVar "allList") (EVar "isEPSet")) (EVar "lits")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PPrefix") (EVar "None"))))
(DTypeSig false "isEPSet" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPSet" ((PCon "EPSet" PWild)) (EVar "True"))
(DFunDef false "isEPSet" (PWild) (EVar "False"))
(DTypeSig false "writtenTermProblems" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "writtenTermProblems" ((PVar "l") (PVar "top") (PVar "lits")) (EBlock (DoLet false false (PVar "each") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "effectParamProblems") (EVar "l")) (EVar "top"))) (EVar "lits"))) (DoExpr (EMatch (EVar "each") (arm (PList) () (EMatch (EApp (EVar "writtenSetProblem") (EApp (EApp (EMethodRef "map") (EApp (EVar "writtenParam") (EVar "top"))) (EVar "lits"))) (arm (PCon "Some" (PVar "why")) () (EListLit (EVar "why"))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EVar "each"))))))
(DTypeSig false "isEPProduct" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPProduct" ((PCon "EPProduct" PWild)) (EVar "True"))
(DFunDef false "isEPProduct" (PWild) (EVar "False"))
(DTypeSig false "isEPName" (TyFun (TyCon "EffParamTy") (TyCon "Bool")))
(DFunDef false "isEPName" ((PCon "EPName" PWild)) (EVar "True"))
(DFunDef false "isEPName" (PWild) (EVar "False"))
(DTypeSig false "axisNamesArgument" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Bool")))
(DFunDef false "axisNamesArgument" ((PVar "axes")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "isEPName") (EApp (EVar "snd") (EVar "a"))))) (EVar "axes")))
(DTypeSig false "qualifyByAll" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "qualifyByAll" ((PVar "etbl") (PVar "ns") (PVar "t")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EListLit (EApp (EVar "AVar") (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EVar "ns"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "cells")) (EBinOp "==" (EApp (EVar "listLen") (EVar "cells")) (EApp (EVar "listLen") (EVar "ns")))) (EApp (EApp (EVar "TQual") (EVar "t")) (EApp (EVar "authJoinAll") (EVar "cells"))) (EVar "t")))))
(DTypeSig false "appFallback" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "appFallback" ((PVar "mctx") PWild PWild (PVar "o") (PVar "n") (PList)) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))
(DFunDef false "appFallback" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "o") (PVar "n") (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldAppFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a")))) (EVar "as2")))
(DTypeSig false "foldAppFallback" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono")))))))
(DFunDef false "foldAppFallback" ((PVar "mctx") PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldAppFallback" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldAppFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a")))) (EVar "as2")))
(DTypeSig false "fromAstTypeApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "fromAstTypeApp" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "o") (PVar "n") (PVar "args")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EBlock (DoLet false false (PTuple (PVar "etbl2") (PVar "tvs2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgScope") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "key")) (EVar "params")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl2")) (EVar "tvs2")) (EVar "rhs"))))) (arm (PCon "Some" (PTuple (PVar "params") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAliasArity")) (EApp (EApp (EApp (EVar "aliasArityMsg") (EVar "n")) (EApp (EVar "listLen") (EVar "params"))) (EApp (EVar "listLen") (EVar "args"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "appFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args"))))) (arm PWild () (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldAppKinds") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n"))) (EVar "kinds")) (EVar "args"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "appFallback") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "o")) (EVar "n")) (EVar "args")))))))))
(DTypeSig false "aliasArgScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))))))
(DFunDef false "aliasArgScope" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "key") (PVar "params") (PVar "args")) (EBlock (DoLet false false (PVar "kinds") (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "KType"))) (EVar "params")))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")))) (DoLet false false (PVar "bound") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "params")) (EVar "kinds")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsUnion") (EApp (EVar "fst") (EVar "bound"))) (EVar "etbl")) (EBinOp "++" (EApp (EVar "snd") (EVar "bound")) (EVar "tvs"))))))
(DTypeSig false "aliasScopeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Ty"))))))))
(DFunDef false "aliasScopeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "ty")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "None") (EMatch (EApp (EVar "tyAppSpine") (EVar "ty")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EBlock (DoLet false false (PTuple (PVar "etbl2") (PVar "tvs2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgScope") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "key")) (EVar "params")) (EVar "args"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "etbl2") (EVar "tvs2") (EVar "rhs")))))) (arm PWild () (EVar "None")))))) (arm PWild () (EVar "None")))))
(DTypeSig false "aliasArgBindings" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyCon "SigVars") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KRow") (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "aliasRowParamCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg")))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsWithRows") (EListLit (ETuple (EVar "p") (EVar "cell")))) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "pat")) (EApp (EVar "Some") (EVar "p")))) (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EVar "arg")))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EApp (EVar "sigVarsWithAuths") (EListLit (ETuple (EVar "p") (EVar "cell")))) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons (PVar "arg") (PVar "args"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasArgBindings") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ps")) (EVar "ks")) (EVar "args"))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "rest")) (EBinOp "::" (ETuple (EVar "p") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg"))) (EApp (EVar "snd") (EVar "rest")))))))
(DFunDef false "aliasArgBindings" ((PVar "mctx") PWild PWild PWild PWild PWild) (ETuple (EVar "emptySigVars") (EListLit)))
(DTypeSig false "aliasRowParamCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "aliasRowParamCell" ((PVar "gctx") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell")))) (EVar "cell"))
(DFunDef false "aliasRowParamCell" ((PVar "gctx") (PVar "row")) (EApp (EVar "Ref") (EApp (EApp (EVar "ELink") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EVar "row"))))
(DTypeSig false "fromAstTypeVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Mono")))))))))
(DFunDef false "fromAstTypeVarApp" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "h") (PVar "args") (PVar "a") (PVar "b")) (EIf (EApp (EApp (EApp (EVar "anyRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "foldRowSlotArgs") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EVar "TyVar") (EVar "h")))) (EVar "args")) (EIf (EVar "otherwise") (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRowSlotArg" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "isRowSlotArg" ((PVar "etbl") (PVar "tvs") (PCon "TyVar" (PVar "n"))) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows"))) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")))))
(DFunDef false "isRowSlotArg" (PWild PWild (PCon "TyRow" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRowSlotArg" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyRowSlotArg" (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "anyRowSlotArg" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyRowSlotArg" ((PVar "etbl") (PVar "tvs") (PCons (PVar "t") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "isRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "t")) (EApp (EApp (EApp (EVar "anyRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "rest"))))
(DTypeSig false "foldRowSlotArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono")))))))
(DFunDef false "foldRowSlotArgs" ((PVar "mctx") PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldRowSlotArgs" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "arg") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldRowSlotArgs") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EVar "rowSlotArgMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")))) (EVar "rest")))
(DTypeSig false "rowSlotArgMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono"))))))
(DFunDef false "rowSlotArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "arg")) (EIf (EApp (EApp (EApp (EVar "isRowSlotArg") (EVar "etbl")) (EVar "tvs")) (EVar "arg")) (EApp (EVar "TEff") (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAppKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Mono"))))))))
(DFunDef false "foldAppKinds" ((PVar "mctx") PWild PWild (PVar "acc") (PList) (PList)) (EVar "acc"))
(DFunDef false "foldAppKinds" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "acc") (PCons (PVar "k") (PVar "ks")) (PCons (PVar "a") (PVar "as2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldAppKinds") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EApp (EApp (EVar "TApp") (EVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "kindArgMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "k")) (EVar "a")))) (EVar "ks")) (EVar "as2")))
(DFunDef false "foldAppKinds" ((PVar "mctx") PWild PWild (PVar "acc") PWild PWild) (EVar "acc"))
(DTypeSig false "kindArgMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Kind") (TyFun (TyCon "Ty") (TyCon "Mono")))))))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KType") (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "arg")))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KRow") (PVar "arg")) (EApp (EVar "TEff") (EApp (EApp (EApp (EVar "rowArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "arg"))))
(DFunDef false "kindArgMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "arg")) (EBlock (DoLet false false (PVar "q") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EVar "arg"))) (DoExpr (EApp (EVar "TAuth") (EIf (EVar "pat") (EApp (EVar "authPatternClose") (EVar "q")) (EVar "q"))))))
(DTypeSig false "authArgOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyCon "Authority"))))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "cell")))) (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l")))) (ELit LUnit))) (DoExpr (EApp (EVar "AVar") (EVar "cell"))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EVar "mctx")) (EVar "TAuthorityKind")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs"))) (EApp (EApp (EVar "typeVarAsAuthorityMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l"))) (EApp (EVar "nameNotAuthorityMsg") (EVar "n"))))) (DoExpr (EApp (EVar "authTop") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "TyAuth" (PVar "ps") (PVar "loc"))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isEPName") (EVar "p"))))) (EVar "ps"))) (DoLet false false (PVar "problems") (EApp (EApp (EApp (EVar "writtenTermProblems") (EApp (EVar "effLabelName") (EVar "l"))) (EVar "top")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "why")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectParam")) (EVar "loc")) (EApp (EApp (EVar "effectParamMsg") (EApp (EVar "effLabelName") (EVar "l"))) (EVar "why"))))) (ELit LUnit)) (EVar "problems"))) (DoExpr (EIf (EBinOp "&&" (EVar "pat") (EApp (EVar "isEmptyL") (EVar "problems"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "lit")) (EBlock (DoLet false false (PVar "written") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "lit"))) (DoExpr (EIf (EApp (EVar "isPatternParam") (EVar "written")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EVar "loc")) (EApp (EApp (EApp (EVar "exactInPatternSlotMsg") (EApp (EVar "effLabelName") (EVar "l"))) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EListLit (EVar "lit")))) (EApp (EApp (EApp (EVar "ppAuthArg") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EApp (EVar "AConst") (EApp (EVar "extendParam") (EVar "written"))))))))))) (ELit LUnit)) (EVar "lits")) (ELit LUnit))) (DoExpr (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "authTermOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat"))) (EVar "ps"))))))
(DFunDef false "authArgOf" ((PVar "mctx") (PVar "etbl") PWild (PVar "l") (PVar "pat") (PVar "ty")) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "ordinaryBinderIn") (EVar "etbl")) (EVar "pat")) (EVar "ty")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityPattern")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EVar "ordinaryInPatternSlotMsg") (EVar "n")) (EApp (EVar "effLabelName") (EVar "l"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TAuthorityKind")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EVar "typeAsAuthorityMsg") (EApp (EVar "ppTy") (EVar "ty"))) (EBinOp "++" (EApp (EVar "effLabelName") (EVar "l")) (EApp (EVar "patternMark") (EVar "pat")))))))) (DoExpr (EApp (EVar "authTop") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))))))
(DTypeSig false "ordinaryBinderIn" (TyFun (TyCon "SigVars") (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "ordinaryBinderIn" ((PVar "etbl") (PCon "True") (PCon "TyRow" (PList) (PVar "names") PWild)) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "isOrdinaryBinder") (EVar "etbl")) (EVar "n")))) (EVar "names")) (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None"))))
(DFunDef false "ordinaryBinderIn" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "isOrdinaryBinder" (TyFun (TyCon "SigVars") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isOrdinaryBinder" ((PVar "etbl") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svAuths")) (arm (PCon "Some" (PVar "cell")) () (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "cell")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "authTermOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyFun (TyCon "EffParamTy") (TyCon "Authority"))))))))
(DFunDef false "authTermOf" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PVar "l") (PVar "pat") (PCon "EPName" (PVar "n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authArgOf") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "l")) (EVar "pat")) (EApp (EVar "TyVar") (EVar "n"))))
(DFunDef false "authTermOf" ((PVar "mctx") PWild PWild (PVar "l") PWild (PVar "p")) (EApp (EVar "AConst") (EApp (EApp (EVar "writtenParam") (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "p"))))
(DTypeSig false "rowArgOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyCon "Ty") (TyCon "EffRow")))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "etbl") "svRows")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell")))) (arm (PCon "None") () (EVar "pureRow"))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "rowArgOf" ((PVar "mctx") (PVar "etbl") (PCon "TyRow" (PVar "labels") (PVar "tail") PWild)) (EApp (EApp (EVar "EffRow") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "labels"))) (EApp (EApp (EApp (EVar "tailCell") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "etbl")) (EVar "tail"))))
(DFunDef false "rowArgOf" ((PVar "mctx") PWild (PVar "ty")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EVar "typeInRowSlotMsg") (EVar "ty")))) (DoExpr (EVar "pureRow"))))
(DTypeSig true "rowArgNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rowArgNames" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EApp (EApp (EApp (EVar "qualifiedKindScope") (EVar "mctx")) (EListLit)) (EVar "ty"))) (EVar "ty")))
(DTypeSig true "qualifiedKindScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "qualifiedKindScope" ((PVar "mctx") (PVar "scope") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "qualifiedConstraintKinds") (EVar "mctx")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "scope")) (EApp (EVar "sigConstraintsOf") (EVar "ty"))))
(DTypeSig false "qualifiedConstraintKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))
(DFunDef false "qualifiedConstraintKinds" ((PVar "mctx") PWild (PVar "scope") (PList)) (EVar "scope"))
(DFunDef false "qualifiedConstraintKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons (PRec "Constraint" ((rf "constraintHead" None) (rf "constraintOrigin" None) (rf "constraintArgs" None)) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value")) (DoLet false false (PVar "cur") (EApp (EApp (EVar "declEnvsOrdOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (EVar "envs"))) (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "constraintOrigin")) (EVar "constraintHead")))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EFieldAccess (EVar "envs") "deIfaces")) (arm (PCon "None") () (EVar "scope")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "scope")) (EApp (EVar "ceRowParamKinds") (EVar "row"))) (EVar "constraintArgs"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "qualifiedConstraintKinds") (EVar "mctx")) (EVar "loc")) (EVar "next")) (EVar "rest")))))
(DTypeSig false "qualifiedArgumentKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons (PVar "kinds") (PVar "restKinds")) (PCons (PCon "TyVar" (PVar "name")) (PVar "restArgs"))) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "scope")) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "name") (EVar "kinds")) (EVar "scope"))) (arm (PCon "Some" (PVar "previous")) () (EBlock (DoExpr (EIf (EApp (EApp (EVar "kindsEq") (EVar "previous")) (EVar "kinds")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "signature parameter `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` has incompatible required kinds `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "previous")))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "kinds")))) (ELit (LString "`; use separate parameters, or constraints requiring one kind")))))) (DoExpr (EVar "scope")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "next")) (EVar "restKinds")) (EVar "restArgs")))))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") (PVar "loc") (PVar "scope") (PCons PWild (PVar "restKinds")) (PCons PWild (PVar "restArgs"))) (EApp (EApp (EApp (EApp (EApp (EVar "qualifiedArgumentKinds") (EVar "mctx")) (EVar "loc")) (EVar "scope")) (EVar "restKinds")) (EVar "restArgs")))
(DFunDef false "qualifiedArgumentKinds" ((PVar "mctx") PWild (PVar "scope") PWild PWild) (EVar "scope"))
(DTypeSig true "rowArgNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "kinded") (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "rowArgNamesApp") (EVar "mctx")) (EVar "scope")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "rowArgNamesVarApp") (EVar "mctx")) (EVar "scope")) (EVar "h")) (EVar "args"))) (arm PWild () (EVar "None")))) (DoExpr (EMatch (EVar "kinded") (arm (PCon "Some" (PVar "names")) () (EVar "names")) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "ts")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgNamesIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "rowArgNamesApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "rowArgNamesApp" ((PVar "mctx") (PVar "scope") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "krowArgVarNames") (EVar "kinds")) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "rowArgNamesVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "rowArgNamesVarApp" ((PVar "mctx") (PVar "scope") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "krowArgVarNames") (EVar "kinds")) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "krowArgVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "krowArgVarNames" ((PList) PWild) (EListLit))
(DFunDef false "krowArgVarNames" (PWild (PList)) (EListLit))
(DFunDef false "krowArgVarNames" ((PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "krowArgVarNames" ((PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TyRow" PWild (PVar "tails") PWild) (PVar "as2"))) (EBinOp "++" (EVar "tails") (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2"))))
(DFunDef false "krowArgVarNames" ((PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EVar "krowArgVarNames") (EVar "ks")) (EVar "as2")))
(DTypeSig true "sigConstraintsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "sigConstraintsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EVar "cs") (EApp (EVar "sigConstraintsOf") (EVar "t"))))
(DFunDef false "sigConstraintsOf" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "sigConstraintsOf") (EVar "t")))
(DFunDef false "sigConstraintsOf" (PWild) (EListLit))
(DTypeSig true "recFieldMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "recFieldMono" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "Field" (PVar "fn") (PVar "ty"))) (ETuple (EVar "fn") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))
(DTypeSig false "kindAnnHasEffect" (TyFun (TyCon "KindAnn") (TyCon "Bool")))
(DFunDef false "kindAnnHasEffect" ((PCon "KindEffect")) (EVar "True"))
(DFunDef false "kindAnnHasEffect" ((PCon "KindAuthority" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "kindAnnHasEffect" ((PCon "KindArrow" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EVar "kindAnnHasEffect") (EVar "a")) (EApp (EVar "kindAnnHasEffect") (EVar "b"))))
(DFunDef false "kindAnnHasEffect" (PWild) (EVar "False"))
(DTypeSig true "kindsEq" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool"))))
(DFunDef false "kindsEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "kindsEq" ((PCons (PCon "KType") (PVar "a")) (PCons (PCon "KType") (PVar "b"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b")))
(DFunDef false "kindsEq" ((PCons (PCon "KRow") (PVar "a")) (PCons (PCon "KRow") (PVar "b"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b")))
(DFunDef false "kindsEq" ((PCons (PCon "KAuth" (PVar "l1") (PVar "p1")) (PVar "a")) (PCons (PCon "KAuth" (PVar "l2") (PVar "p2")) (PVar "b"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "labelKey") (EVar "l1")) (EApp (EVar "labelKey") (EVar "l2"))) (EBinOp "==" (EVar "p1") (EVar "p2"))) (EApp (EApp (EVar "kindsEq") (EVar "a")) (EVar "b"))))
(DFunDef false "kindsEq" (PWild PWild) (EVar "False"))
(DTypeSig true "reportUnboundAuthorityNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "SigVars") (TyCon "Unit")))))
(DFunDef false "reportUnboundAuthorityNamesIn" ((PVar "mctx") (PVar "tys") (PVar "sv")) (EApp (EApp (EVar "each") (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "reportUnboundAuthorityNames") (EVar "mctx")) (EVar "t")) (EVar "sv")))) (EVar "tys")))
(DTypeSig true "payloadTypesE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "payloadTypesE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "ConPos" (PVar "tys"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "tys")))
(DFunDef false "payloadTypesE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "fieldTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "fields")))
(DTypeSig false "fieldTypeE" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Field") (TyCon "Mono"))))))
(DFunDef false "fieldTypeE" ((PVar "mctx") (PVar "etbl") (PVar "tvs") (PCon "Field" PWild (PVar "ty"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")))
(DTypeSig true "reqTyToMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyVar" (PVar "n"))) (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EMethodRef "sub"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") PWild (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "n")))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TApp") (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "a"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "b"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "TFun") (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "a"))) (EApp (EApp (EVar "openRow") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "b"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "tupleSpineOf") (EApp (EVar "tconTupleHead") (EApp (EVar "listLen") (EVar "ts")))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub"))) (EVar "ts"))))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "t")))
(DFunDef false "reqTyToMono" ((PVar "mctx") (PVar "sub") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EMethodRef "sub")) (EVar "t")))
(DFunDef false "reqTyToMono" ((PVar "mctx") PWild (PCon "TyRow" (PVar "labels") (PVar "tail") (PVar "loc"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TEffectKindMismatch")) (EVar "loc")) (EApp (EApp (EVar "rowKindMismatchMsg") (EVar "labels")) (EVar "tail")))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig true "expandAliasHeadTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandAliasHeadTy" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EVar "expandAliasHeadTyWith") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "ty")))
(DTypeSig true "expandAliasHeadTyWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandAliasHeadTyWith" ((PVar "aliases") (PAs "t" (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false))) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (ELit (LInt 0))))) (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "rhs"))) (arm PWild () (EVar "t"))))
(DFunDef false "expandAliasHeadTyWith" ((PVar "aliases") (PAs "t" (PCon "TyApp" PWild PWild))) (EMatch (EApp (EVar "tyAppSpine") (EVar "t")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EApp (EApp (EVar "substAliasArgs") (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "rhs")))) (arm PWild () (EVar "t")))) (arm PWild () (EVar "t"))))
(DFunDef false "expandAliasHeadTyWith" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "substTyVars" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyVar" (PVar "n"))) (EApp (EApp (EVar "optionOr") (EApp (EVar "TyVar") (EVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EMethodRef "sub"))))
(DFunDef false "substTyVars" (PWild (PAs "t" (PRec "TyCon" () false))) (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConLoc" (EVar "None")))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "a"))) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "b"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "a"))) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "b"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTyVars") (EMethodRef "sub"))) (EVar "ts"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyEffect" (PVar "es") (PVar "eff") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "eff")) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "t"))))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "t"))))
(DFunDef false "substTyVars" (PWild (PCon "TyRow" (PVar "es") (PVar "eff") (PVar "l"))) (EApp (EApp (EApp (EVar "TyRow") (EVar "es")) (EVar "eff")) (EVar "l")))
(DFunDef false "substTyVars" (PWild (PCon "TyAuth" (PVar "p") (PVar "l"))) (EApp (EApp (EVar "TyAuth") (EVar "p")) (EVar "l")))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "t"))) (EVar "d")))
(DFunDef false "substTyVars" ((PVar "sub") (PCon "TyQual" (PVar "t") (PVar "ns") (PVar "l"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EVar "t"))) (EVar "ns")) (EVar "l")))
(DTypeSig true "substAliasArgs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substAliasArgs" ((PVar "sub") (PVar "rhs")) (EApp (EApp (EVar "substTyVars") (EMethodRef "sub")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (EApp (EVar "substRowTailsAt") (EMethodRef "sub"))) (EVar "rhs")))))
(DTypeSig false "substRowTailsAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "substRowTailsAt" ((PVar "sub") (PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "extra") (PVar "tails2")) (EApp (EApp (EVar "spliceRowTails") (EMethodRef "sub")) (EVar "tails"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EBinOp "++" (EVar "atoms") (EVar "extra"))) (EVar "tails2")) (EVar "t")) (EVar "False")))))
(DFunDef false "substRowTailsAt" ((PVar "sub") (PCon "TyRow" (PVar "atoms") (PVar "tails") (PVar "l"))) (EBlock (DoLet false false (PTuple (PVar "extra") (PVar "tails2")) (EApp (EApp (EVar "spliceRowTails") (EMethodRef "sub")) (EVar "tails"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyRow") (EBinOp "++" (EVar "atoms") (EVar "extra"))) (EVar "tails2")) (EVar "l")) (EVar "False")))))
(DFunDef false "substRowTailsAt" (PWild (PVar "t")) (ETuple (EVar "t") (EVar "False")))
(DTypeSig false "spliceRowTails" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "spliceRowTails" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spliceRowTails" ((PVar "sub") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "names")) (EApp (EApp (EVar "spliceRowTails") (EMethodRef "sub")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EMethodRef "sub")) (arm (PCon "Some" (PCon "TyRow" (PVar "written") (PVar "tails") PWild)) () (ETuple (EBinOp "++" (EVar "written") (EVar "atoms")) (EBinOp "++" (EVar "tails") (EVar "names")))) (arm (PCon "Some" (PCon "TyEffect" (PVar "written") (PVar "tails") PWild)) () (ETuple (EBinOp "++" (EVar "written") (EVar "atoms")) (EBinOp "++" (EVar "tails") (EVar "names")))) (arm (PCon "Some" (PCon "TyVar" (PVar "v"))) () (ETuple (EVar "atoms") (EBinOp "::" (EVar "v") (EVar "names")))) (arm PWild () (ETuple (EVar "atoms") (EBinOp "::" (EVar "n") (EVar "names"))))))))
