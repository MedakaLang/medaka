# META
source_lines=658
stages=DESUGAR,MARK
# SOURCE
-- tc_grants: capability grant recording: which grants a binding records (the top, recursive,
-- local and method grant rows and the occurrences that carry them), and the file-bound values a
-- clause's grants fix (authority bounds at binding boundaries: keys, recording, flow and settle
-- checks).
--
-- Spec: EFFECTS section 2.3, section 4.1, section 8.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_effects`,
-- `tc_occurrence`, `tc_mark`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`,
-- `tc_global`, `tc_stamp`, `tc_module`.

import support.diag_codes.{DiagCode(..)}
import types.tc_types.{
  BindingRole(..),
  grantTopKey,
  methodGrantKey,
  setGrantIds,
  AbsorptionEvent(..),
  GrantBinder(..),
  GrantCallee(..),
  GrantOcc(..),
  MethodGrant(..),
  GraphCtx,
  MethodSchemeRow,
  ModuleCtx,
  SelectedValueOccurrence,
  TcEnv,
}
import types.tc_mono.{
  arrowArity,
  authCellsIn,
  authOrderIn,
  authOrderRow,
  authRowCells,
  containsI,
  funArity,
  schemeAuthIds,
  tyArrowCount,
}
import types.tc_state.{currentScopeStore, wPushAll, wRestore, wWindow}
import types.tc_env.{lookupBinding}
import types.tc_diag.{pushTypeErrorOncePerSite}
import types.tc_unify.{captureScope}
import types.tc_solve.{isLocalAbsName}
import types.expr_loc.{isNoLoc}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  authHasVars,
  authIsTop,
  authSub,
  authvarName,
}
import types.effect_rows.{
  Atom(..),
  EffLabel(..),
  EffRow(..),
  Effvar(..),
  atomAuth,
  atomKey,
  atomLabelOf,
  rowFlat,
}
import types.repr.{
  AuthResidual(..),
  Mono(..),
  Scheme(..),
  lookupAssocI,
  normalize,
  ppMonosShared,
  IfaceRef(..),
}
import types.effect_bindings.{BindingSummary(..)}
import frontend.ast.{
  Decl(..),
  EffAtomTy(..),
  EvId(..),
  Expr(..),
  IfaceMethod(..),
  LetBind(..),
  Loc(..),
  Pat(..),
  Ty(..),
  TyConOrigin(..),
  Lit(..),
}
import map.{Map(..)}
import support.ordmap.{
  omDelete, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import types.evidence.{ScopeId(..)}
import types.effect_solver.{ScopeRoles(..)}
import support.util.{
  anyList, filterList, isEmptyL, isNonEmptyL, lookupAssoc, reverseL
}
import list.{reverse}
import types.route_key.{ifaceWordOf}
import frontend.desugar.{mapChildren, mapExpr}
import types.scopes as Scopes
import types.runtime_grants.{fileGrantExterns}
import map as IdMap
import types.scopes.{ScopeOwner(..)}
import types.effect_domain.{Param(..)}

export
evOrdinal : EvId -> Int
evOrdinal (EvId _ i) = i

-- Grants are passed only on a graph whose driver ran the marking preamble: a
-- driver that never marks has no use that could carry one.
grantsEnabled : GraphCtx -> Unit -> Bool
grantsEnabled gctx _ = isSome gctx.markSetsRef.value

-- What a use of [name] in the module being marked denotes.  An extern the module
-- declares or imports is a foreign declaration, and one spelled like a catalog
-- file extern binds that same runtime operation (a redeclaration must agree with
-- the catalog row); any other value the module defines or imports is a source
-- binding; a name the module neither defines nor imports is the catalog extern
-- when the catalog declares it.
grantCalleeOf : ModuleCtx -> String -> GrantCallee
grantCalleeOf mctx name
  | isLocalAbsName name = SourceCallee
  | otherwise = match mctx.mcCells.markingRef.value
    Some mm =>
      if omHasKey name mm.mmExterns then
        externCallee name
      else if omHasKey name mm.mmUserNames then
        SourceCallee
      else
        catalogCallee mctx.mcGraph name
    None => catalogCallee mctx.mcGraph name

catalogCallee : GraphCtx -> String -> GrantCallee
catalogCallee gctx name =
  if omHasKey name gctx.builtinExternNamesRef.value then
    externCallee name
  else
    SourceCallee

externCallee : String -> GrantCallee
externCallee name =
  if omHasKey name fileGrantExterns then FileExternCallee else NoGrantCallee

-- Whether the marker gives a use of [n] a grant identity: the binding [n] denotes
-- in [env] is a value, not an interface method (whose uses are method
-- occurrences), that takes grants, and its own scheme quantifies an authority.
export
grantNameIn : TcEnv -> String -> Bool
grantNameIn env n
  | not (grantsEnabled env.teDyn.dcModule.mcGraph ()) = False
  | otherwise = match lookupBinding env n
    Some b => match b.ebMethodRow
      Some _ => False
      None =>
        calleeTakesGrants (grantCalleeOf env.teDyn.dcModule n)
          && isNonEmptyL (schemeAuthIds b.ebValue.vsScheme)
    None => False

calleeTakesGrants : GrantCallee -> Bool
calleeTakesGrants SourceCallee = True
calleeTakesGrants FileExternCallee = True
calleeTakesGrants NoGrantCallee = False

-- A scheme's quantified authorities in grant order: first occurrence in the
-- type read left to right (an arrow's domain, its row, its result), so a
-- scheme and every copy of it list them alike whatever ids they carry.
export
grantOrder : Scheme -> List Int
grantOrder (Forall _ _ [] _ _ _) = []
grantOrder (Forall _ _ avars _ force body) =
  let seen = reverseL (authOrderRow force (authOrderIn body []))
  let quantified = filterList (i => containsI i avars) seen
  quantified ++ filterList (i => not (containsI i quantified)) avars

export
grantOccOf : GraphCtx -> EvId -> Option GrantOcc
grantOccOf gctx ev = IdMap.get (evOrdinal ev) gctx.graphRun.grants.gsOccs.value

setGrantOcc : GraphCtx -> EvId -> GrantOcc -> Unit
setGrantOcc gctx ev occ =
  let st = gctx.graphRun.grants
  st.gsOccs := IdMap.set (evOrdinal ev) occ st.gsOccs.value

-- The binding id resolve's stamp would have given this use: its top-level
-- binder's, or 0 for an imported name.
export
grantOnlyBindingId : ModuleCtx -> String -> Int
grantOnlyBindingId mctx name = match mctx.mcCells.markingRef.value
  Some mm => optionOr 0 (omLookup name mm.mmTop)
  None => 0

export
recordGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Unit
recordGrantOcc mctx name ev (scheme@(Forall _ _ _ _ _ body)) subst =
  match grantCalleeOf mctx name
    NoGrantCallee => ()
    SourceCallee => recordOccWith mctx name ev scheme subst None False
    FileExternCallee =>
      recordOccWith mctx name ev scheme subst (Some (arrowArity body)) False

-- A method candidate's use: its grants follow its value arguments.
export
recordMethodGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Unit
recordMethodGrantOcc mctx name ev (scheme@(Forall _ _ _ _ _ body)) subst =
  recordOccWith mctx name ev scheme subst (Some (arrowArity body)) False

-- A method occurrence typed as the standalone binding its name shadows: that
-- binding's grants, leading its arguments.
export
recordStandaloneGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Int ->
  Unit
recordStandaloneGrantOcc mctx name ev scheme subst arity =
  recordOccWith mctx name ev scheme subst (Some arity) True

recordOccWith : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Option Int ->
  Bool ->
  Unit
recordOccWith mctx name ev scheme subst trailing standalone =
  match grantOrder scheme
    [] => ()
    ids => setGrantOcc mctx.mcGraph ev GrantOcc {
      goCallee = name,
      goCells = map (i => optionOr (AJoin []) (lookupAssocI i subst)) ids,
      goRecIds = [],
      goTrailing = trailing,
      goChain = grantChainAt mctx.mcGraph (captureScope mctx ()),
      goStandalone = standalone,
    }

-- The evidence id of the method occurrence heading an application spine.
export
spineHeadEv : Expr -> Option EvId
spineHeadEv (ELoc _ e) = spineHeadEv e
spineHeadEv (EApp f _) = spineHeadEv f
spineHeadEv (EMethodAt _ _ ev) = Some ev
-- any other head is not a method occurrence
spineHeadEv _ = None

-- A shadow application's head, typed as the standalone [occurrence] selected.
export
recordStandaloneAt : ModuleCtx ->
  String ->
  Expr ->
  SelectedValueOccurrence ->
  Unit
recordStandaloneAt mctx name hd occurrence = match spineHeadEv hd
  Some ev =>
    recordStandaloneGrantOcc
      mctx
      name
      ev
      occurrence.svoScheme
      occurrence.svoInstance.mtiSubstitution.misAuthSubst
      (funArity occurrence.svoInstance.mtiBody)
  None => ()

export
methodGrantOf : GraphCtx -> String -> String -> Option MethodGrant
methodGrantOf gctx ifaceWord method =
  omLookup
    (methodGrantKey ifaceWord method)
    gctx.graphRun.grants.gsMethods.value

-- The interface methods a module declares whose type quantifies authorities; any
-- other method it declares has no row, whatever an earlier check of the module id
-- left.  The grants follow the arrows the written type spells, since that declared
-- arity is what the backends read; a result an alias names a function stays the
-- result.
export
recordMethodGrants : GraphCtx -> List MethodSchemeRow -> Unit
recordMethodGrants gctx rows =
  let st = gctx.graphRun.grants
  st.gsMethods :=
    fold
      (acc row =>
        let key =
          methodGrantKey
            (ifaceWordOf row.msrIface.irOrigin row.msrIface.irName)
            row.msrName
        match methodGrantOfRow row
          Some mg => omInsert key mg acc
          None => omDelete key acc)
      st.gsMethods.value
      rows

methodGrantOfRow : MethodSchemeRow -> Option MethodGrant
methodGrantOfRow row = match row.msrScheme
  Forall _ _ _ _ force body => match grantOrder row.msrScheme
    [] => None
    ids =>
      let cells = authCellsIn body (authRowCells force Tip)
      Some MethodGrant {
        mgArity = tyArrowCount row.msrType,
        mgNames =
          map
            (i => match IdMap.get i cells
              Some cell => optionOr "" (authvarName cell)
              None => "")
            ids,
      }

-- Authority variables no caller supplies, whose grant is the whole domain: the
-- escape check has already held every declaration they reach to its label's top.
export
markSourceless : GraphCtx -> List Int -> Unit
markSourceless gctx ids =
  let st = gctx.graphRun.grants
  st.gsSourceless := fold (m i => IdMap.set i () m) st.gsSourceless.value ids

-- The binders around [sid] whose authority parameters a grant may forward,
-- innermost first.
grantChainAt : GraphCtx -> ScopeId -> List GrantBinder
grantChainAt gctx (sid@(ScopeId i)) =
  let frame = Scopes.scopeFrame (currentScopeStore gctx ()) sid
  let outer = match frame.sfParent
    Some parent => grantChainAt gctx parent
    None => []
  let own = match frame.sfOwner
    BindingOwner n => TopGrantBinder frame.sfModuleId n :: outer
    LocalBindingOwner n => LocalGrantBinder n :: outer
    _ => outer
  match IdMap.get i gctx.graphRun.grants.gsBodies.value
    Some body => body :: own
    None => own

-- A generalized top-level group: each member whose scheme quantifies
-- authorities takes them as parameters, and each use of such a member inside
-- the group that instantiated nothing (its type was the member's own) forwards
-- them.  A member that takes none has no row, whatever an earlier check of the
-- module id left.
export
recordTopGrants : GraphCtx ->
  String ->
  List (String, Scheme) ->
  OrdMap (List (List Pat, Expr)) ->
  Unit
recordTopGrants gctx mid schemes grouped =
  let st = gctx.graphRun.grants
  let enabled = grantsEnabled gctx ()
  let granted =
    map ((n, sch) => (n, if enabled then grantOrder sch else [])) schemes
  each (e => setGrantIds st.gsTopIds (grantTopKey mid (fst e), snd e)) granted
  let taking = filterList (e => isNonEmptyL (snd e)) granted
  match taking
    [] => ()
    _ =>
      st.gsTakers := omFromNames (map fst taking) st.gsTakers.value
      each
        ((m, _) =>
          each
            (clause => recordRecursiveGrants gctx mid m taking (snd clause))
            (clausesOf m grouped))
        schemes

recordRecursiveGrants : GraphCtx ->
  String ->
  String ->
  List (String, List Int) ->
  Expr ->
  Unit
recordRecursiveGrants gctx mid m taking body =
  let visit =
    e => match e
      EDictAt n ev => match (lookupAssoc n taking, grantOccOf gctx ev)
        (Some ids, None) =>
          setGrantOcc gctx ev GrantOcc {
            goCallee = n,
            goCells = [],
            goRecIds = ids,
            goTrailing = None,
            goChain = [TopGrantBinder mid m],
            goStandalone = False,
          }
          e
        _ => e
      _ => e
  let _ = mapExpr visit body
  ()

-- A generalized candidate local: its quantified authorities become its
-- parameters, and its uses inside its own right-hand side forward them.
export
registerLocalGrants : GraphCtx -> String -> Scheme -> Unit
registerLocalGrants gctx name sch = match grantOrder sch
  [] => ()
  ids =>
    let st = gctx.graphRun.grants
    st.gsLocalIds := omInsert name ids st.gsLocalIds.value
    let recOccs =
      optionOr [] (omLookup name gctx.graphRun.localAbs.lasRecOccs.value)
    each
      (occ => setGrantOcc gctx (fst occ) GrantOcc {
        goCallee = name,
        goCells = [],
        goRecIds = ids,
        goTrailing = None,
        goChain = grantChainAt gctx (snd occ),
        goStandalone = False,
      })
      recOccs

-- Chunk C: number of arguments applied in this spine (`f a b c` ⇒ 3).
export
appSpineArgCount : Expr -> Int
appSpineArgCount (ELoc _ e) = appSpineArgCount e
appSpineArgCount (EDoOrigin _ e) = appSpineArgCount e
appSpineArgCount (EAnnot e _) = appSpineArgCount e
appSpineArgCount (EApp f _) = 1 + appSpineArgCount f
appSpineArgCount _ = 0

-- A declared file row bounds every operation performed while its body runs,
-- including operations in helpers and callbacks. The bound is checked in
-- addition to each extern's own grant; a statically named symlink can change
-- the physical order between the two authorities.
fileBoundKey : Loc -> String
fileBoundKey (Loc file line col endLine endCol) =
  "\{file}:\{intToString line}:\{intToString col}:\{intToString endLine}:\{intToString endCol}"

-- Some application and block roots carry locations only on their children.
-- Key the body by its first source node, and guard the whole body at its
-- binding/lambda seam, rather than guarding that child alone.  A tree parsed
-- without locations gives every node the same placeholder span, which would
-- key every body of the module alike and hand one body's bound to all of them,
-- so a placeholder identifies no body.
export
fileBodyLoc : Expr -> Option Loc
fileBodyLoc e = match firstSpan e
  Some l if not (isNoLoc l) => Some l
  _ => None

firstSpan : Expr -> Option Loc
firstSpan (ELoc l _) = Some l
firstSpan e =
  let found = Ref None
  let _ =
    mapChildren
      (child =>
        match found.value
          None => found := firstSpan child
          Some _ => ()
        child)
      e
  found.value

export
fileBoundSite : String -> Loc -> String
-- Parsed locations may have an empty file field; the module keeps equal
-- source spans in different modules from sharing a bound.
fileBoundSite mid loc =
  "\{intToString (stringLength mid)}:\{mid}:\{fileBoundKey loc}"

scopeFileBoundModule : ModuleCtx -> Unit -> String
scopeFileBoundModule mctx _ =
  (Scopes.scopeFrame
    (currentScopeStore mctx.mcGraph ())
    (captureScope mctx ())).sfModuleId

export
fileValueKey : String -> Expr -> Option String
fileValueKey mid e =
  map (loc => "\{fileBoundSite mid loc}:\{fileValueShape e}") (fileBodyLoc e)

fileValueShape : Expr -> String
fileValueShape (ELoc _ _) = "loc"
fileValueShape (EApp f _) = "app" ++ intToString (appSpineArgCount f + 1)
fileValueShape (ELam _ _) = "lambda"
fileValueShape _ = "value"

export
finishFileValueScope : ModuleCtx -> Unit -> Unit
finishFileValueScope mctx _ = match mctx.mcCells.fileValueScopes.value
  saved :: rest =>
    mctx.mcCells.fileValueScopes := rest
    let flows = wWindow mctx.mcCells.fileValueFlows (snd saved)
    wRestore mctx.mcCells.fileValueFlows saved
    each
      (flow =>
        if isEmptyL rest || not (unsettledFileValueFlow flow) then
          checkFileValueFlow mctx flow)
      flows
    -- A local result can be shaped by a later use in its enclosing scope.
    -- Keep its producer evidence until that receiving type is determined.
    match rest
      [] => ()
      _ =>
        wPushAll
          mctx.mcCells.fileValueFlows
          (reverseL (filterList unsettledFileValueFlow flows))
    ()
  [] => ()

unsettledFileValueFlow : (Option Loc, Mono, Mono) -> Bool
unsettledFileValueFlow (_, upper, lower) =
  unsettledPackedFileBound False upper lower

unsettledPackedFileBound : Bool -> Mono -> Mono -> Bool
unsettledPackedFileBound packed upper lower = match (
  normalize upper,
  normalize lower,
)
  (TVar _, _) => True
  (_, TVar _) => True
  (TQual u _, l) => unsettledPackedFileBound packed u l
  (u, TQual l _) => unsettledPackedFileBound packed u l
  (TApp uf ux, TApp lf lx) =>
    unsettledPackedFileBound True uf lf || unsettledPackedFileBound True ux lx
  (TFun ud ur ux, TFun ld lr lx) =>
    packed && unsettledFileRow ur lr
      || unsettledPackedFileBound packed ld ud
      || unsettledPackedFileBound packed ux lx
  _ => False

unsettledFileRow : EffRow -> EffRow -> Bool
unsettledFileRow upper lower =
  let (ua, ut) = rowFlat upper
  let (la, lt) = rowFlat lower
  isNonEmptyL ut
    || isNonEmptyL lt
    || anyList (a => narrowFileAtom a && authHasVars (atomAuth a)) (ua ++ la)

checkFileValueFlow : ModuleCtx -> (Option Loc, Mono, Mono) -> Unit
checkFileValueFlow mctx (loc, upper, lower) =
  if changesPackedFileBound False upper lower then
    pushTypeErrorOncePerSite
      mctx
      TFileBoundValue
      loc
      ("a function's file bound cannot change inside a container: "
        ++ ppMonosShared [lower, upper]
        ++ "; annotate the function with the container's FileRead or FileWrite bound before packing it")

changesPackedFileBound : Bool -> Mono -> Mono -> Bool
changesPackedFileBound packed upper lower = match (
  normalize upper,
  normalize lower,
)
  (TQual u _, l) => changesPackedFileBound packed u l
  (u, TQual l _) => changesPackedFileBound packed u l
  (TApp uf ux, TApp lf lx) =>
    changesPackedFileBound True uf lf || changesPackedFileBound True ux lx
  (TFun ud ur ux, TFun ld lr lx) =>
    packed && changesFileRow ur lr
      || changesPackedFileBound packed ld ud
      || changesPackedFileBound packed ux lx
  _ => False

changesFileRow : EffRow -> EffRow -> Bool
changesFileRow upper lower =
  let (ua, ut) = rowFlat upper
  let (la, lt) = rowFlat lower
  isEmptyL ut
    && anyList
      (u =>
        narrowFileAtom u
          && (isNonEmptyL lt
            || anyList
              (l =>
                atomKey l == atomKey u
                  && not
                    (authSub (atomAuth l) (atomAuth u)
                      && authSub (atomAuth u) (atomAuth l)))
              la))
      ua

export
hasFileBoundValue : Mono -> Bool
hasFileBoundValue t = match normalize t
  TFun _ row result =>
    let (atoms, tails) = rowFlat row
    isEmptyL tails && anyList narrowFileAtom atoms || hasFileBoundValue result
  TQual inner _ => hasFileBoundValue inner
  _ => False

export
recordValueFileBound : ModuleCtx -> Expr -> Mono -> Unit
recordValueFileBound mctx e ty =
  if hasFileBoundValue
    ty then match fileValueKey (scopeFileBoundModule mctx ()) e
    Some key =>
      let st = mctx.mcGraph.graphRun.grants
      st.gsValueBounds :=
        omInsert
          key
          ((ty, grantChainAt mctx.mcGraph (captureScope mctx ()))
            :: optionOr [] (omLookup key st.gsValueBounds.value))
          st.gsValueBounds.value
    None => ()

export
recordFileBound : ModuleCtx -> Expr -> EffRow -> Unit
recordFileBound mctx body row =
  let (atoms, tails) = rowFlat row
  if isEmptyL tails && anyList narrowFileAtom atoms then match fileBodyLoc body
    None => ()
    Some loc =>
      let st = mctx.mcGraph.graphRun.grants
      let key = fileBoundSite (scopeFileBoundModule mctx ()) loc
      st.gsBounds :=
        omInsert
          key
          ((row, grantChainAt mctx.mcGraph (captureScope mctx ()))
            :: optionOr [] (omLookup key st.gsBounds.value))
          st.gsBounds.value

export
narrowFileAtom : Atom -> Bool
narrowFileAtom atom = match atomLabelOf atom
  EffLabel label OriginBuiltin =>
    (label == "FileRead" || label == "FileWrite")
      && not (authIsTop (atomAuth atom))
  _ => False

export
recordClauseFileBound : ModuleCtx -> Expr -> Int -> Mono -> Unit
-- Bound: a where-local go over this signature is let-generalised and dictionary-passes the loop (#4921, MonoLocalBinds).
-- lint-disable-next-line rule-threaded-invariant
recordClauseFileBound mctx body arity ty
  | arity <= 0 = ()
  | otherwise = match normalize ty
    TFun _ row result =>
      if arity == 1 then
        recordFileBound mctx body row
      else
        recordClauseFileBound mctx body (arity - 1) result
    TQual inner _ => recordClauseFileBound mctx body arity inner
    _ => ()

export
clausesAt : String -> OrdMap (List (List Pat, Expr)) -> List (List Pat, Expr)
clausesAt n m = match omLookup n m
  Some xs => xs
  None => []

export
clausesOf : String -> OrdMap (List (List Pat, Expr)) -> List (List Pat, Expr)
clausesOf n m = reverse (clausesAt n m)
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BindingRole" true) (mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false) (mem "AbsorptionEvent" true) (mem "GrantBinder" true) (mem "GrantCallee" true) (mem "GrantOcc" true) (mem "MethodGrant" true) (mem "GraphCtx" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "SelectedValueOccurrence" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "arrowArity" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "authRowCells" false) (mem "containsI" false) (mem "funArity" false) (mem "schemeAuthIds" false) (mem "tyArrowCount" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "wPushAll" false) (mem "wRestore" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupBinding" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false))))
(DUse false (UseGroup ("types" "expr_loc") ((mem "isNoLoc" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authHasVars" false) (mem "authIsTop" false) (mem "authSub" false) (mem "authvarName" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomLabelOf" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMonosShared" false) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Lit" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapExpr" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "fileGrantExterns" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DTypeSig true "evOrdinal" (TyFun (TyCon "EvId") (TyCon "Int")))
(DFunDef false "evOrdinal" ((PCon "EvId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "grantsEnabled" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "grantsEnabled" ((PVar "gctx") PWild) (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value")))
(DTypeSig false "grantCalleeOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "grantCalleeOf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EVar "SourceCallee") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmExterns")) (EApp (EVar "externCallee") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmUserNames")) (EVar "SourceCallee") (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))))) (arm (PCon "None") () (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "catalogCallee" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "catalogCallee" ((PVar "gctx") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (EApp (EVar "externCallee") (EVar "name")) (EVar "SourceCallee")))
(DTypeSig false "externCallee" (TyFun (TyCon "String") (TyCon "GrantCallee")))
(DFunDef false "externCallee" ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fileGrantExterns")) (EVar "FileExternCallee") (EVar "NoGrantCallee")))
(DTypeSig true "grantNameIn" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantNameIn" ((PVar "env") (PVar "n")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "grantsEnabled") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "ebMethodRow") (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EBinOp "&&" (EApp (EVar "calleeTakesGrants") (EApp (EApp (EVar "grantCalleeOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "schemeAuthIds") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme"))))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "calleeTakesGrants" (TyFun (TyCon "GrantCallee") (TyCon "Bool")))
(DFunDef false "calleeTakesGrants" ((PCon "SourceCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "FileExternCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "NoGrantCallee")) (EVar "False"))
(DTypeSig true "grantOrder" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PList) PWild PWild PWild)) (EListLit))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PVar "avars") PWild (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "reverseL") (EApp (EApp (EVar "authOrderRow") (EVar "force")) (EApp (EApp (EVar "authOrderIn") (EVar "body")) (EListLit))))) (DoLet false false (PVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "avars")))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "quantified"))))) (EVar "avars"))))))
(DTypeSig true "grantOccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Option") (TyCon "GrantOcc")))))
(DFunDef false "grantOccOf" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsOccs") "value")))
(DTypeSig false "setGrantOcc" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyFun (TyCon "GrantOcc") (TyCon "Unit")))))
(DFunDef false "setGrantOcc" ((PVar "gctx") (PVar "ev") (PVar "occ")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsOccs")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (EVar "occ")) (EFieldAccess (EFieldAccess (EVar "st") "gsOccs") "value"))))))
(DTypeSig true "grantOnlyBindingId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "grantOnlyBindingId" ((PVar "mctx") (PVar "name")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "mm") "mmTop")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "recordGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EMatch (EApp (EApp (EVar "grantCalleeOf") (EVar "mctx")) (EVar "name")) (arm (PCon "NoGrantCallee") () (ELit LUnit)) (arm (PCon "SourceCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EVar "None")) (EVar "False"))) (arm (PCon "FileExternCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))))
(DTypeSig true "recordMethodGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))
(DTypeSig true "recordStandaloneGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordStandaloneGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "arity")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EVar "arity"))) (EVar "True")))
(DTypeSig false "recordOccWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit")))))))))
(DFunDef false "recordOccWith" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "trailing") (PVar "standalone")) (EMatch (EApp (EVar "grantOrder") (EVar "scheme")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EApp (EApp (EApp (EVar "setGrantOcc") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "optionOr") (EApp (EVar "AJoin") (EListLit))) (EApp (EApp (EVar "lookupAssocI") (EVar "i")) (EVar "subst"))))) (EVar "ids"))) (fa "goRecIds" (EListLit)) (fa "goTrailing" (EVar "trailing")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (fa "goStandalone" (EVar "standalone"))))))))
(DTypeSig true "spineHeadEv" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "EvId"))))
(DFunDef false "spineHeadEv" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHeadEv") (EVar "e")))
(DFunDef false "spineHeadEv" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHeadEv") (EVar "f")))
(DFunDef false "spineHeadEv" ((PCon "EMethodAt" PWild PWild (PVar "ev"))) (EApp (EVar "Some") (EVar "ev")))
(DFunDef false "spineHeadEv" (PWild) (EVar "None"))
(DTypeSig true "recordStandaloneAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "SelectedValueOccurrence") (TyCon "Unit"))))))
(DFunDef false "recordStandaloneAt" ((PVar "mctx") (PVar "name") (PVar "hd") (PVar "occurrence")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EFieldAccess (EVar "occurrence") "svoScheme")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiSubstitution") "misAuthSubst")) (EApp (EVar "funArity") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "methodGrantOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))))
(DFunDef false "methodGrantOf" ((PVar "gctx") (PVar "ifaceWord") (PVar "method")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "methodGrantKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsMethods") "value")))
(DTypeSig true "recordMethodGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "recordMethodGrants" ((PVar "gctx") (PVar "rows")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsMethods")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName"))) (EFieldAccess (EVar "row") "msrName"))) (DoExpr (EMatch (EApp (EVar "methodGrantOfRow") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EVar "key")) (EVar "acc")))))))) (EFieldAccess (EFieldAccess (EVar "st") "gsMethods") "value")) (EVar "rows"))))))
(DTypeSig false "methodGrantOfRow" (TyFun (TyCon "MethodSchemeRow") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))
(DFunDef false "methodGrantOfRow" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "body")) () (EMatch (EApp (EVar "grantOrder") (EFieldAccess (EVar "row") "msrScheme")) (arm (PList) () (EVar "None")) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EVar "Some") (ERecordCreate "MethodGrant" ((fa "mgArity" (EApp (EVar "tyArrowCount") (EFieldAccess (EVar "row") "msrType"))) (fa "mgNames" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "authvarName") (EVar "cell")))) (arm (PCon "None") () (ELit (LString "")))))) (EVar "ids")))))))))))))
(DTypeSig true "markSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "markSourceless" ((PVar "gctx") (PVar "ids")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsSourceless")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EVar "st") "gsSourceless") "value")) (EVar "ids"))))))
(DTypeSig false "grantChainAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GrantBinder")))))
(DFunDef false "grantChainAt" ((PVar "gctx") (PAs "sid" (PCon "ScopeId" (PVar "i")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid"))) (DoLet false false (PVar "outer") (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EVar "parent"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "own") (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "BindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EApp (EVar "TopGrantBinder") (EFieldAccess (EVar "frame") "sfModuleId")) (EVar "n")) (EVar "outer"))) (arm (PCon "LocalBindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EVar "LocalGrantBinder") (EVar "n")) (EVar "outer"))) (arm PWild () (EVar "outer")))) (DoExpr (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBodies") "value")) (arm (PCon "Some" (PVar "body")) () (EBinOp "::" (EVar "body") (EVar "own"))) (arm (PCon "None") () (EVar "own"))))))
(DTypeSig true "recordTopGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Unit"))))))
(DFunDef false "recordTopGrants" ((PVar "gctx") (PVar "mid") (PVar "schemes") (PVar "grouped")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "enabled") (EApp (EApp (EVar "grantsEnabled") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "granted") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "sch"))) (ETuple (EVar "n") (EIf (EVar "enabled") (EApp (EVar "grantOrder") (EVar "sch")) (EListLit))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "e")) (EApp (EApp (EVar "setGrantIds") (EFieldAccess (EVar "st") "gsTopIds")) (ETuple (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "granted"))) (DoLet false false (PVar "taking") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "isNonEmptyL") (EApp (EVar "snd") (EVar "e"))))) (EVar "granted"))) (DoExpr (EMatch (EVar "taking") (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsTakers")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "taking"))) (EFieldAccess (EFieldAccess (EVar "st") "gsTakers") "value")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "m") PWild)) (EApp (EApp (EVar "each") (ELam ((PVar "clause")) (EApp (EApp (EApp (EApp (EApp (EVar "recordRecursiveGrants") (EVar "gctx")) (EVar "mid")) (EVar "m")) (EVar "taking")) (EApp (EVar "snd") (EVar "clause"))))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "schemes")))))))))
(DTypeSig false "recordRecursiveGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Expr") (TyCon "Unit")))))))
(DFunDef false "recordRecursiveGrants" ((PVar "gctx") (PVar "mid") (PVar "m") (PVar "taking") (PVar "body")) (EBlock (DoLet false false (PVar "visit") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EDictAt" (PVar "n") (PVar "ev")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "taking")) (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (arm (PTuple (PCon "Some" (PVar "ids")) (PCon "None")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "n")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EListLit (EApp (EApp (EVar "TopGrantBinder") (EVar "mid")) (EVar "m")))) (fa "goStandalone" (EVar "False")))))) (DoExpr (EVar "e")))) (arm PWild () (EVar "e")))) (arm PWild () (EVar "e"))))) (DoLet false false PWild (EApp (EApp (EVar "mapExpr") (EVar "visit")) (EVar "body"))) (DoExpr (ELit LUnit))))
(DTypeSig true "registerLocalGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit")))))
(DFunDef false "registerLocalGrants" ((PVar "gctx") (PVar "name") (PVar "sch")) (EMatch (EApp (EVar "grantOrder") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLocalIds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "ids")) (EFieldAccess (EFieldAccess (EVar "st") "gsLocalIds") "value")))) (DoLet false false (PVar "recOccs") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "occ")) (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EApp (EVar "fst") (EVar "occ"))) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EApp (EVar "snd") (EVar "occ")))) (fa "goStandalone" (EVar "False"))))))) (EVar "recOccs")))))))
(DTypeSig true "appSpineArgCount" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "appSpineArgCount" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "appSpineArgCount") (EVar "f"))))
(DFunDef false "appSpineArgCount" (PWild) (ELit (LInt 0)))
(DTypeSig false "fileBoundKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "fileBoundKey" ((PCon "Loc" (PVar "file") (PVar "line") (PVar "col") (PVar "endLine") (PVar "endCol"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "endLine")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "endCol")))) (ELit (LString ""))))
(DTypeSig true "fileBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "fileBodyLoc" ((PVar "e")) (EMatch (EApp (EVar "firstSpan") (EVar "e")) (arm (PCon "Some" (PVar "l")) ((GBool (EApp (EVar "not") (EApp (EVar "isNoLoc") (EVar "l"))))) (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))
(DTypeSig false "firstSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstSpan" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstSpan" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "firstSpan") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig true "fileBoundSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String"))))
(DFunDef false "fileBoundSite" ((PVar "mid") (PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EApp (EVar "stringLength") (EVar "mid"))))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EVar "mid"))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "fileBoundKey") (EVar "loc")))) (ELit (LString ""))))
(DTypeSig false "scopeFileBoundModule" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "scopeFileBoundModule" ((PVar "mctx") PWild) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) "sfModuleId"))
(DTypeSig true "fileValueKey" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fileValueKey" ((PVar "mid") (PVar "e")) (EApp (EApp (EVar "map") (ELam ((PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EApp (EVar "fileBoundSite") (EVar "mid")) (EVar "loc")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "fileValueShape") (EVar "e")))) (ELit (LString ""))))) (EApp (EVar "fileBodyLoc") (EVar "e"))))
(DTypeSig false "fileValueShape" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "fileValueShape" ((PCon "ELoc" PWild PWild)) (ELit (LString "loc")))
(DFunDef false "fileValueShape" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "++" (ELit (LString "app")) (EApp (EVar "intToString") (EBinOp "+" (EApp (EVar "appSpineArgCount") (EVar "f")) (ELit (LInt 1))))))
(DFunDef false "fileValueShape" ((PCon "ELam" PWild PWild)) (ELit (LString "lambda")))
(DFunDef false "fileValueShape" (PWild) (ELit (LString "value")))
(DTypeSig true "finishFileValueScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "finishFileValueScope" ((PVar "mctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value") (arm (PCons (PVar "saved") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EVar "rest"))) (DoLet false false (PVar "flows") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "snd") (EVar "saved")))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "flow")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "not") (EApp (EVar "unsettledFileValueFlow") (EVar "flow")))) (EApp (EApp (EVar "checkFileValueFlow") (EVar "mctx")) (EVar "flow")) (ELit LUnit)))) (EVar "flows"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "wPushAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "reverseL") (EApp (EApp (EVar "filterList") (EVar "unsettledFileValueFlow")) (EVar "flows"))))))) (DoExpr (ELit LUnit)))) (arm (PList) () (ELit LUnit))))
(DTypeSig false "unsettledFileValueFlow" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "unsettledFileValueFlow" ((PTuple PWild (PVar "upper") (PVar "lower"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")))
(DTypeSig false "unsettledPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "unsettledPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TVar" PWild) PWild) () (EVar "True")) (arm (PTuple PWild (PCon "TVar" PWild)) () (EVar "True")) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "unsettledFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "unsettledFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "unsettledFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "ut")) (EApp (EVar "isNonEmptyL") (EVar "lt"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "a")) (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))) (EBinOp "++" (EVar "ua") (EVar "la")))))))
(DTypeSig false "checkFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Unit"))))
(DFunDef false "checkFileValueFlow" ((PVar "mctx") (PTuple (PVar "loc") (PVar "upper") (PVar "lower"))) (EIf (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TFileBoundValue")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (ELit (LString "a function's file bound cannot change inside a container: ")) (EApp (EVar "ppMonosShared") (EListLit (EVar "lower") (EVar "upper")))) (ELit (LString "; annotate the function with the container's FileRead or FileWrite bound before packing it")))) (ELit LUnit)))
(DTypeSig false "changesPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "changesPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "changesFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "changesFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "changesFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "u")) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "lt")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "l")) (EApp (EVar "atomKey") (EVar "u"))) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "l"))) (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EVar "atomAuth") (EVar "l")))))))) (EVar "la")))))) (EVar "ua"))))))
(DTypeSig true "hasFileBoundValue" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "hasFileBoundValue" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EApp (EVar "hasFileBoundValue") (EVar "result")))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "hasFileBoundValue") (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordValueFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordValueFileBound" ((PVar "mctx") (PVar "e") (PVar "ty")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EApp (EVar "fileValueKey") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsValueBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "ty") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit)))
(DTypeSig true "recordFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordFileBound" ((PVar "mctx") (PVar "body") (PVar "row")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "loc")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoLet false false (PVar "key") (EApp (EApp (EVar "fileBoundSite") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "loc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "row") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))))) (ELit LUnit)))))
(DTypeSig true "narrowFileAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "narrowFileAtom" ((PVar "atom")) (EMatch (EApp (EVar "atomLabelOf") (EVar "atom")) (arm (PCon "EffLabel" (PVar "label") (PCon "OriginBuiltin")) () (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "label") (ELit (LString "FileRead"))) (EBinOp "==" (EVar "label") (ELit (LString "FileWrite")))) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "atomAuth") (EVar "atom")))))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordClauseFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordClauseFileBound" ((PVar "mctx") (PVar "body") (PVar "arity") (PVar "ty")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "recordFileBound") (EVar "mctx")) (EVar "body")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EVar "arity")) (EVar "inner"))) (arm PWild () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "clausesAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesAt" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" ((PVar "n") (PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m"))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BindingRole" true) (mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false) (mem "AbsorptionEvent" true) (mem "GrantBinder" true) (mem "GrantCallee" true) (mem "GrantOcc" true) (mem "MethodGrant" true) (mem "GraphCtx" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "SelectedValueOccurrence" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "arrowArity" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "authRowCells" false) (mem "containsI" false) (mem "funArity" false) (mem "schemeAuthIds" false) (mem "tyArrowCount" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "wPushAll" false) (mem "wRestore" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupBinding" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false))))
(DUse false (UseGroup ("types" "expr_loc") ((mem "isNoLoc" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authHasVars" false) (mem "authIsTop" false) (mem "authSub" false) (mem "authvarName" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomLabelOf" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMonosShared" false) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Lit" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapExpr" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "fileGrantExterns" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DTypeSig true "evOrdinal" (TyFun (TyCon "EvId") (TyCon "Int")))
(DFunDef false "evOrdinal" ((PCon "EvId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "grantsEnabled" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "grantsEnabled" ((PVar "gctx") PWild) (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value")))
(DTypeSig false "grantCalleeOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "grantCalleeOf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EVar "SourceCallee") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmExterns")) (EApp (EVar "externCallee") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmUserNames")) (EVar "SourceCallee") (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))))) (arm (PCon "None") () (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "catalogCallee" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "catalogCallee" ((PVar "gctx") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (EApp (EVar "externCallee") (EVar "name")) (EVar "SourceCallee")))
(DTypeSig false "externCallee" (TyFun (TyCon "String") (TyCon "GrantCallee")))
(DFunDef false "externCallee" ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fileGrantExterns")) (EVar "FileExternCallee") (EVar "NoGrantCallee")))
(DTypeSig true "grantNameIn" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantNameIn" ((PVar "env") (PVar "n")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "grantsEnabled") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "ebMethodRow") (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EBinOp "&&" (EApp (EVar "calleeTakesGrants") (EApp (EApp (EVar "grantCalleeOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "schemeAuthIds") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme"))))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "calleeTakesGrants" (TyFun (TyCon "GrantCallee") (TyCon "Bool")))
(DFunDef false "calleeTakesGrants" ((PCon "SourceCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "FileExternCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "NoGrantCallee")) (EVar "False"))
(DTypeSig true "grantOrder" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PList) PWild PWild PWild)) (EListLit))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PVar "avars") PWild (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "reverseL") (EApp (EApp (EVar "authOrderRow") (EVar "force")) (EApp (EApp (EVar "authOrderIn") (EVar "body")) (EListLit))))) (DoLet false false (PVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "avars")))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "quantified"))))) (EVar "avars"))))))
(DTypeSig true "grantOccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Option") (TyCon "GrantOcc")))))
(DFunDef false "grantOccOf" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsOccs") "value")))
(DTypeSig false "setGrantOcc" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyFun (TyCon "GrantOcc") (TyCon "Unit")))))
(DFunDef false "setGrantOcc" ((PVar "gctx") (PVar "ev") (PVar "occ")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsOccs")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (EVar "occ")) (EFieldAccess (EFieldAccess (EVar "st") "gsOccs") "value"))))))
(DTypeSig true "grantOnlyBindingId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "grantOnlyBindingId" ((PVar "mctx") (PVar "name")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "mm") "mmTop")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "recordGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EMatch (EApp (EApp (EVar "grantCalleeOf") (EVar "mctx")) (EVar "name")) (arm (PCon "NoGrantCallee") () (ELit LUnit)) (arm (PCon "SourceCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EVar "None")) (EVar "False"))) (arm (PCon "FileExternCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))))
(DTypeSig true "recordMethodGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))
(DTypeSig true "recordStandaloneGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordStandaloneGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "arity")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EVar "arity"))) (EVar "True")))
(DTypeSig false "recordOccWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit")))))))))
(DFunDef false "recordOccWith" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "trailing") (PVar "standalone")) (EMatch (EApp (EVar "grantOrder") (EVar "scheme")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EApp (EApp (EApp (EVar "setGrantOcc") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "optionOr") (EApp (EVar "AJoin") (EListLit))) (EApp (EApp (EVar "lookupAssocI") (EVar "i")) (EVar "subst"))))) (EVar "ids"))) (fa "goRecIds" (EListLit)) (fa "goTrailing" (EVar "trailing")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (fa "goStandalone" (EVar "standalone"))))))))
(DTypeSig true "spineHeadEv" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "EvId"))))
(DFunDef false "spineHeadEv" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHeadEv") (EVar "e")))
(DFunDef false "spineHeadEv" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHeadEv") (EVar "f")))
(DFunDef false "spineHeadEv" ((PCon "EMethodAt" PWild PWild (PVar "ev"))) (EApp (EVar "Some") (EVar "ev")))
(DFunDef false "spineHeadEv" (PWild) (EVar "None"))
(DTypeSig true "recordStandaloneAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "SelectedValueOccurrence") (TyCon "Unit"))))))
(DFunDef false "recordStandaloneAt" ((PVar "mctx") (PVar "name") (PVar "hd") (PVar "occurrence")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EFieldAccess (EVar "occurrence") "svoScheme")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiSubstitution") "misAuthSubst")) (EApp (EVar "funArity") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "methodGrantOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))))
(DFunDef false "methodGrantOf" ((PVar "gctx") (PVar "ifaceWord") (PVar "method")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "methodGrantKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsMethods") "value")))
(DTypeSig true "recordMethodGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "recordMethodGrants" ((PVar "gctx") (PVar "rows")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsMethods")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName"))) (EFieldAccess (EVar "row") "msrName"))) (DoExpr (EMatch (EApp (EVar "methodGrantOfRow") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EVar "key")) (EVar "acc")))))))) (EFieldAccess (EFieldAccess (EVar "st") "gsMethods") "value")) (EVar "rows"))))))
(DTypeSig false "methodGrantOfRow" (TyFun (TyCon "MethodSchemeRow") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))
(DFunDef false "methodGrantOfRow" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "body")) () (EMatch (EApp (EVar "grantOrder") (EFieldAccess (EVar "row") "msrScheme")) (arm (PList) () (EVar "None")) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EVar "Some") (ERecordCreate "MethodGrant" ((fa "mgArity" (EApp (EVar "tyArrowCount") (EFieldAccess (EVar "row") "msrType"))) (fa "mgNames" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "authvarName") (EVar "cell")))) (arm (PCon "None") () (ELit (LString "")))))) (EVar "ids")))))))))))))
(DTypeSig true "markSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "markSourceless" ((PVar "gctx") (PVar "ids")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsSourceless")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EVar "st") "gsSourceless") "value")) (EVar "ids"))))))
(DTypeSig false "grantChainAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GrantBinder")))))
(DFunDef false "grantChainAt" ((PVar "gctx") (PAs "sid" (PCon "ScopeId" (PVar "i")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid"))) (DoLet false false (PVar "outer") (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EVar "parent"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "own") (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "BindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EApp (EVar "TopGrantBinder") (EFieldAccess (EVar "frame") "sfModuleId")) (EVar "n")) (EVar "outer"))) (arm (PCon "LocalBindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EVar "LocalGrantBinder") (EVar "n")) (EVar "outer"))) (arm PWild () (EVar "outer")))) (DoExpr (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBodies") "value")) (arm (PCon "Some" (PVar "body")) () (EBinOp "::" (EVar "body") (EVar "own"))) (arm (PCon "None") () (EVar "own"))))))
(DTypeSig true "recordTopGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Unit"))))))
(DFunDef false "recordTopGrants" ((PVar "gctx") (PVar "mid") (PVar "schemes") (PVar "grouped")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "enabled") (EApp (EApp (EVar "grantsEnabled") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "granted") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "sch"))) (ETuple (EVar "n") (EIf (EVar "enabled") (EApp (EVar "grantOrder") (EVar "sch")) (EListLit))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "e")) (EApp (EApp (EVar "setGrantIds") (EFieldAccess (EVar "st") "gsTopIds")) (ETuple (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "granted"))) (DoLet false false (PVar "taking") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "isNonEmptyL") (EApp (EVar "snd") (EVar "e"))))) (EVar "granted"))) (DoExpr (EMatch (EVar "taking") (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsTakers")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "taking"))) (EFieldAccess (EFieldAccess (EVar "st") "gsTakers") "value")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "m") PWild)) (EApp (EApp (EVar "each") (ELam ((PVar "clause")) (EApp (EApp (EApp (EApp (EApp (EVar "recordRecursiveGrants") (EVar "gctx")) (EVar "mid")) (EVar "m")) (EVar "taking")) (EApp (EVar "snd") (EVar "clause"))))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "schemes")))))))))
(DTypeSig false "recordRecursiveGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Expr") (TyCon "Unit")))))))
(DFunDef false "recordRecursiveGrants" ((PVar "gctx") (PVar "mid") (PVar "m") (PVar "taking") (PVar "body")) (EBlock (DoLet false false (PVar "visit") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EDictAt" (PVar "n") (PVar "ev")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "taking")) (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (arm (PTuple (PCon "Some" (PVar "ids")) (PCon "None")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "n")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EListLit (EApp (EApp (EVar "TopGrantBinder") (EVar "mid")) (EVar "m")))) (fa "goStandalone" (EVar "False")))))) (DoExpr (EVar "e")))) (arm PWild () (EVar "e")))) (arm PWild () (EVar "e"))))) (DoLet false false PWild (EApp (EApp (EVar "mapExpr") (EVar "visit")) (EVar "body"))) (DoExpr (ELit LUnit))))
(DTypeSig true "registerLocalGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit")))))
(DFunDef false "registerLocalGrants" ((PVar "gctx") (PVar "name") (PVar "sch")) (EMatch (EApp (EVar "grantOrder") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLocalIds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "ids")) (EFieldAccess (EFieldAccess (EVar "st") "gsLocalIds") "value")))) (DoLet false false (PVar "recOccs") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "occ")) (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EApp (EVar "fst") (EVar "occ"))) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EApp (EVar "snd") (EVar "occ")))) (fa "goStandalone" (EVar "False"))))))) (EVar "recOccs")))))))
(DTypeSig true "appSpineArgCount" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "appSpineArgCount" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "appSpineArgCount") (EVar "f"))))
(DFunDef false "appSpineArgCount" (PWild) (ELit (LInt 0)))
(DTypeSig false "fileBoundKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "fileBoundKey" ((PCon "Loc" (PVar "file") (PVar "line") (PVar "col") (PVar "endLine") (PVar "endCol"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "endLine")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "endCol")))) (ELit (LString ""))))
(DTypeSig true "fileBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "fileBodyLoc" ((PVar "e")) (EMatch (EApp (EVar "firstSpan") (EVar "e")) (arm (PCon "Some" (PVar "l")) ((GBool (EApp (EVar "not") (EApp (EVar "isNoLoc") (EVar "l"))))) (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))
(DTypeSig false "firstSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstSpan" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstSpan" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "firstSpan") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig true "fileBoundSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String"))))
(DFunDef false "fileBoundSite" ((PVar "mid") (PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EApp (EVar "stringLength") (EVar "mid"))))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EVar "mid"))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "fileBoundKey") (EVar "loc")))) (ELit (LString ""))))
(DTypeSig false "scopeFileBoundModule" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "scopeFileBoundModule" ((PVar "mctx") PWild) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) "sfModuleId"))
(DTypeSig true "fileValueKey" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fileValueKey" ((PVar "mid") (PVar "e")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EApp (EVar "fileBoundSite") (EVar "mid")) (EVar "loc")))) (ELit (LString ":"))) (EApp (EVar "$core.display") (EApp (EVar "fileValueShape") (EVar "e")))) (ELit (LString ""))))) (EApp (EVar "fileBodyLoc") (EVar "e"))))
(DTypeSig false "fileValueShape" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "fileValueShape" ((PCon "ELoc" PWild PWild)) (ELit (LString "loc")))
(DFunDef false "fileValueShape" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "++" (ELit (LString "app")) (EApp (EVar "intToString") (EBinOp "+" (EApp (EVar "appSpineArgCount") (EVar "f")) (ELit (LInt 1))))))
(DFunDef false "fileValueShape" ((PCon "ELam" PWild PWild)) (ELit (LString "lambda")))
(DFunDef false "fileValueShape" (PWild) (ELit (LString "value")))
(DTypeSig true "finishFileValueScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "finishFileValueScope" ((PVar "mctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value") (arm (PCons (PVar "saved") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EVar "rest"))) (DoLet false false (PVar "flows") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "snd") (EVar "saved")))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "flow")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "not") (EApp (EVar "unsettledFileValueFlow") (EVar "flow")))) (EApp (EApp (EVar "checkFileValueFlow") (EVar "mctx")) (EVar "flow")) (ELit LUnit)))) (EVar "flows"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "wPushAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "reverseL") (EApp (EApp (EVar "filterList") (EVar "unsettledFileValueFlow")) (EVar "flows"))))))) (DoExpr (ELit LUnit)))) (arm (PList) () (ELit LUnit))))
(DTypeSig false "unsettledFileValueFlow" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "unsettledFileValueFlow" ((PTuple PWild (PVar "upper") (PVar "lower"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")))
(DTypeSig false "unsettledPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "unsettledPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TVar" PWild) PWild) () (EVar "True")) (arm (PTuple PWild (PCon "TVar" PWild)) () (EVar "True")) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "unsettledFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "unsettledFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "unsettledFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "ut")) (EApp (EVar "isNonEmptyL") (EMethodRef "lt"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "a")) (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))) (EBinOp "++" (EVar "ua") (EVar "la")))))))
(DTypeSig false "checkFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Unit"))))
(DFunDef false "checkFileValueFlow" ((PVar "mctx") (PTuple (PVar "loc") (PVar "upper") (PVar "lower"))) (EIf (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (EVar "TFileBoundValue")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (ELit (LString "a function's file bound cannot change inside a container: ")) (EApp (EVar "ppMonosShared") (EListLit (EVar "lower") (EVar "upper")))) (ELit (LString "; annotate the function with the container's FileRead or FileWrite bound before packing it")))) (ELit LUnit)))
(DTypeSig false "changesPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "changesPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "changesFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "changesFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "changesFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "u")) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EMethodRef "lt")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "l")) (EApp (EVar "atomKey") (EVar "u"))) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "l"))) (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EVar "atomAuth") (EVar "l")))))))) (EVar "la")))))) (EVar "ua"))))))
(DTypeSig true "hasFileBoundValue" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "hasFileBoundValue" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EApp (EVar "hasFileBoundValue") (EVar "result")))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "hasFileBoundValue") (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordValueFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordValueFileBound" ((PVar "mctx") (PVar "e") (PVar "ty")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EApp (EVar "fileValueKey") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsValueBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "ty") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit)))
(DTypeSig true "recordFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordFileBound" ((PVar "mctx") (PVar "body") (PVar "row")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "loc")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoLet false false (PVar "key") (EApp (EApp (EVar "fileBoundSite") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "loc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "row") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))))) (ELit LUnit)))))
(DTypeSig true "narrowFileAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "narrowFileAtom" ((PVar "atom")) (EMatch (EApp (EVar "atomLabelOf") (EVar "atom")) (arm (PCon "EffLabel" (PVar "label") (PCon "OriginBuiltin")) () (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "label") (ELit (LString "FileRead"))) (EBinOp "==" (EVar "label") (ELit (LString "FileWrite")))) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "atomAuth") (EVar "atom")))))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordClauseFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordClauseFileBound" ((PVar "mctx") (PVar "body") (PVar "arity") (PVar "ty")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "recordFileBound") (EVar "mctx")) (EVar "body")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EVar "arity")) (EVar "inner"))) (arm PWild () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "clausesAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesAt" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" ((PVar "n") (PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m"))))
