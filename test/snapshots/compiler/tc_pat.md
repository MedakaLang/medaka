# META
source_lines=532
stages=DESUGAR,MARK
# SOURCE
-- tc_pat: pattern inference: literal, constructor, tuple, list, record and existential-opening
-- patterns, binder types.
--
-- Spec: HM-CORE section 3 (owed, #2555); language-design Data Types; EFFECTS section 4.1.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_infer_records`,
-- `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  DynCtx,
  ExistentialScope,
  GraphCtx,
  ModuleCtx,
  PendingBinder,
  RecordInfo,
  TcEnv,
}
import types.tc_mono.{
  authCellsIn,
  foldrFun,
  litType,
  monoScheme,
  recordAuthCells,
  substMono,
  tconBuiltin,
  tupleMono,
}
import types.tc_diag_text.{
  existentialEscapeMsg,
  existentialScopeMsg,
  unknownCtorMsg,
  unknownFieldMsg,
  unknownRecordMsg,
}
import types.tc_state.{dynAtIfSome}
import types.tc_env.{lookupCtor, lookupRecordByName}
import types.tc_diag.{pushTypeError, pushTypeErrorAt, recordTypeError}
import types.tc_unify.{
  bindFrom,
  enterLevel,
  exitLevel,
  freshAuthSubstOpening,
  freshAuthSubstOpeningIn,
  freshEffSubst,
  freshSubst,
  freshVar,
  raiseAuthvarLevel,
  unifyAll,
  unifyIn,
}
import types.tc_solve.{localSourceName}
import types.tc_effects.{markSourceless}
import types.effect_authority.{
  Authority(..), Authvar(..), authvarId, authvarLevel, authvarName
}
import frontend.ast.{
  BinderId(..),
  LetBind(..),
  Lit(..),
  Loc(..),
  Pat(..),
  RecPatField(..),
  isBoxed64Head,
  isI64Head,
  isTaggedFixedHead,
  orElseLoc,
}
import types.effect_bindings.{BindingSummary(..)}
import types.repr.{Mono(..), Scheme(..), normalize, ppMono}
import types.publish.{TcDiag(..)}
import support.util.{anyList, i64HalvesLiteral, lookupAssoc, u64HalvesHex}
import map as IdMap
import map.{Map(..)}

-- `loc` is the BINDER's own source span (#2092) — `None` only where the binding
-- site genuinely has none to give.  Discarding it is what made the hover tier
-- order unfixable: without a position there is no way to tell a local that is
-- in scope at the cursor from one bound in an unrelated declaration.
export
recordLocalBind : ModuleCtx -> String -> Option Loc -> BinderId -> Mono -> Unit
recordLocalBind mctx name loc bid v =
  recordBinderType mctx.mcGraph bid name v None False
  mctx.mcCells.localBindRefs :=
    (localSourceName name, loc, v) :: mctx.mcCells.localBindRefs.value

-- Queue binder [bid]'s type for the runtime-type table.  [arity] is `Some n` for
-- a function binder, whose return type is read after its n declared parameters;
-- [signed] is whether that function has a declared type signature.
-- A binder no minting pass visited (a node the typechecker or a later pass
-- synthesized) has no id to publish under and is skipped.
export
recordBinderType : GraphCtx ->
  BinderId ->
  String ->
  Mono ->
  Option Int ->
  Bool ->
  Unit
recordBinderType gctx bid name v arity signed = match bid
  BinderId _ i =>
    if i < 0 then
      ()
    else
      let g = gctx.graphRun
      g.binderPending :=
        PendingBinder bid (localSourceName name) v arity signed
          :: g.binderPending.value

-- A constructor in PATTERN position: its universals freshen as at any use,
-- but an existential binder (§4.1) is OPENED — a fresh RIGID authority the
-- arm may relate values by and never solve — and parked for the pattern
-- site (`takePatLits`/`settlePatLits`), which decides whether it may open one.
instantiateCtorPattern : ModuleCtx -> Scheme -> Mono
instantiateCtorPattern mctx (Forall ids evars avars _ _ t) =
  let (asub, opened) = freshAuthSubstOpening mctx avars t
  openExistentials mctx opened
  substMono mctx.mcGraph (freshSubst mctx ids) (freshEffSubst mctx evars) asub t

openExistentials : ModuleCtx -> List (Ref Authvar) -> Unit
openExistentials mctx [] = ()
openExistentials mctx cells =
  markSourceless mctx.mcGraph (map authvarId cells)
  mctx.mcCells.openedExistentialsRef :=
    cells ++ mctx.mcCells.openedExistentialsRef.value

-- ── pattern inference: returns the pattern's type + the bindings it adds ───
export
inferPat : TcEnv -> Pat -> (Mono, List (String, Scheme))
inferPat env (PVar x xloc bid) =
  let v = freshVar env.teDyn.dcModule ()
  recordLocalBind env.teDyn.dcModule x (Some xloc) bid v
  (v, [(x, monoScheme v)])
inferPat env PWild = (freshVar env.teDyn.dcModule (), [])
inferPat env (PLit (LInt n)) = inferIntLitPat env.teDyn.dcModule n
inferPat env (PLit (LU64 hi lo)) = inferU64LitPat env.teDyn.dcModule hi lo
inferPat env (PLit (LI64 hi lo)) =
  refuseBoxedLitPat
    env.teDyn.dcModule
    "I64"
    (i64HalvesLiteral hi lo)
    env.teDyn.dcModule.mcLoc
  (tconBuiltin "I64", [])
inferPat env (PLit l) = (litType l, [])
inferPat env (PCon name pats) = inferPatCon env name pats
inferPat env (PTuple pats) = inferPatTuple env pats
inferPat env (PCons h t) = inferPatCons env h t
inferPat env (PList pats) = inferPatList env pats
inferPat env (PAs x xloc bid p) = inferPatAs env x xloc bid p
inferPat env (PRec name fields _) = inferPatRec env name fields
inferPat env (PRng lo hi _) = inferPatRng env.teDyn.dcModule lo hi
inferPat env _ = panic "typecheck: unsupported pattern"

-- range pattern `lo..hi` / `lo..=hi`: only Int and Char bounds are valid
-- binds no variables
inferPatRng : ModuleCtx -> Lit -> Lit -> (Mono, List (String, Scheme))
inferPatRng mctx (LInt _) (LInt _) = (tconBuiltin "Int", [])
inferPatRng mctx (LChar _) (LChar _) = (tconBuiltin "Char", [])
inferPatRng mctx lo hi =
  pushTypeError
    mctx
    "T-TYPE-MISMATCH"
    "type mismatch: \{ppMono (litType lo)} vs \{ppMono (litType hi)}"
  (tconBuiltin "Int", [])

inferPatRec : TcEnv ->
  String ->
  List RecPatField ->
  (Mono, List (String, Scheme))
inferPatRec env name fields = match lookupRecordByName env.teDyn.dcModule name
  None =>
    pushTypeError env.teDyn.dcModule "T-UNKNOWN-RECORD" (unknownRecordMsg name)
    (freshVar env.teDyn.dcModule (), bindRecPatFieldsFresh env fields)
  Some ri => inferPatRecWith env name ri fields

-- bind a record pattern's fields against fresh types, NO unknown-field check
-- (the record itself is already-reported unknown; see inferPatRec error path)
bindRecPatFieldsFresh : TcEnv -> List RecPatField -> List (String, Scheme)
bindRecPatFieldsFresh env [] = []
bindRecPatFieldsFresh env ((RecPatField fname _ bid mp) :: rest) =
  inferRecPatFieldWith env (freshVar env.teDyn.dcModule ()) fname bid mp
    ++ bindRecPatFieldsFresh env rest

inferPatRecWith : TcEnv ->
  String ->
  RecordInfo ->
  List RecPatField ->
  (Mono, List (String, Scheme))
inferPatRecWith env rname ri fields =
  let (ir, opened) = instantiateRecordOpening env.teDyn.dcModule ri
  openExistentials env.teDyn.dcModule opened
  (fst ir, inferRecPatFields env rname (snd ir) fields)

inferRecPatFields : TcEnv ->
  String ->
  List (String, Mono) ->
  List RecPatField ->
  List (String, Scheme)
inferRecPatFields env _ _ [] = []
inferRecPatFields env rname fieldTypes ((RecPatField fname _ bid mp) :: rest) =
  inferRecPatField env rname fieldTypes fname bid mp
    ++ inferRecPatFields env rname fieldTypes rest

inferRecPatField : TcEnv ->
  String ->
  List (String, Mono) ->
  String ->
  BinderId ->
  Option Pat ->
  List (String, Scheme)
inferRecPatField env rname fieldTypes fname bid mp =
  match lookupAssoc fname fieldTypes
    None =>
      pushTypeError
        env.teDyn.dcModule
        "T-UNKNOWN-FIELD"
        (unknownFieldMsg fname rname)
      inferRecPatFieldWith env (freshVar env.teDyn.dcModule ()) fname bid mp
    Some ft => inferRecPatFieldWith env ft fname bid mp

-- A pun binds the field's own type.  It is published to the runtime-type table
-- but not to the LSP hover list, which has never carried puns.
inferRecPatFieldWith : TcEnv ->
  Mono ->
  String ->
  BinderId ->
  Option Pat ->
  List (String, Scheme)
inferRecPatFieldWith env ft fname bid None =
  recordBinderType env.teDyn.dcModule.mcGraph bid fname ft None False
  [(fname, monoScheme ft)]
inferRecPatFieldWith env ft _ _ (Some p) =
  let pr = inferPat env p
  bindFrom env.teDyn (fst pr) ft
  snd pr

-- INTEGER-TYPES-DESIGN §3.2 item 5: an integer literal PATTERN takes its type from
-- the scrutinee when that is a builtin integer head, and is `Int` otherwise.  It is
-- inferred as a fresh var and parked on `patLitPending`; the pattern site that
-- unifies the pattern with its scrutinee (or a signature's domain) then settles it
-- with `settlePatLits`, or defers it to `generalize` when the scrutinee's type is
-- not known yet.  Either way the var is settled before anything can quantify it,
-- so a literal pattern never makes a binding polymorphic.
inferIntLitPat : ModuleCtx -> Int -> (Mono, List (String, Scheme))
inferIntLitPat mctx n =
  let a = freshVar mctx ()
  mctx.mcCells.patLitPending :=
    (a, n, mctx.mcLoc) :: mctx.mcCells.patLitPending.value
  (a, [])

-- Open a pattern site: park the literals of any enclosing site and start
-- empty.  The existentials a pattern opens are parked the same way; a match
-- arm or a clause takes them (`takeOpenedExistentials`) before settling, every
-- other site finds them still parked at `settlePatLits` and refuses them,
-- since only an arm or a clause has a scope to close them in.
export
takePatLits : ModuleCtx -> Unit -> List (Mono, Int, Option Loc)
takePatLits mctx _ =
  parkOpenedExistentials mctx ()
  let saved = mctx.mcCells.patLitPending.value
  mctx.mcCells.patLitPending := []
  saved

-- Close a pattern site, after its pattern met its scrutinee.  A literal whose var
-- is now a fixed-width head keeps that type and joins the literal range check; one
-- whose var is any other type is `Int`, exactly as a literal pattern always was (a
-- non-integer scrutinee is the same `Int vs T` mismatch).  A var still unknown here
-- (a lambda's parameter, typed only by a later argument) is deferred: `generalize`
-- defaults it to `Int` before it could be quantified, and the module's end settles
-- whatever remains (`settleDeferredPatLits`).
export
settlePatLits : DynCtx -> List (Mono, Int, Option Loc) -> Unit
settlePatLits dyn saved =
  refuseOpenedExistentials dyn.dcModule ()
  settlePatLitsOnly dyn saved

parkOpenedExistentials : ModuleCtx -> Unit -> Unit
parkOpenedExistentials mctx _ =
  mctx.mcCells.openedExistentialsStackRef :=
    mctx.mcCells.openedExistentialsRef.value
      :: mctx.mcCells.openedExistentialsStackRef.value
  mctx.mcCells.openedExistentialsRef := []

-- The existentials the current pattern site opened, handed to the site that
-- may close them; the site's accumulator is left empty for `settlePatLits`.
export
takeOpenedExistentials : ModuleCtx -> Unit -> List (Ref Authvar)
takeOpenedExistentials mctx _ =
  let opened = mctx.mcCells.openedExistentialsRef.value
  mctx.mcCells.openedExistentialsRef := []
  opened

refuseOpenedExistentials : ModuleCtx -> Unit -> Unit
refuseOpenedExistentials mctx _ =
  let opened = mctx.mcCells.openedExistentialsRef.value
  match opened
    [] => ()
    cell :: _ =>
      pushTypeErrorAt
        mctx
        "T-AUTHORITY-EXISTENTIAL-SCOPE"
        mctx.mcLoc
        (existentialScopeMsg (authvarName cell))
  match mctx.mcCells.openedExistentialsStackRef.value
    outer :: rest =>
      mctx.mcCells.openedExistentialsRef := outer
      mctx.mcCells.openedExistentialsStackRef := rest
    [] => mctx.mcCells.openedExistentialsRef := []

settlePatLitsOnly : DynCtx -> List (Mono, Int, Option Loc) -> Unit
settlePatLitsOnly dyn saved =
  settlePatLitsGo dyn False dyn.dcModule.mcCells.patLitPending.value
  dyn.dcModule.mcCells.patLitPending := saved

-- [final]: the module is done, so an unknown var defaults instead of deferring.
export
settlePatLitsGo : DynCtx -> Bool -> List (Mono, Int, Option Loc) -> Unit
settlePatLitsGo dyn _ [] = ()
settlePatLitsGo dyn final ((a, n, loc) :: rest) =
  match normalize a
    TCon tag _ if isTaggedFixedHead tag =>
      dyn.dcModule.mcCells.numlitRanges :=
        (a, n, loc) :: dyn.dcModule.mcCells.numlitRanges.value
    TCon tag _ if isBoxed64Head tag =>
      refuseBoxedLitPat dyn.dcModule tag (intToString n) loc
    TVar _ if not final =>
      dyn.dcModule.mcCells.patLitDeferred :=
        (a, n, loc) :: dyn.dcModule.mcCells.patLitDeferred.value
    _ => unifyIn (dynAtIfSome loc dyn) (tconBuiltin "Int") a
  settlePatLitsGo dyn final rest

-- A `U64` or `I64` is a boxed cell, and no engine's pattern matcher compares one
-- against a constant, so a literal pattern cannot match it (INTEGER-TYPES-DESIGN
-- §3.2 item 5 builds the tagged heads only).  Refused, never compiled to an arm
-- that silently never matches: an ordinary literal whose scrutinee grounded to
-- `U64` or `I64` (`settlePatLitsGo`), and a wide one wherever it is written
-- (`exprToPat` keeps it as `LU64`).
refuseBoxedLitPat : ModuleCtx -> String -> String -> Option Loc -> Unit
refuseBoxedLitPat mctx tag lit loc =
  recordTypeError
    mctx
    (TcDiag
      "T-TYPE-MISMATCH"
      1
      (orElseLoc loc mctx.mcLoc)
      "the literal pattern `\{lit}` cannot match \{if isI64Head tag then "an" else "a"} `\{tag}`; compare in a guard instead"
      (Some "compare in a guard instead: `x if x == \{lit}`")
      None)

inferU64LitPat : ModuleCtx -> Int -> Int -> (Mono, List (String, Scheme))
inferU64LitPat mctx hi lo =
  refuseBoxedLitPat mctx "U64" ("0x" ++ u64HalvesHex hi lo) mctx.mcLoc
  (tconBuiltin "U64", [])

inferPatCon : TcEnv -> String -> List Pat -> (Mono, List (String, Scheme))
inferPatCon env name pats = match lookupCtor env name
  None =>
    pushTypeError env.teDyn.dcModule "T-UNKNOWN-CTOR" (unknownCtorMsg name)
    let pr = inferPats env pats
    (freshVar env.teDyn.dcModule (), snd pr)
  Some scheme => inferPatConWith env scheme pats

inferPatConWith : TcEnv -> Scheme -> List Pat -> (Mono, List (String, Scheme))
inferPatConWith env scheme pats =
  let ctorType = instantiateCtorPattern env.teDyn.dcModule scheme
  let pr = inferPats env pats
  let resultVar = freshVar env.teDyn.dcModule ()
  unifyIn env.teDyn ctorType (foldrFun (fst pr) resultVar)
  (resultVar, snd pr)

export
inferPats : TcEnv -> List Pat -> (List Mono, List (String, Scheme))
inferPats env [] = ([], [])
inferPats env (p :: ps) =
  let pr = inferPat env p
  let rest = inferPats env ps
  (fst pr :: fst rest, snd pr ++ snd rest)

inferPatTuple : TcEnv -> List Pat -> (Mono, List (String, Scheme))
inferPatTuple env pats =
  let pr = inferPats env pats
  (tupleMono (fst pr), snd pr)

inferPatCons : TcEnv -> Pat -> Pat -> (Mono, List (String, Scheme))
inferPatCons env h t =
  let hr = inferPat env h
  let tr = inferPat env t
  let listTy = TApp (tconBuiltin "List") (fst hr)
  unifyIn env.teDyn (fst tr) listTy
  (listTy, snd hr ++ snd tr)

inferPatList : TcEnv -> List Pat -> (Mono, List (String, Scheme))
inferPatList env pats =
  let elem = freshVar env.teDyn.dcModule ()
  let pr = inferPats env pats
  unifyAll env.teDyn elem (fst pr)
  (TApp (tconBuiltin "List") elem, snd pr)

inferPatAs : TcEnv ->
  String ->
  Loc ->
  BinderId ->
  Pat ->
  (Mono, List (String, Scheme))
inferPatAs env x xloc bid p =
  let pr = inferPat env p
  recordLocalBind env.teDyn.dcModule x (Some xloc) bid (fst pr)
  (fst pr, (x, monoScheme (fst pr)) :: snd pr)

export
patIsVar : Pat -> Bool
patIsVar (PVar _ _ _) = True
patIsVar _ = False

export
isConPat : Pat -> Bool
isConPat (PCon _ _) = True
isConPat _ = False

-- Does the pattern name a constructor with an existential binder?  Decided
-- before inference so the arm can enter its level first.
export
patOpensExistentials : TcEnv -> Pat -> Bool
patOpensExistentials env (PCon name pats) =
  ctorHasExistentials env.teDyn.dcModule.mcGraph (lookupCtor env name)
    || anyList (patOpensExistentials env) pats
patOpensExistentials env (PRec name fields _) =
  recordHasExistentials
      env.teDyn.dcModule.mcGraph
      (lookupRecordByName env.teDyn.dcModule name)
    || anyList (recPatFieldOpens env) fields
patOpensExistentials env (PTuple pats) = anyList (patOpensExistentials env) pats
patOpensExistentials env (PList pats) = anyList (patOpensExistentials env) pats
patOpensExistentials env (PCons h t) =
  patOpensExistentials env h || patOpensExistentials env t
patOpensExistentials env (PAs _ _ _ p) = patOpensExistentials env p
patOpensExistentials env _ = False

recPatFieldOpens : TcEnv -> RecPatField -> Bool
recPatFieldOpens env (RecPatField _ _ _ (Some p)) = patOpensExistentials env p
recPatFieldOpens env _ = False

ctorHasExistentials : GraphCtx -> Option Scheme -> Bool
ctorHasExistentials gctx (Some (Forall _ _ avars _ _ _)) =
  anyExistential gctx avars
ctorHasExistentials gctx None = False

recordHasExistentials : GraphCtx -> Option RecordInfo -> Bool
recordHasExistentials gctx (Some (RecordInfo _ authIds _ _ _)) =
  anyExistential gctx authIds
recordHasExistentials gctx None = False

anyExistential : GraphCtx -> List Int -> Bool
anyExistential gctx ids =
  anyList (id => IdMap.has id gctx.graphRun.ctorExistentialsRef.value) ids

export
openExistentialScope : ModuleCtx -> List (Ref Authvar) -> ExistentialScope
openExistentialScope mctx [] = ExistentialScope [] 0
openExistentialScope mctx opened =
  enterLevel mctx ()
  let level = mctx.mcCells.currentLevel.value
  fold (_ cell => raiseAuthvarLevel level cell) () opened
  ExistentialScope opened level

-- A cell in the scope's value, or lowered below the scope's level, escaped
-- (`T-AUTHORITY-ESCAPE`): the value cannot carry an authority nothing outside
-- the scope can name.  A row the scope performed at the authority is checked
-- against the enclosing declaration as any row is (rigid: only the label bare
-- admits it), and an inferred row publishes it as the domain's top
-- (`defaultSourcelessAuthorities`).
export
closeExistentialScope : ModuleCtx ->
  ExistentialScope ->
  Mono ->
  Option Loc ->
  Unit
closeExistentialScope mctx (ExistentialScope [] _) _ _ = ()
closeExistentialScope mctx (ExistentialScope opened level) t loc =
  exitLevel mctx ()
  let inValue = authCellsIn t Tip
  fold
    (_ cell =>
      if IdMap.has (authvarId cell) inValue || authvarLevel cell < level then
        mctx.mcCells.escapedExistentialsRef :=
          IdMap.set
            (authvarId cell)
            ()
            mctx.mcCells.escapedExistentialsRef.value
        pushTypeErrorAt
          mctx
          "T-AUTHORITY-ESCAPE"
          loc
          (existentialEscapeMsg (authvarName cell)))
    ()
    opened

-- A record's params and authorities freshened together; the constructor's
-- existentials are OPENED (rigid cells, parked at the pattern site) rather
-- than freshened flexible — the record-pattern twin of `instantiateCtorPattern`.
-- A record CREATE goes through `instantiateRecordShared`, which freshens every
-- authority flexible, since packing takes the value's own index.
instantiateRecordOpening : ModuleCtx ->
  RecordInfo ->
  ((Mono, List (String, Mono)), List (Ref Authvar))
instantiateRecordOpening mctx (RecordInfo paramIds authIds result fields _) =
  let subst = freshSubst mctx paramIds
  let (asub, opened) =
    freshAuthSubstOpeningIn mctx authIds (recordAuthCells authIds result fields)
  (
    (
      substMono mctx.mcGraph subst [] asub result,
      map (substField mctx.mcGraph subst asub) fields,
    ),
    opened,
  )

substField : GraphCtx ->
  List (Int, Mono) ->
  List (Int, Authority) ->
  (String, Mono) ->
  (String, Mono)
substField gctx subst asub (fn, fm) = (fn, substMono gctx subst [] asub fm)

-- A where/let group member's own type cell, the one its clauses are inferred
-- into, published with the member's declared parameter count.  A member is never
-- signed: a `LetBind` carries no type signature.
export
recordLetBindType : GraphCtx -> (LetBind, (String, BindingSummary)) -> Unit
recordLetBindType gctx (LetBind name _ _ bid, (_, summary)) =
  recordBinderType gctx bid name summary.bsValue (Some summary.bsArity) False
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "DynCtx" false) (mem "ExistentialScope" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PendingBinder" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "foldrFun" false) (mem "litType" false) (mem "monoScheme" false) (mem "recordAuthCells" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tupleMono" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "existentialEscapeMsg" false) (mem "existentialScopeMsg" false) (mem "unknownCtorMsg" false) (mem "unknownFieldMsg" false) (mem "unknownRecordMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupCtor" false) (mem "lookupRecordByName" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "bindFrom" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshAuthSubstOpening" false) (mem "freshAuthSubstOpeningIn" false) (mem "freshEffSubst" false) (mem "freshSubst" false) (mem "freshVar" false) (mem "raiseAuthvarLevel" false) (mem "unifyAll" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "localSourceName" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "markSourceless" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false) (mem "authvarLevel" false) (mem "authvarName" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "isBoxed64Head" false) (mem "isI64Head" false) (mem "isTaggedFixedHead" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "i64HalvesLiteral" false) (mem "lookupAssoc" false) (mem "u64HalvesHex" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DTypeSig true "recordLocalBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordLocalBind" ((PVar "mctx") (PVar "name") (PVar "loc") (PVar "bid") (PVar "v")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "bid")) (EVar "name")) (EVar "v")) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs")) (EBinOp "::" (ETuple (EApp (EVar "localSourceName") (EVar "name")) (EVar "loc") (EVar "v")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs") "value"))))))
(DTypeSig true "recordBinderType" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BinderId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "recordBinderType" ((PVar "gctx") (PVar "bid") (PVar "name") (PVar "v") (PVar "arity") (PVar "signed")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) () (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit LUnit) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "PendingBinder") (EVar "bid")) (EApp (EVar "localSourceName") (EVar "name"))) (EVar "v")) (EVar "arity")) (EVar "signed")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value")))))))))
(DTypeSig false "instantiateCtorPattern" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Mono"))))
(DFunDef false "instantiateCtorPattern" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") PWild PWild (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "asub") (PVar "opened")) (EApp (EApp (EApp (EVar "freshAuthSubstOpening") (EVar "mctx")) (EVar "avars")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "openExistentials") (EVar "mctx")) (EVar "opened"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (EVar "asub")) (EVar "t")))))
(DTypeSig false "openExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Unit"))))
(DFunDef false "openExistentials" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "openExistentials" ((PVar "mctx") (PVar "cells")) (EBlock (DoExpr (EApp (EApp (EVar "markSourceless") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "map") (EVar "authvarId")) (EVar "cells")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EBinOp "++" (EVar "cells") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value"))))))
(DTypeSig true "inferPat" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid"))) (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "v"))) (DoExpr (ETuple (EVar "v") (EListLit (ETuple (EVar "x") (EApp (EVar "monoScheme") (EVar "v"))))))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PWild")) (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EListLit)))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LInt" (PVar "n")))) (EApp (EApp (EVar "inferIntLitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LU64" (PVar "hi") (PVar "lo")))) (EApp (EApp (EApp (EVar "inferU64LitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hi")) (EVar "lo")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LI64" (PVar "hi") (PVar "lo")))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "I64"))) (EApp (EApp (EVar "i64HalvesLiteral") (EVar "hi")) (EVar "lo"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "I64"))) (EListLit)))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PVar "l"))) (ETuple (EApp (EVar "litType") (EVar "l")) (EListLit)))
(DFunDef false "inferPat" ((PVar "env") (PCon "PCon" (PVar "name") (PVar "pats"))) (EApp (EApp (EApp (EVar "inferPatCon") (EVar "env")) (EVar "name")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PTuple" (PVar "pats"))) (EApp (EApp (EVar "inferPatTuple") (EVar "env")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EApp (EVar "inferPatCons") (EVar "env")) (EVar "h")) (EVar "t")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PList" (PVar "pats"))) (EApp (EApp (EVar "inferPatList") (EVar "env")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PAs" (PVar "x") (PVar "xloc") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferPatAs") (EVar "env")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "p")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EVar "inferPatRec") (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PRng" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "inferPatRng") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lo")) (EVar "hi")))
(DFunDef false "inferPat" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported pattern"))))
(DTypeSig false "inferPatRng" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Lit") (TyFun (TyCon "Lit") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatRng" ((PVar "mctx") (PCon "LInt" PWild) (PCon "LInt" PWild)) (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EListLit)))
(DFunDef false "inferPatRng" ((PVar "mctx") (PCon "LChar" PWild) (PCon "LChar" PWild)) (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Char"))) (EListLit)))
(DFunDef false "inferPatRng" ((PVar "mctx") (PVar "lo") (PVar "hi")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EApp (EVar "litType") (EVar "lo"))))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EApp (EVar "litType") (EVar "hi"))))) (ELit (LString ""))))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EListLit)))))
(DTypeSig false "inferPatRec" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatRec" ((PVar "env") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-RECORD"))) (EApp (EVar "unknownRecordMsg") (EVar "name")))) (DoExpr (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EApp (EApp (EVar "bindRecPatFieldsFresh") (EVar "env")) (EVar "fields")))))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EVar "inferPatRecWith") (EVar "env")) (EVar "name")) (EVar "ri")) (EVar "fields")))))
(DTypeSig false "bindRecPatFieldsFresh" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "bindRecPatFieldsFresh" ((PVar "env") (PList)) (EListLit))
(DFunDef false "bindRecPatFieldsFresh" ((PVar "env") (PCons (PCon "RecPatField" (PVar "fname") PWild (PVar "bid") (PVar "mp")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "fname")) (EVar "bid")) (EVar "mp")) (EApp (EApp (EVar "bindRecPatFieldsFresh") (EVar "env")) (EVar "rest"))))
(DTypeSig false "inferPatRecWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "inferPatRecWith" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "fields")) (EBlock (DoLet false false (PTuple (PVar "ir") (PVar "opened")) (EApp (EApp (EVar "instantiateRecordOpening") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EVar "openExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "opened"))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "ir")) (EApp (EApp (EApp (EApp (EVar "inferRecPatFields") (EVar "env")) (EVar "rname")) (EApp (EVar "snd") (EVar "ir"))) (EVar "fields"))))))
(DTypeSig false "inferRecPatFields" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferRecPatFields" ((PVar "env") PWild PWild (PList)) (EListLit))
(DFunDef false "inferRecPatFields" ((PVar "env") (PVar "rname") (PVar "fieldTypes") (PCons (PCon "RecPatField" (PVar "fname") PWild (PVar "bid") (PVar "mp")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatField") (EVar "env")) (EVar "rname")) (EVar "fieldTypes")) (EVar "fname")) (EVar "bid")) (EVar "mp")) (EApp (EApp (EApp (EApp (EVar "inferRecPatFields") (EVar "env")) (EVar "rname")) (EVar "fieldTypes")) (EVar "rest"))))
(DTypeSig false "inferRecPatField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "inferRecPatField" ((PVar "env") (PVar "rname") (PVar "fieldTypes") (PVar "fname") (PVar "bid") (PVar "mp")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fname")) (EVar "fieldTypes")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "fname")) (EVar "bid")) (EVar "mp"))))) (arm (PCon "Some" (PVar "ft")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EVar "ft")) (EVar "fname")) (EVar "bid")) (EVar "mp")))))
(DTypeSig false "inferRecPatFieldWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "inferRecPatFieldWith" ((PVar "env") (PVar "ft") (PVar "fname") (PVar "bid") (PCon "None")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "bid")) (EVar "fname")) (EVar "ft")) (EVar "None")) (EVar "False"))) (DoExpr (EListLit (ETuple (EVar "fname") (EApp (EVar "monoScheme") (EVar "ft")))))))
(DFunDef false "inferRecPatFieldWith" ((PVar "env") (PVar "ft") PWild PWild (PCon "Some" (PVar "p"))) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "ft"))) (DoExpr (EApp (EVar "snd") (EVar "pr")))))
(DTypeSig false "inferIntLitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferIntLitPat" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending") "value")))) (DoExpr (ETuple (EVar "a") (EListLit)))))
(DTypeSig true "takePatLits" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "takePatLits" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "parkOpenedExistentials") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending")) (EListLit))) (DoExpr (EVar "saved"))))
(DTypeSig true "settlePatLits" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "settlePatLits" ((PVar "dyn") (PVar "saved")) (EBlock (DoExpr (EApp (EApp (EVar "refuseOpenedExistentials") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "settlePatLitsOnly") (EVar "dyn")) (EVar "saved")))))
(DTypeSig false "parkOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "parkOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef")) (EBinOp "::" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit)))))
(DTypeSig true "takeOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "takeOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "opened") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit))) (DoExpr (EVar "opened"))))
(DTypeSig false "refuseOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "refuseOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "opened") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value")) (DoExpr (EMatch (EVar "opened") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "cell") PWild) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EVar "existentialScopeMsg") (EApp (EVar "authvarName") (EVar "cell"))))))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef") "value") (arm (PCons (PVar "outer") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef")) (EVar "rest"))))) (arm (PList) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit)))))))
(DTypeSig false "settlePatLitsOnly" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "settlePatLitsOnly" ((PVar "dyn") (PVar "saved")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "settlePatLitsGo") (EVar "dyn")) (EVar "False")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitPending") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitPending")) (EVar "saved")))))
(DTypeSig true "settlePatLitsGo" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit")))))
(DFunDef false "settlePatLitsGo" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "settlePatLitsGo" ((PVar "dyn") (PVar "final") (PCons (PTuple (PVar "a") (PVar "n") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "numlitRanges") "value")))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isBoxed64Head") (EVar "tag")))) (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "tag")) (EApp (EVar "intToString") (EVar "n"))) (EVar "loc"))) (arm (PCon "TVar" PWild) ((GBool (EApp (EVar "not") (EVar "final")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred") "value")))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EVar "loc")) (EVar "dyn"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EVar "a"))))) (DoExpr (EApp (EApp (EApp (EVar "settlePatLitsGo") (EVar "dyn")) (EVar "final")) (EVar "rest")))))
(DTypeSig false "refuseBoxedLitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "refuseBoxedLitPat" ((PVar "mctx") (PVar "tag") (PVar "lit") (PVar "loc")) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-TYPE-MISMATCH"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the literal pattern `")) (EApp (EVar "display") (EVar "lit"))) (ELit (LString "` cannot match "))) (EApp (EVar "display") (EIf (EApp (EVar "isI64Head") (EVar "tag")) (ELit (LString "an")) (ELit (LString "a"))))) (ELit (LString " `"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "`; compare in a guard instead")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "compare in a guard instead: `x if x == ")) (EApp (EVar "display") (EVar "lit"))) (ELit (LString "`"))))) (EVar "None"))))
(DTypeSig false "inferU64LitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferU64LitPat" ((PVar "mctx") (PVar "hi") (PVar "lo")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EVar "mctx")) (ELit (LString "U64"))) (EBinOp "++" (ELit (LString "0x")) (EApp (EApp (EVar "u64HalvesHex") (EVar "hi")) (EVar "lo")))) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "U64"))) (EListLit)))))
(DTypeSig false "inferPatCon" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatCon" ((PVar "env") (PVar "name") (PVar "pats")) (EMatch (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-CTOR"))) (EApp (EVar "unknownCtorMsg") (EVar "name")))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EApp (EVar "snd") (EVar "pr")))))) (arm (PCon "Some" (PVar "scheme")) () (EApp (EApp (EApp (EVar "inferPatConWith") (EVar "env")) (EVar "scheme")) (EVar "pats")))))
(DTypeSig false "inferPatConWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatConWith" ((PVar "env") (PVar "scheme") (PVar "pats")) (EBlock (DoLet false false (PVar "ctorType") (EApp (EApp (EVar "instantiateCtorPattern") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scheme"))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoLet false false (PVar "resultVar") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "ctorType")) (EApp (EApp (EVar "foldrFun") (EApp (EVar "fst") (EVar "pr"))) (EVar "resultVar")))) (DoExpr (ETuple (EVar "resultVar") (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig true "inferPats" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPats" ((PVar "env") (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "inferPats" ((PVar "env") (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "ps"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "fst") (EVar "pr")) (EApp (EVar "fst") (EVar "rest"))) (EBinOp "++" (EApp (EVar "snd") (EVar "pr")) (EApp (EVar "snd") (EVar "rest")))))))
(DTypeSig false "inferPatTuple" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPatTuple" ((PVar "env") (PVar "pats")) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (ETuple (EApp (EVar "tupleMono") (EApp (EVar "fst") (EVar "pr"))) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferPatCons" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatCons" ((PVar "env") (PVar "h") (PVar "t")) (EBlock (DoLet false false (PVar "hr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "h"))) (DoLet false false (PVar "tr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "t"))) (DoLet false false (PVar "listTy") (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EApp (EVar "fst") (EVar "hr")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "tr"))) (EVar "listTy"))) (DoExpr (ETuple (EVar "listTy") (EBinOp "++" (EApp (EVar "snd") (EVar "hr")) (EApp (EVar "snd") (EVar "tr")))))))
(DTypeSig false "inferPatList" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPatList" ((PVar "env") (PVar "pats")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EVar "unifyAll") (EFieldAccess (EVar "env") "teDyn")) (EVar "elem")) (EApp (EVar "fst") (EVar "pr")))) (DoExpr (ETuple (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EVar "elem")) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferPatAs" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderId") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "inferPatAs" ((PVar "env") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "p")) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EApp (EVar "fst") (EVar "pr")))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "pr")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "monoScheme") (EApp (EVar "fst") (EVar "pr")))) (EApp (EVar "snd") (EVar "pr")))))))
(DTypeSig true "patIsVar" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsVar" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIsVar" (PWild) (EVar "False"))
(DTypeSig true "isConPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isConPat" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isConPat" (PWild) (EVar "False"))
(DTypeSig true "patOpensExistentials" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PCon" (PVar "name") (PVar "pats"))) (EBinOp "||" (EApp (EApp (EVar "ctorHasExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EBinOp "||" (EApp (EApp (EVar "recordHasExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EVar "anyList") (EApp (EVar "recPatFieldOpens") (EVar "env"))) (EVar "fields"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PTuple" (PVar "pats"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats")))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PList" (PVar "pats"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats")))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "h")) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "t"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "p")))
(DFunDef false "patOpensExistentials" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "recPatFieldOpens" (TyFun (TyCon "TcEnv") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldOpens" ((PVar "env") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "p")))
(DFunDef false "recPatFieldOpens" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "ctorHasExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyCon "Bool"))))
(DFunDef false "ctorHasExistentials" ((PVar "gctx") (PCon "Some" (PCon "Forall" PWild PWild (PVar "avars") PWild PWild PWild))) (EApp (EApp (EVar "anyExistential") (EVar "gctx")) (EVar "avars")))
(DFunDef false "ctorHasExistentials" ((PVar "gctx") (PCon "None")) (EVar "False"))
(DTypeSig false "recordHasExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "recordHasExistentials" ((PVar "gctx") (PCon "Some" (PCon "RecordInfo" PWild (PVar "authIds") PWild PWild PWild))) (EApp (EApp (EVar "anyExistential") (EVar "gctx")) (EVar "authIds")))
(DFunDef false "recordHasExistentials" ((PVar "gctx") (PCon "None")) (EVar "False"))
(DTypeSig false "anyExistential" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "anyExistential" ((PVar "gctx") (PVar "ids")) (EApp (EApp (EVar "anyList") (ELam ((PVar "id")) (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef") "value")))) (EVar "ids")))
(DTypeSig true "openExistentialScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "ExistentialScope"))))
(DFunDef false "openExistentialScope" ((PVar "mctx") (PList)) (EApp (EApp (EVar "ExistentialScope") (EListLit)) (ELit (LInt 0))))
(DFunDef false "openExistentialScope" ((PVar "mctx") (PVar "opened")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "level") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EApp (EApp (EVar "raiseAuthvarLevel") (EVar "level")) (EVar "cell")))) (ELit LUnit)) (EVar "opened"))) (DoExpr (EApp (EApp (EVar "ExistentialScope") (EVar "opened")) (EVar "level")))))
(DTypeSig true "closeExistentialScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ExistentialScope") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "closeExistentialScope" ((PVar "mctx") (PCon "ExistentialScope" (PList) PWild) PWild PWild) (ELit LUnit))
(DFunDef false "closeExistentialScope" ((PVar "mctx") (PCon "ExistentialScope" (PVar "opened") (PVar "level")) (PVar "t") (PVar "loc")) (EBlock (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "inValue") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "||" (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "inValue")) (EBinOp "<" (EApp (EVar "authvarLevel") (EVar "cell")) (EVar "level"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-ESCAPE"))) (EVar "loc")) (EApp (EVar "existentialEscapeMsg") (EApp (EVar "authvarName") (EVar "cell")))))) (ELit LUnit)))) (ELit LUnit)) (EVar "opened")))))
(DTypeSig false "instantiateRecordOpening" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "RecordInfo") (TyTuple (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "instantiateRecordOpening" ((PVar "mctx") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild)) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PTuple (PVar "asub") (PVar "opened")) (EApp (EApp (EApp (EVar "freshAuthSubstOpeningIn") (EVar "mctx")) (EVar "authIds")) (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields")))) (DoExpr (ETuple (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "substField") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EVar "asub"))) (EVar "fields"))) (EVar "opened")))))
(DTypeSig false "substField" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyTuple (TyCon "String") (TyCon "Mono")) (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "substField" ((PVar "gctx") (PVar "subst") (PVar "asub") (PTuple (PVar "fn") (PVar "fm"))) (ETuple (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "fm"))))
(DTypeSig true "recordLetBindType" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary"))) (TyCon "Unit"))))
(DFunDef false "recordLetBindType" ((PVar "gctx") (PTuple (PCon "LetBind" (PVar "name") PWild PWild (PVar "bid")) (PTuple PWild (PVar "summary")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EVar "gctx")) (EVar "bid")) (EVar "name")) (EFieldAccess (EVar "summary") "bsValue")) (EApp (EVar "Some") (EFieldAccess (EVar "summary") "bsArity"))) (EVar "False")))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "DynCtx" false) (mem "ExistentialScope" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PendingBinder" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "foldrFun" false) (mem "litType" false) (mem "monoScheme" false) (mem "recordAuthCells" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tupleMono" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "existentialEscapeMsg" false) (mem "existentialScopeMsg" false) (mem "unknownCtorMsg" false) (mem "unknownFieldMsg" false) (mem "unknownRecordMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupCtor" false) (mem "lookupRecordByName" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "bindFrom" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshAuthSubstOpening" false) (mem "freshAuthSubstOpeningIn" false) (mem "freshEffSubst" false) (mem "freshSubst" false) (mem "freshVar" false) (mem "raiseAuthvarLevel" false) (mem "unifyAll" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "localSourceName" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "markSourceless" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false) (mem "authvarLevel" false) (mem "authvarName" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "isBoxed64Head" false) (mem "isI64Head" false) (mem "isTaggedFixedHead" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "i64HalvesLiteral" false) (mem "lookupAssoc" false) (mem "u64HalvesHex" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DTypeSig true "recordLocalBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordLocalBind" ((PVar "mctx") (PVar "name") (PVar "loc") (PVar "bid") (PVar "v")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "bid")) (EVar "name")) (EVar "v")) (EVar "None")) (EVar "False"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs")) (EBinOp "::" (ETuple (EApp (EVar "localSourceName") (EVar "name")) (EVar "loc") (EVar "v")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs") "value"))))))
(DTypeSig true "recordBinderType" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BinderId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "recordBinderType" ((PVar "gctx") (PVar "bid") (PVar "name") (PVar "v") (PVar "arity") (PVar "signed")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) () (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit LUnit) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "PendingBinder") (EVar "bid")) (EApp (EVar "localSourceName") (EVar "name"))) (EVar "v")) (EVar "arity")) (EVar "signed")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value")))))))))
(DTypeSig false "instantiateCtorPattern" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Mono"))))
(DFunDef false "instantiateCtorPattern" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") PWild PWild (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "asub") (PVar "opened")) (EApp (EApp (EApp (EVar "freshAuthSubstOpening") (EVar "mctx")) (EVar "avars")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "openExistentials") (EVar "mctx")) (EVar "opened"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (EVar "asub")) (EVar "t")))))
(DTypeSig false "openExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Unit"))))
(DFunDef false "openExistentials" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "openExistentials" ((PVar "mctx") (PVar "cells")) (EBlock (DoExpr (EApp (EApp (EVar "markSourceless") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EMethodRef "map") (EVar "authvarId")) (EVar "cells")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EBinOp "++" (EVar "cells") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value"))))))
(DTypeSig true "inferPat" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid"))) (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "v"))) (DoExpr (ETuple (EVar "v") (EListLit (ETuple (EVar "x") (EApp (EVar "monoScheme") (EVar "v"))))))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PWild")) (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EListLit)))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LInt" (PVar "n")))) (EApp (EApp (EVar "inferIntLitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LU64" (PVar "hi") (PVar "lo")))) (EApp (EApp (EApp (EVar "inferU64LitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hi")) (EVar "lo")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PCon "LI64" (PVar "hi") (PVar "lo")))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "I64"))) (EApp (EApp (EVar "i64HalvesLiteral") (EVar "hi")) (EVar "lo"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "I64"))) (EListLit)))))
(DFunDef false "inferPat" ((PVar "env") (PCon "PLit" (PVar "l"))) (ETuple (EApp (EVar "litType") (EVar "l")) (EListLit)))
(DFunDef false "inferPat" ((PVar "env") (PCon "PCon" (PVar "name") (PVar "pats"))) (EApp (EApp (EApp (EVar "inferPatCon") (EVar "env")) (EVar "name")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PTuple" (PVar "pats"))) (EApp (EApp (EVar "inferPatTuple") (EVar "env")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EApp (EVar "inferPatCons") (EVar "env")) (EVar "h")) (EVar "t")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PList" (PVar "pats"))) (EApp (EApp (EVar "inferPatList") (EVar "env")) (EVar "pats")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PAs" (PVar "x") (PVar "xloc") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferPatAs") (EVar "env")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "p")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EVar "inferPatRec") (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "inferPat" ((PVar "env") (PCon "PRng" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "inferPatRng") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lo")) (EVar "hi")))
(DFunDef false "inferPat" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported pattern"))))
(DTypeSig false "inferPatRng" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Lit") (TyFun (TyCon "Lit") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatRng" ((PVar "mctx") (PCon "LInt" PWild) (PCon "LInt" PWild)) (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EListLit)))
(DFunDef false "inferPatRng" ((PVar "mctx") (PCon "LChar" PWild) (PCon "LChar" PWild)) (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Char"))) (EListLit)))
(DFunDef false "inferPatRng" ((PVar "mctx") (PVar "lo") (PVar "hi")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EApp (EVar "litType") (EVar "lo"))))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EApp (EVar "litType") (EVar "hi"))))) (ELit (LString ""))))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EListLit)))))
(DTypeSig false "inferPatRec" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatRec" ((PVar "env") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-RECORD"))) (EApp (EVar "unknownRecordMsg") (EVar "name")))) (DoExpr (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EApp (EApp (EVar "bindRecPatFieldsFresh") (EVar "env")) (EVar "fields")))))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EVar "inferPatRecWith") (EVar "env")) (EVar "name")) (EVar "ri")) (EVar "fields")))))
(DTypeSig false "bindRecPatFieldsFresh" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "bindRecPatFieldsFresh" ((PVar "env") (PList)) (EListLit))
(DFunDef false "bindRecPatFieldsFresh" ((PVar "env") (PCons (PCon "RecPatField" (PVar "fname") PWild (PVar "bid") (PVar "mp")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "fname")) (EVar "bid")) (EVar "mp")) (EApp (EApp (EVar "bindRecPatFieldsFresh") (EVar "env")) (EVar "rest"))))
(DTypeSig false "inferPatRecWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "inferPatRecWith" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "fields")) (EBlock (DoLet false false (PTuple (PVar "ir") (PVar "opened")) (EApp (EApp (EVar "instantiateRecordOpening") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EVar "openExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "opened"))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "ir")) (EApp (EApp (EApp (EApp (EVar "inferRecPatFields") (EVar "env")) (EVar "rname")) (EApp (EVar "snd") (EVar "ir"))) (EVar "fields"))))))
(DTypeSig false "inferRecPatFields" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferRecPatFields" ((PVar "env") PWild PWild (PList)) (EListLit))
(DFunDef false "inferRecPatFields" ((PVar "env") (PVar "rname") (PVar "fieldTypes") (PCons (PCon "RecPatField" (PVar "fname") PWild (PVar "bid") (PVar "mp")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatField") (EVar "env")) (EVar "rname")) (EVar "fieldTypes")) (EVar "fname")) (EVar "bid")) (EVar "mp")) (EApp (EApp (EApp (EApp (EVar "inferRecPatFields") (EVar "env")) (EVar "rname")) (EVar "fieldTypes")) (EVar "rest"))))
(DTypeSig false "inferRecPatField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "inferRecPatField" ((PVar "env") (PVar "rname") (PVar "fieldTypes") (PVar "fname") (PVar "bid") (PVar "mp")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fname")) (EVar "fieldTypes")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "fname")) (EVar "bid")) (EVar "mp"))))) (arm (PCon "Some" (PVar "ft")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecPatFieldWith") (EVar "env")) (EVar "ft")) (EVar "fname")) (EVar "bid")) (EVar "mp")))))
(DTypeSig false "inferRecPatFieldWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "inferRecPatFieldWith" ((PVar "env") (PVar "ft") (PVar "fname") (PVar "bid") (PCon "None")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "bid")) (EVar "fname")) (EVar "ft")) (EVar "None")) (EVar "False"))) (DoExpr (EListLit (ETuple (EVar "fname") (EApp (EVar "monoScheme") (EVar "ft")))))))
(DFunDef false "inferRecPatFieldWith" ((PVar "env") (PVar "ft") PWild PWild (PCon "Some" (PVar "p"))) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "ft"))) (DoExpr (EApp (EVar "snd") (EVar "pr")))))
(DTypeSig false "inferIntLitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferIntLitPat" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending") "value")))) (DoExpr (ETuple (EVar "a") (EListLit)))))
(DTypeSig true "takePatLits" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "takePatLits" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "parkOpenedExistentials") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "patLitPending")) (EListLit))) (DoExpr (EVar "saved"))))
(DTypeSig true "settlePatLits" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "settlePatLits" ((PVar "dyn") (PVar "saved")) (EBlock (DoExpr (EApp (EApp (EVar "refuseOpenedExistentials") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "settlePatLitsOnly") (EVar "dyn")) (EVar "saved")))))
(DTypeSig false "parkOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "parkOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef")) (EBinOp "::" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit)))))
(DTypeSig true "takeOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "takeOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "opened") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit))) (DoExpr (EVar "opened"))))
(DTypeSig false "refuseOpenedExistentials" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "refuseOpenedExistentials" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "opened") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef") "value")) (DoExpr (EMatch (EVar "opened") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "cell") PWild) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EVar "existentialScopeMsg") (EApp (EVar "authvarName") (EVar "cell"))))))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef") "value") (arm (PCons (PVar "outer") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsStackRef")) (EVar "rest"))))) (arm (PList) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedExistentialsRef")) (EListLit)))))))
(DTypeSig false "settlePatLitsOnly" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "settlePatLitsOnly" ((PVar "dyn") (PVar "saved")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "settlePatLitsGo") (EVar "dyn")) (EVar "False")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitPending") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitPending")) (EVar "saved")))))
(DTypeSig true "settlePatLitsGo" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit")))))
(DFunDef false "settlePatLitsGo" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "settlePatLitsGo" ((PVar "dyn") (PVar "final") (PCons (PTuple (PVar "a") (PVar "n") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "numlitRanges") "value")))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isBoxed64Head") (EVar "tag")))) (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "tag")) (EApp (EVar "intToString") (EVar "n"))) (EVar "loc"))) (arm (PCon "TVar" PWild) ((GBool (EApp (EVar "not") (EVar "final")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred") "value")))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EVar "loc")) (EVar "dyn"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EVar "a"))))) (DoExpr (EApp (EApp (EApp (EVar "settlePatLitsGo") (EVar "dyn")) (EVar "final")) (EVar "rest")))))
(DTypeSig false "refuseBoxedLitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "refuseBoxedLitPat" ((PVar "mctx") (PVar "tag") (PVar "lit") (PVar "loc")) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-TYPE-MISMATCH"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the literal pattern `")) (EApp (EMethodRef "display") (EVar "lit"))) (ELit (LString "` cannot match "))) (EApp (EMethodRef "display") (EIf (EApp (EVar "isI64Head") (EVar "tag")) (ELit (LString "an")) (ELit (LString "a"))))) (ELit (LString " `"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "`; compare in a guard instead")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "compare in a guard instead: `x if x == ")) (EApp (EMethodRef "display") (EVar "lit"))) (ELit (LString "`"))))) (EVar "None"))))
(DTypeSig false "inferU64LitPat" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferU64LitPat" ((PVar "mctx") (PVar "hi") (PVar "lo")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "refuseBoxedLitPat") (EVar "mctx")) (ELit (LString "U64"))) (EBinOp "++" (ELit (LString "0x")) (EApp (EApp (EVar "u64HalvesHex") (EVar "hi")) (EVar "lo")))) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (ETuple (EApp (EVar "tconBuiltin") (ELit (LString "U64"))) (EListLit)))))
(DTypeSig false "inferPatCon" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatCon" ((PVar "env") (PVar "name") (PVar "pats")) (EMatch (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-CTOR"))) (EApp (EVar "unknownCtorMsg") (EVar "name")))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (ETuple (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)) (EApp (EVar "snd") (EVar "pr")))))) (arm (PCon "Some" (PVar "scheme")) () (EApp (EApp (EApp (EVar "inferPatConWith") (EVar "env")) (EVar "scheme")) (EVar "pats")))))
(DTypeSig false "inferPatConWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatConWith" ((PVar "env") (PVar "scheme") (PVar "pats")) (EBlock (DoLet false false (PVar "ctorType") (EApp (EApp (EVar "instantiateCtorPattern") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scheme"))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoLet false false (PVar "resultVar") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "ctorType")) (EApp (EApp (EVar "foldrFun") (EApp (EVar "fst") (EVar "pr"))) (EVar "resultVar")))) (DoExpr (ETuple (EVar "resultVar") (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig true "inferPats" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPats" ((PVar "env") (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "inferPats" ((PVar "env") (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "ps"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "fst") (EVar "pr")) (EApp (EVar "fst") (EVar "rest"))) (EBinOp "++" (EApp (EVar "snd") (EVar "pr")) (EApp (EVar "snd") (EVar "rest")))))))
(DTypeSig false "inferPatTuple" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPatTuple" ((PVar "env") (PVar "pats")) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (ETuple (EApp (EVar "tupleMono") (EApp (EVar "fst") (EVar "pr"))) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferPatCons" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "inferPatCons" ((PVar "env") (PVar "h") (PVar "t")) (EBlock (DoLet false false (PVar "hr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "h"))) (DoLet false false (PVar "tr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "t"))) (DoLet false false (PVar "listTy") (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EApp (EVar "fst") (EVar "hr")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "tr"))) (EVar "listTy"))) (DoExpr (ETuple (EVar "listTy") (EBinOp "++" (EApp (EVar "snd") (EVar "hr")) (EApp (EVar "snd") (EVar "tr")))))))
(DTypeSig false "inferPatList" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "inferPatList" ((PVar "env") (PVar "pats")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EVar "unifyAll") (EFieldAccess (EVar "env") "teDyn")) (EDictApp "elem")) (EApp (EVar "fst") (EVar "pr")))) (DoExpr (ETuple (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EDictApp "elem")) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferPatAs" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderId") (TyFun (TyCon "Pat") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "inferPatAs" ((PVar "env") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "p")) (EBlock (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EApp (EVar "fst") (EVar "pr")))) (DoExpr (ETuple (EApp (EVar "fst") (EVar "pr")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "monoScheme") (EApp (EVar "fst") (EVar "pr")))) (EApp (EVar "snd") (EVar "pr")))))))
(DTypeSig true "patIsVar" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsVar" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIsVar" (PWild) (EVar "False"))
(DTypeSig true "isConPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isConPat" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isConPat" (PWild) (EVar "False"))
(DTypeSig true "patOpensExistentials" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PCon" (PVar "name") (PVar "pats"))) (EBinOp "||" (EApp (EApp (EVar "ctorHasExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EBinOp "||" (EApp (EApp (EVar "recordHasExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EVar "anyList") (EApp (EVar "recPatFieldOpens") (EVar "env"))) (EVar "fields"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PTuple" (PVar "pats"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats")))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PList" (PVar "pats"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patOpensExistentials") (EVar "env"))) (EVar "pats")))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "h")) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "t"))))
(DFunDef false "patOpensExistentials" ((PVar "env") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "p")))
(DFunDef false "patOpensExistentials" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "recPatFieldOpens" (TyFun (TyCon "TcEnv") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldOpens" ((PVar "env") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "p")))
(DFunDef false "recPatFieldOpens" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "ctorHasExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyCon "Bool"))))
(DFunDef false "ctorHasExistentials" ((PVar "gctx") (PCon "Some" (PCon "Forall" PWild PWild (PVar "avars") PWild PWild PWild))) (EApp (EApp (EVar "anyExistential") (EVar "gctx")) (EVar "avars")))
(DFunDef false "ctorHasExistentials" ((PVar "gctx") (PCon "None")) (EVar "False"))
(DTypeSig false "recordHasExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "recordHasExistentials" ((PVar "gctx") (PCon "Some" (PCon "RecordInfo" PWild (PVar "authIds") PWild PWild PWild))) (EApp (EApp (EVar "anyExistential") (EVar "gctx")) (EVar "authIds")))
(DFunDef false "recordHasExistentials" ((PVar "gctx") (PCon "None")) (EVar "False"))
(DTypeSig false "anyExistential" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "anyExistential" ((PVar "gctx") (PVar "ids")) (EApp (EApp (EVar "anyList") (ELam ((PVar "id")) (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef") "value")))) (EVar "ids")))
(DTypeSig true "openExistentialScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "ExistentialScope"))))
(DFunDef false "openExistentialScope" ((PVar "mctx") (PList)) (EApp (EApp (EVar "ExistentialScope") (EListLit)) (ELit (LInt 0))))
(DFunDef false "openExistentialScope" ((PVar "mctx") (PVar "opened")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "level") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EApp (EApp (EVar "raiseAuthvarLevel") (EVar "level")) (EVar "cell")))) (ELit LUnit)) (EVar "opened"))) (DoExpr (EApp (EApp (EVar "ExistentialScope") (EVar "opened")) (EVar "level")))))
(DTypeSig true "closeExistentialScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ExistentialScope") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "closeExistentialScope" ((PVar "mctx") (PCon "ExistentialScope" (PList) PWild) PWild PWild) (ELit LUnit))
(DFunDef false "closeExistentialScope" ((PVar "mctx") (PCon "ExistentialScope" (PVar "opened") (PVar "level")) (PVar "t") (PVar "loc")) (EBlock (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "inValue") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "||" (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "inValue")) (EBinOp "<" (EApp (EVar "authvarLevel") (EVar "cell")) (EVar "level"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-ESCAPE"))) (EVar "loc")) (EApp (EVar "existentialEscapeMsg") (EApp (EVar "authvarName") (EVar "cell")))))) (ELit LUnit)))) (ELit LUnit)) (EVar "opened")))))
(DTypeSig false "instantiateRecordOpening" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "RecordInfo") (TyTuple (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "instantiateRecordOpening" ((PVar "mctx") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild)) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PTuple (PVar "asub") (PVar "opened")) (EApp (EApp (EApp (EVar "freshAuthSubstOpeningIn") (EVar "mctx")) (EVar "authIds")) (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields")))) (DoExpr (ETuple (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "substField") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EVar "asub"))) (EVar "fields"))) (EVar "opened")))))
(DTypeSig false "substField" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyTuple (TyCon "String") (TyCon "Mono")) (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "substField" ((PVar "gctx") (PVar "subst") (PVar "asub") (PTuple (PVar "fn") (PVar "fm"))) (ETuple (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "fm"))))
(DTypeSig true "recordLetBindType" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary"))) (TyCon "Unit"))))
(DFunDef false "recordLetBindType" ((PVar "gctx") (PTuple (PCon "LetBind" (PVar "name") PWild PWild (PVar "bid")) (PTuple PWild (PVar "summary")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EVar "gctx")) (EVar "bid")) (EVar "name")) (EFieldAccess (EVar "summary") "bsValue")) (EApp (EVar "Some") (EFieldAccess (EVar "summary") "bsArity"))) (EVar "False")))
