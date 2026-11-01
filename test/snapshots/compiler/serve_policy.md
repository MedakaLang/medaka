# META
source_lines=376
stages=DESUGAR,MARK
# SOURCE
-- Which modules of a keyed drive are served, checked, recorded, and the per-drive
-- state that decides it.
--
-- The policy reaches the drive's drain and its open-variable test through
-- `ServeOps`, which `typecheck.mdk` builds once; this module imports nothing from it.
import list.{drop, take, sort}
import string.{lines}
import frontend.visibility.{isSubjectIn, useModuleIds}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omHasKey}
import support.util.{
  anyList, dedup, filterList, isNonEmptyL, isSome, joinNl, listLen, zipL
}
import types.chain_key.{chainGraphKey, interfaceRows}
import types.invocation_basis.{readInvocationView}
import types.module_interface.{
  ModuleKey(..),
  ModuleInterface,
  ModuleRows,
  applyModuleInterface,
  applyModuleTrees,
  captureModuleRows,
  freezeModuleInterface,
  freezeModuleTrees,
  freshModuleSerial,
  moduleCacheHit,
  moduleInterfaceIdentity,
  privateBindingsOf,
  recordModuleInterface,
}
import types.publish.{ModDiags, PubScheme, TcDiag, freezeRows}
import types.repr.{Mono}
import types.tc_types.{
  ExportBinding, GraphCtx(..), GraphRun(..), InvocationView, LiveGoal(..),
  ModuleCtx(..), ModuleServe(..), ServeStep(..)
}
import frontend.ast.{Decl}

-- What the policy needs from the typechecker: the drain of the queues a module's
-- check left (its findings attached to the rows so far), and the unbound variables
-- of a type.
public export data ServeOps = ServeOps {
  soDrain : ModuleCtx -> List ModDiags -> List ModDiags,
  soUnboundIds : Mono -> List Int,
}

-- A diagnostics drive's per-module payload (`graphModuleWorker`).
export type DiagsPayload = (List Decl, List (String, PubScheme), List TcDiag, List TcDiag, Option InvocationView)

-- The serve policy's state: whether the drive serves trees, the source keys of the
-- modules still to come, the graph key, the interface rows of the modules so far,
-- the identity of each module so far, the modules checked and not recorded, and the
-- counts `ModuleServe` reports.
export data ServeState = ServeState {
  ssOps : ServeOps,
  ssTrees : Bool,
  ssCapture : OrdMap Unit,
  ssKeys : List (Option String),
  ssGraph : String,
  ssIfaces : List String,
  ssIdents : OrdMap String,
  ssUnrecorded : OrdMap Unit,
  ssRows : Int,
  ssFrozen : Int,
  ssServed : Int,
}

-- The policy's start for a drive over [modules] whose chain key and source keys are
-- [keyed]: the graph key is the drive's configuration, the chain key's prelude
-- generation (not its entry or roots), and every module's instance heads and
-- constrained signature names, which a module reads whether or not it imports
-- their definer (`chainGraphKey`).  A module's key adds the interface declarations
-- of the modules before it (`graphPart`).
export
serveStateOf : ServeOps ->
  OrdMap Unit ->
  GraphCtx ->
  List (String, List Decl) ->
  (String, List (Option String)) ->
  ServeState
serveStateOf ops capture gctx modules (chain, steps) = ServeState {
  ssOps = ops,
  ssTrees = False,
  ssCapture = capture,
  ssKeys = steps,
  ssGraph =
    if anyList isSome steps then
      "\{gctx.config.value.tcKey}\n\{generationLine chain}\n\{chainGraphKey modules}"
    else
      "",
  ssIfaces = [],
  ssIdents = omEmpty,
  ssUnrecorded = omEmpty,
  ssRows = 0,
  ssFrozen = 0,
  ssServed = 0,
}

-- The chain key's first line, the prelude generation.  The entry is read only once the
-- whole graph is checked, and the roots only choose the file an import resolves to,
-- which a module's source key and its imports' identities already carry.
generationLine : String -> String
generationLine chain = match lines chain
  first :: _ => first
  [] => ""

-- A keyed diagnostics drive's serve policy.  A module before the entry whose
-- `ModuleKey` matches its interface's is served from it.  A miss is checked, and it
-- is left unrecorded when its own check leaves a live root open, which a later
-- module is to ground, or when a module it imports is unrecorded: either could not
-- be replayed without a module outside its interface.  Every other miss records,
-- including one after an unrecorded module, which does not import it.  A recording
-- module is drained at its own end before its row is frozen and its interface taken,
-- so an interface brings no queued goal; the drain is scoped to what the module's
-- own check queued (`recordScoped`).  The key carries each direct import's identity,
-- and an import checked and not recorded has a fresh serial no interface carries, so
-- a change anywhere in a module's import closure re-checks it.
export
diagsServe : ServeState -> ModuleServe DiagsPayload
diagsServe st = ModuleServe {
  msServed = st.ssServed,
  msFrozen = st.ssFrozen,
  msStep = serveStep st,
}

-- A keyed tree drive's serve policy: `diagsServe`'s, over interfaces that carry the
-- module's trees (`ModuleTrees`).  The key's graph part also names the drive's
-- selection and the promotion harvest of the modules before this one, which its
-- marking reads.  A served module contributes its own promotions to the harvest.
export
treeServe : ServeState -> ModuleServe DiagsPayload
treeServe st = diagsServe { st | ssTrees = True }

serveStep : ServeState ->
  String ->
  List Decl ->
  ModuleCtx ->
  ServeStep DiagsPayload
serveStep st mid prog prev =
  let next = { st |
    ssKeys = drop 1 st.ssKeys,
    ssIfaces = st.ssIfaces ++ interfaceRows mid prog,
    ssRows = st.ssRows + 1,
  }
  let unrecorded done = (done, diagsServe (unrecordedState next mid))
  match st.ssKeys
    (Some source) :: _ =>
      let key = ModuleKey {
        mkModule = mid,
        mkSource = source,
        mkImports =
          map
            (m => (m, optionOr "" (omLookup m st.ssIdents)))
            (dedup (useModuleIds prog)),
        mkGraph = graphPart st prev,
      }
      match servable st (moduleCacheHit key)
        Some mi =>
          let ((_, (schemes, errs, warns)), own) =
            applyModuleInterface prev.mcGraph mi
          ServeHit
            own
            (if isSubject prev mid then privateBindingsOf mi else [])
            (
              servedTrees st prev mi,
              schemes,
              errs,
              warns,
              if omHasKey mid st.ssCapture then
                Some (readInvocationView mi.miInvocationView)
              else
                None,
            )
            (diagsServe (servedState next mid mi))
        None =>
          let before = captureModuleRows prev.mcGraph
          let mark = queueMarkOf prev.mcGraph
          ServeCheck (mctx own private done =>
            if anyList (m => omHasKey m st.ssUnrecorded) (map fst key.mkImports)
              || ownRootsOpen st.ssOps mctx.mcGraph mark then
              unrecorded done
            else
              recordScoped next key before mctx own private done mark)
    _ => ServeCheck (_ _ _ done => unrecorded done)

-- Whether [mid] is a test subject of the graph [prev] belongs to: a module its
-- sibling sees in the full view, so one whose private bindings the drive keeps.
export
isSubject : ModuleCtx -> String -> Bool
isSubject prev mid = isSubjectIn prev.mcGraph.config.value.tcSibling mid

-- The key's graph part for the module [prev] precedes: the graph key and the
-- interface declarations of the modules before it, whose method names it reads by
-- bare name whether or not it imports their declarer.
graphPart : ServeState -> ModuleCtx -> String
graphPart st prev =
  let graph = joinNl (st.ssGraph :: st.ssIfaces)
  if st.ssTrees then
    joinNl ("\{graph}\ntrees" :: sort prev.mcGraph.promotionHarvestRef.value)
  else
    graph

-- A tree drive serves only an interface that carries trees.
servable : ServeState -> Option ModuleInterface -> Option ModuleInterface
servable st (Some mi)
  | st.ssTrees && isNone mi.miTrees = None
servable _ hit = hit

servedTrees : ServeState -> ModuleCtx -> ModuleInterface -> List Decl
servedTrees st prev mi = match mi.miTrees
  Some trees if st.ssTrees => applyModuleTrees prev.mcGraph trees
  _ => []

-- A served row extends the frozen prefix when every row before it is frozen.
servedState : ServeState -> String -> ModuleInterface -> ServeState
servedState st mid mi = { rowFrozen st mid mi | ssServed = st.ssServed + 1 }

-- [st] with [mid]'s interface identity recorded and its row frozen when every row
-- before it is.
rowFrozen : ServeState -> String -> ModuleInterface -> ServeState
rowFrozen st mid mi = { st |
  ssIdents = omInsert mid (moduleInterfaceIdentity mi) st.ssIdents,
  ssFrozen = if st.ssFrozen + 1 == st.ssRows then st.ssRows else st.ssFrozen,
}

unrecordedState : ServeState -> String -> ServeState
unrecordedState st mid = { st |
  ssIdents = omInsert mid (intToString (freshModuleSerial ())) st.ssIdents,
  ssUnrecorded = omInsert mid () st.ssUnrecorded,
}

-- How much each queue the drain reads held before a module's check, and the next
-- evidence ordinal: what that check queued is the head of each queue (newest first)
-- beyond these lengths.
data QueueMark = QueueMark {
  qmCtxs : Int,
  qmRoots : Int,
  qmNumRoots : Int,
  qmNumGoals : Int,
  qmBinders : Int,
  qmEvidence : Int,
}

queueMarkOf : GraphCtx -> QueueMark
queueMarkOf gctx =
  let g = gctx.graphRun
  QueueMark {
    qmCtxs = listLen g.stampCtxs.value,
    qmRoots = listLen g.liveRoots.value,
    qmNumRoots = listLen g.liveNumRoots.value,
    qmNumGoals = listLen g.liveNumGoals.value,
    qmBinders = listLen g.binderPending.value,
    qmEvidence = g.evCounter.value,
  }

-- Some live root the module's own check queued still has a variable a later module
-- could ground.
ownRootsOpen : ServeOps -> GraphCtx -> QueueMark -> Bool
ownRootsOpen ops gctx mark =
  let roots = gctx.graphRun.liveRoots.value
  anyList
    (m => isNonEmptyL (ops.soUnboundIds m))
    (take (listLen roots - mark.qmRoots) roots)

-- The queue's entries from before [n] entries were held, and the [n] newest.
queueOlder : Int -> List a -> List a
queueOlder n xs = drop (listLen xs - n) xs

queueNewer : Int -> List a -> List a
queueNewer n xs = take (listLen xs - n) xs

-- `recordChecked` with the drain scoped to the module's own queue: the entries queued
-- before its check are set aside for the drive's later drains and restored after, and
-- the evidence it minted is judged now and skipped by the later drain, so those
-- drains see what they would have seen had the module not recorded.
recordScoped : ServeState ->
  ModuleKey ->
  ModuleRows ->
  ModuleCtx ->
  List (String, ExportBinding) ->
  List (String, ExportBinding) ->
  List (String, DiagsPayload) ->
  QueueMark ->
  (List (String, DiagsPayload), ModuleServe DiagsPayload)
recordScoped st key before mctx own private done mark =
  let g = mctx.mcGraph.graphRun
  let mid = key.mkModule
  let ctxs = queueOlder mark.qmCtxs g.stampCtxs.value
  let roots = queueOlder mark.qmRoots g.liveRoots.value
  let numRoots = queueOlder mark.qmNumRoots g.liveNumRoots.value
  let numGoals = queueOlder mark.qmNumGoals g.liveNumGoals.value
  let binders = queueOlder mark.qmBinders g.binderPending.value
  let goals = filterList (lg => lg.lgModule /= mid) g.liveGoals.value
  let judged = g.evJudged.value
  let from = max judged mark.qmEvidence
  g.stampCtxs := queueNewer mark.qmCtxs g.stampCtxs.value
  g.liveRoots := queueNewer mark.qmRoots g.liveRoots.value
  g.liveNumRoots := queueNewer mark.qmNumRoots g.liveNumRoots.value
  g.liveNumGoals := queueNewer mark.qmNumGoals g.liveNumGoals.value
  g.binderPending := queueNewer mark.qmBinders g.binderPending.value
  g.liveGoals := filterList (lg => lg.lgModule == mid) g.liveGoals.value
  g.evJudged := from
  let result = recordChecked st key before mctx own private done
  g.evScopedJudged := (from, g.evCounter.value) :: g.evScopedJudged.value
  g.evJudged := judged
  g.stampCtxs := g.stampCtxs.value ++ ctxs
  g.liveRoots := g.liveRoots.value ++ roots
  g.liveNumRoots := g.liveNumRoots.value ++ numRoots
  g.liveNumGoals := g.liveNumGoals.value ++ numGoals
  g.binderPending := g.binderPending.value ++ binders
  g.liveGoals := g.liveGoals.value ++ goals
  result

-- A checked module's record: drain what it queued, attach the drain's findings to
-- the rows so far (whose errors decide which live findings stay), freeze its row and
-- record its interface.  [done] is the payloads so far, this module's first.
recordChecked : ServeState ->
  ModuleKey ->
  ModuleRows ->
  ModuleCtx ->
  List (String, ExportBinding) ->
  List (String, ExportBinding) ->
  List (String, DiagsPayload) ->
  (List (String, DiagsPayload), ModuleServe DiagsPayload)
recordChecked st key before mctx own private done =
  let drained = withModDiags (st.ssOps.soDrain mctx) done
  match drained
    [] => (drained, diagsServe st)
    (mid, (marked, schemes, errs, warns, _)) :: older =>
      let published = freezeRows schemes
      let trees =
        if st.ssTrees then
          Some (freezeModuleTrees mid marked published before mctx)
        else
          None
      let mi =
        freezeModuleInterface
          key
          (freshModuleSerial ())
          (mid, (published, errs, warns))
          own
          private
          before
          mctx
          trees
      recordModuleInterface mi
      (
        (
            mid,
            (
              marked,
              published,
              errs,
              warns,
              if omHasKey mid st.ssCapture then
                Some (readInvocationView mi.miInvocationView)
              else
                None,
            ),
          )
          :: older,
        diagsServe (rowFrozen st mid mi),
      )

-- [f] over the diagnostics rows of [done], each payload keeping its marked tree.
-- [f] keeps every row in place.
withModDiags : (List ModDiags -> List ModDiags) ->
  List (String, DiagsPayload) ->
  List (String, DiagsPayload)
withModDiags f done = map withMarked (zipL done (f (map payloadRow done)))

payloadRow : (String, DiagsPayload) -> ModDiags
payloadRow (mid, (_, schemes, errs, warns, _)) = (mid, (schemes, errs, warns))

withMarked : ((String, DiagsPayload), ModDiags) -> (String, DiagsPayload)
withMarked ((mid, (marked, _, _, _, view)), (_, (schemes, errs, warns))) =
  (mid, (marked, schemes, errs, warns, view))
# DESUGAR
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "lines" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "isSubjectIn" false) (mem "useModuleIds" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedup" false) (mem "filterList" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinNl" false) (mem "listLen" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "chainGraphKey" false) (mem "interfaceRows" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "readInvocationView" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "ModuleKey" true) (mem "ModuleInterface" false) (mem "ModuleRows" false) (mem "applyModuleInterface" false) (mem "applyModuleTrees" false) (mem "captureModuleRows" false) (mem "freezeModuleInterface" false) (mem "freezeModuleTrees" false) (mem "freshModuleSerial" false) (mem "moduleCacheHit" false) (mem "moduleInterfaceIdentity" false) (mem "privateBindingsOf" false) (mem "recordModuleInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" false) (mem "TcDiag" false) (mem "freezeRows" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ExportBinding" false) (mem "GraphCtx" true) (mem "GraphRun" true) (mem "InvocationView" false) (mem "LiveGoal" true) (mem "ModuleCtx" true) (mem "ModuleServe" true) (mem "ServeStep" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DData Public "ServeOps" () ((variant "ServeOps" (ConNamed (field "soDrain" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags"))))) (field "soUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))))) ())
(DTypeAlias true "DiagsPayload" () (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))))
(DData Abstract "ServeState" () ((variant "ServeState" (ConNamed (field "ssOps" (TyCon "ServeOps")) (field "ssTrees" (TyCon "Bool")) (field "ssCapture" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ssKeys" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))) (field "ssGraph" (TyCon "String")) (field "ssIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ssIdents" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "ssUnrecorded" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ssRows" (TyCon "Int")) (field "ssFrozen" (TyCon "Int")) (field "ssServed" (TyCon "Int"))))) ())
(DTypeSig true "serveStateOf" (TyFun (TyCon "ServeOps") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "ServeState")))))))
(DFunDef false "serveStateOf" ((PVar "ops") (PVar "capture") (PVar "gctx") (PVar "modules") (PTuple (PVar "chain") (PVar "steps"))) (ERecordCreate "ServeState" ((fa "ssOps" (EVar "ops")) (fa "ssTrees" (EVar "False")) (fa "ssCapture" (EVar "capture")) (fa "ssKeys" (EVar "steps")) (fa "ssGraph" (EIf (EApp (EApp (EVar "anyList") (EVar "isSome")) (EVar "steps")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcKey"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "generationLine") (EVar "chain")))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "chainGraphKey") (EVar "modules")))) (ELit (LString ""))) (ELit (LString "")))) (fa "ssIfaces" (EListLit)) (fa "ssIdents" (EVar "omEmpty")) (fa "ssUnrecorded" (EVar "omEmpty")) (fa "ssRows" (ELit (LInt 0))) (fa "ssFrozen" (ELit (LInt 0))) (fa "ssServed" (ELit (LInt 0))))))
(DTypeSig false "generationLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "generationLine" ((PVar "chain")) (EMatch (EApp (EVar "lines") (EVar "chain")) (arm (PCons (PVar "first") PWild) () (EVar "first")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "diagsServe" (TyFun (TyCon "ServeState") (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))
(DFunDef false "diagsServe" ((PVar "st")) (ERecordCreate "ModuleServe" ((fa "msServed" (EFieldAccess (EVar "st") "ssServed")) (fa "msFrozen" (EFieldAccess (EVar "st") "ssFrozen")) (fa "msStep" (EApp (EVar "serveStep") (EVar "st"))))))
(DTypeSig true "treeServe" (TyFun (TyCon "ServeState") (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))
(DFunDef false "treeServe" ((PVar "st")) (EApp (EVar "diagsServe") (ERecordUpdate (EVar "st") ((fa "ssTrees" (EVar "True"))))))
(DTypeSig false "serveStep" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "ServeStep") (TyCon "DiagsPayload")))))))
(DFunDef false "serveStep" ((PVar "st") (PVar "mid") (PVar "prog") (PVar "prev")) (EBlock (DoLet false false (PVar "next") (ERecordUpdate (EVar "st") ((fa "ssKeys" (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "st") "ssKeys"))) (fa "ssIfaces" (EBinOp "++" (EFieldAccess (EVar "st") "ssIfaces") (EApp (EApp (EVar "interfaceRows") (EVar "mid")) (EVar "prog")))) (fa "ssRows" (EBinOp "+" (EFieldAccess (EVar "st") "ssRows") (ELit (LInt 1))))))) (DoLet false true (PVar "unrecorded") (ELam ((PVar "done")) (ETuple (EVar "done") (EApp (EVar "diagsServe") (EApp (EApp (EVar "unrecordedState") (EVar "next")) (EVar "mid")))))) (DoExpr (EMatch (EFieldAccess (EVar "st") "ssKeys") (arm (PCons (PCon "Some" (PVar "source")) PWild) () (EBlock (DoLet false false (PVar "key") (ERecordCreate "ModuleKey" ((fa "mkModule" (EVar "mid")) (fa "mkSource" (EVar "source")) (fa "mkImports" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EVar "st") "ssIdents")))))) (EApp (EVar "dedup") (EApp (EVar "useModuleIds") (EVar "prog"))))) (fa "mkGraph" (EApp (EApp (EVar "graphPart") (EVar "st")) (EVar "prev")))))) (DoExpr (EMatch (EApp (EApp (EVar "servable") (EVar "st")) (EApp (EVar "moduleCacheHit") (EVar "key"))) (arm (PCon "Some" (PVar "mi")) () (EBlock (DoLet false false (PTuple (PTuple PWild (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))) (PVar "own")) (EApp (EApp (EVar "applyModuleInterface") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mi"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ServeHit") (EVar "own")) (EIf (EApp (EApp (EVar "isSubject") (EVar "prev")) (EVar "mid")) (EApp (EVar "privateBindingsOf") (EVar "mi")) (EListLit))) (ETuple (EApp (EApp (EApp (EVar "servedTrees") (EVar "st")) (EVar "prev")) (EVar "mi")) (EVar "schemes") (EVar "errs") (EVar "warns") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EVar "st") "ssCapture")) (EApp (EVar "Some") (EApp (EVar "readInvocationView") (EFieldAccess (EVar "mi") "miInvocationView"))) (EVar "None")))) (EApp (EVar "diagsServe") (EApp (EApp (EApp (EVar "servedState") (EVar "next")) (EVar "mid")) (EVar "mi"))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "before") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "prev") "mcGraph"))) (DoLet false false (PVar "mark") (EApp (EVar "queueMarkOf") (EFieldAccess (EVar "prev") "mcGraph"))) (DoExpr (EApp (EVar "ServeCheck") (ELam ((PVar "mctx") (PVar "own") (PVar "private") (PVar "done")) (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EVar "st") "ssUnrecorded")))) (EApp (EApp (EVar "map") (EVar "fst")) (EFieldAccess (EVar "key") "mkImports"))) (EApp (EApp (EApp (EVar "ownRootsOpen") (EFieldAccess (EVar "st") "ssOps")) (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mark"))) (EApp (EVar "unrecorded") (EVar "done")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordScoped") (EVar "next")) (EVar "key")) (EVar "before")) (EVar "mctx")) (EVar "own")) (EVar "private")) (EVar "done")) (EVar "mark")))))))))))) (arm PWild () (EApp (EVar "ServeCheck") (ELam (PWild PWild PWild (PVar "done")) (EApp (EVar "unrecorded") (EVar "done")))))))))
(DTypeSig true "isSubject" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isSubject" ((PVar "prev") (PVar "mid")) (EApp (EApp (EVar "isSubjectIn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "config") "value") "tcSibling")) (EVar "mid")))
(DTypeSig false "graphPart" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleCtx") (TyCon "String"))))
(DFunDef false "graphPart" ((PVar "st") (PVar "prev")) (EBlock (DoLet false false (PVar "graph") (EApp (EVar "joinNl") (EBinOp "::" (EFieldAccess (EVar "st") "ssGraph") (EFieldAccess (EVar "st") "ssIfaces")))) (DoExpr (EIf (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "joinNl") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "graph"))) (ELit (LString "\ntrees"))) (EApp (EVar "sort") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef") "value")))) (EVar "graph")))))
(DTypeSig false "servable" (TyFun (TyCon "ServeState") (TyFun (TyApp (TyCon "Option") (TyCon "ModuleInterface")) (TyApp (TyCon "Option") (TyCon "ModuleInterface")))))
(DFunDef false "servable" ((PVar "st") (PCon "Some" (PVar "mi"))) (EIf (EBinOp "&&" (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "isNone") (EFieldAccess (EVar "mi") "miTrees"))) (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "servable" (PWild (PVar "hit")) (EVar "hit"))
(DTypeSig false "servedTrees" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleInterface") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "servedTrees" ((PVar "st") (PVar "prev") (PVar "mi")) (EMatch (EFieldAccess (EVar "mi") "miTrees") (arm (PCon "Some" (PVar "trees")) ((GBool (EFieldAccess (EVar "st") "ssTrees"))) (EApp (EApp (EVar "applyModuleTrees") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "trees"))) (arm PWild () (EListLit))))
(DTypeSig false "servedState" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyCon "ModuleInterface") (TyCon "ServeState")))))
(DFunDef false "servedState" ((PVar "st") (PVar "mid") (PVar "mi")) (ERecordUpdate (EApp (EApp (EApp (EVar "rowFrozen") (EVar "st")) (EVar "mid")) (EVar "mi")) ((fa "ssServed" (EBinOp "+" (EFieldAccess (EVar "st") "ssServed") (ELit (LInt 1)))))))
(DTypeSig false "rowFrozen" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyCon "ModuleInterface") (TyCon "ServeState")))))
(DFunDef false "rowFrozen" ((PVar "st") (PVar "mid") (PVar "mi")) (ERecordUpdate (EVar "st") ((fa "ssIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EVar "moduleInterfaceIdentity") (EVar "mi"))) (EFieldAccess (EVar "st") "ssIdents"))) (fa "ssFrozen" (EIf (EBinOp "==" (EBinOp "+" (EFieldAccess (EVar "st") "ssFrozen") (ELit (LInt 1))) (EFieldAccess (EVar "st") "ssRows")) (EFieldAccess (EVar "st") "ssRows") (EFieldAccess (EVar "st") "ssFrozen"))))))
(DTypeSig false "unrecordedState" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyCon "ServeState"))))
(DFunDef false "unrecordedState" ((PVar "st") (PVar "mid")) (ERecordUpdate (EVar "st") ((fa "ssIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "freshModuleSerial") (ELit LUnit)))) (EFieldAccess (EVar "st") "ssIdents"))) (fa "ssUnrecorded" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EFieldAccess (EVar "st") "ssUnrecorded"))))))
(DData Private "QueueMark" () ((variant "QueueMark" (ConNamed (field "qmCtxs" (TyCon "Int")) (field "qmRoots" (TyCon "Int")) (field "qmNumRoots" (TyCon "Int")) (field "qmNumGoals" (TyCon "Int")) (field "qmBinders" (TyCon "Int")) (field "qmEvidence" (TyCon "Int"))))) ())
(DTypeSig false "queueMarkOf" (TyFun (TyCon "GraphCtx") (TyCon "QueueMark")))
(DFunDef false "queueMarkOf" ((PVar "gctx")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (ERecordCreate "QueueMark" ((fa "qmCtxs" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value"))) (fa "qmRoots" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value"))) (fa "qmNumRoots" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value"))) (fa "qmNumGoals" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))) (fa "qmBinders" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value"))) (fa "qmEvidence" (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")))))))
(DTypeSig false "ownRootsOpen" (TyFun (TyCon "ServeOps") (TyFun (TyCon "GraphCtx") (TyFun (TyCon "QueueMark") (TyCon "Bool")))))
(DFunDef false "ownRootsOpen" ((PVar "ops") (PVar "gctx") (PVar "mark")) (EBlock (DoLet false false (PVar "roots") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "liveRoots") "value")) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EVar "isNonEmptyL") (EApp (EFieldAccess (EVar "ops") "soUnboundIds") (EVar "m"))))) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "roots")) (EFieldAccess (EVar "mark") "qmRoots"))) (EVar "roots"))))))
(DTypeSig false "queueOlder" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "queueOlder" ((PVar "n") (PVar "xs")) (EApp (EApp (EVar "drop") (EBinOp "-" (EApp (EVar "listLen") (EVar "xs")) (EVar "n"))) (EVar "xs")))
(DTypeSig false "queueNewer" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "queueNewer" ((PVar "n") (PVar "xs")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "xs")) (EVar "n"))) (EVar "xs")))
(DTypeSig false "recordScoped" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyFun (TyCon "QueueMark") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))))))))))
(DFunDef false "recordScoped" ((PVar "st") (PVar "key") (PVar "before") (PVar "mctx") (PVar "own") (PVar "private") (PVar "done") (PVar "mark")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "mid") (EFieldAccess (EVar "key") "mkModule")) (DoLet false false (PVar "ctxs") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmCtxs")) (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value"))) (DoLet false false (PVar "roots") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value"))) (DoLet false false (PVar "numRoots") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmNumRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value"))) (DoLet false false (PVar "numGoals") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmNumGoals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))) (DoLet false false (PVar "binders") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmBinders")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value"))) (DoLet false false (PVar "goals") (EApp (EApp (EVar "filterList") (ELam ((PVar "lg")) (EBinOp "/=" (EFieldAccess (EVar "lg") "lgModule") (EVar "mid")))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoLet false false (PVar "judged") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoLet false false (PVar "from") (EApp (EApp (EVar "max") (EVar "judged")) (EFieldAccess (EVar "mark") "qmEvidence"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "stampCtxs")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmCtxs")) (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmNumRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmNumGoals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmBinders")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EApp (EApp (EVar "filterList") (ELam ((PVar "lg")) (EBinOp "==" (EFieldAccess (EVar "lg") "lgModule") (EVar "mid")))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EVar "from"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordChecked") (EVar "st")) (EVar "key")) (EVar "before")) (EVar "mctx")) (EVar "own")) (EVar "private")) (EVar "done"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evScopedJudged")) (EBinOp "::" (ETuple (EVar "from") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EVar "judged"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "stampCtxs")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value") (EVar "ctxs")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value") (EVar "roots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value") (EVar "numRoots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value") (EVar "numGoals")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value") (EVar "binders")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value") (EVar "goals")))) (DoExpr (EVar "result"))))
(DTypeSig false "recordChecked" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload")))))))))))
(DFunDef false "recordChecked" ((PVar "st") (PVar "key") (PVar "before") (PVar "mctx") (PVar "own") (PVar "private") (PVar "done")) (EBlock (DoLet false false (PVar "drained") (EApp (EApp (EVar "withModDiags") (EApp (EFieldAccess (EFieldAccess (EVar "st") "ssOps") "soDrain") (EVar "mctx"))) (EVar "done"))) (DoExpr (EMatch (EVar "drained") (arm (PList) () (ETuple (EVar "drained") (EApp (EVar "diagsServe") (EVar "st")))) (arm (PCons (PTuple (PVar "mid") (PTuple (PVar "marked") (PVar "schemes") (PVar "errs") (PVar "warns") PWild)) (PVar "older")) () (EBlock (DoLet false false (PVar "published") (EApp (EVar "freezeRows") (EVar "schemes"))) (DoLet false false (PVar "trees") (EIf (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "freezeModuleTrees") (EVar "mid")) (EVar "marked")) (EVar "published")) (EVar "before")) (EVar "mctx"))) (EVar "None"))) (DoLet false false (PVar "mi") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "freezeModuleInterface") (EVar "key")) (EApp (EVar "freshModuleSerial") (ELit LUnit))) (ETuple (EVar "mid") (ETuple (EVar "published") (EVar "errs") (EVar "warns")))) (EVar "own")) (EVar "private")) (EVar "before")) (EVar "mctx")) (EVar "trees"))) (DoExpr (EApp (EVar "recordModuleInterface") (EVar "mi"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "mid") (ETuple (EVar "marked") (EVar "published") (EVar "errs") (EVar "warns") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EVar "st") "ssCapture")) (EApp (EVar "Some") (EApp (EVar "readInvocationView") (EFieldAccess (EVar "mi") "miInvocationView"))) (EVar "None")))) (EVar "older")) (EApp (EVar "diagsServe") (EApp (EApp (EApp (EVar "rowFrozen") (EVar "st")) (EVar "mid")) (EVar "mi")))))))))))
(DTypeSig false "withModDiags" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))))))
(DFunDef false "withModDiags" ((PVar "f") (PVar "done")) (EApp (EApp (EVar "map") (EVar "withMarked")) (EApp (EApp (EVar "zipL") (EVar "done")) (EApp (EVar "f") (EApp (EApp (EVar "map") (EVar "payloadRow")) (EVar "done"))))))
(DTypeSig false "payloadRow" (TyFun (TyTuple (TyCon "String") (TyCon "DiagsPayload")) (TyCon "ModDiags")))
(DFunDef false "payloadRow" ((PTuple (PVar "mid") (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns") PWild))) (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns"))))
(DTypeSig false "withMarked" (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "DiagsPayload")) (TyCon "ModDiags")) (TyTuple (TyCon "String") (TyCon "DiagsPayload"))))
(DFunDef false "withMarked" ((PTuple (PTuple (PVar "mid") (PTuple (PVar "marked") PWild PWild PWild (PVar "view"))) (PTuple PWild (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))))) (ETuple (EVar "mid") (ETuple (EVar "marked") (EVar "schemes") (EVar "errs") (EVar "warns") (EVar "view"))))
# MARK
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "lines" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "isSubjectIn" false) (mem "useModuleIds" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedup" false) (mem "filterList" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinNl" false) (mem "listLen" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "chainGraphKey" false) (mem "interfaceRows" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "readInvocationView" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "ModuleKey" true) (mem "ModuleInterface" false) (mem "ModuleRows" false) (mem "applyModuleInterface" false) (mem "applyModuleTrees" false) (mem "captureModuleRows" false) (mem "freezeModuleInterface" false) (mem "freezeModuleTrees" false) (mem "freshModuleSerial" false) (mem "moduleCacheHit" false) (mem "moduleInterfaceIdentity" false) (mem "privateBindingsOf" false) (mem "recordModuleInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" false) (mem "TcDiag" false) (mem "freezeRows" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ExportBinding" false) (mem "GraphCtx" true) (mem "GraphRun" true) (mem "InvocationView" false) (mem "LiveGoal" true) (mem "ModuleCtx" true) (mem "ModuleServe" true) (mem "ServeStep" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DData Public "ServeOps" () ((variant "ServeOps" (ConNamed (field "soDrain" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags"))))) (field "soUnboundIds" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int"))))))) ())
(DTypeAlias true "DiagsPayload" () (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))))
(DData Abstract "ServeState" () ((variant "ServeState" (ConNamed (field "ssOps" (TyCon "ServeOps")) (field "ssTrees" (TyCon "Bool")) (field "ssCapture" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ssKeys" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))) (field "ssGraph" (TyCon "String")) (field "ssIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ssIdents" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "ssUnrecorded" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ssRows" (TyCon "Int")) (field "ssFrozen" (TyCon "Int")) (field "ssServed" (TyCon "Int"))))) ())
(DTypeSig true "serveStateOf" (TyFun (TyCon "ServeOps") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "ServeState")))))))
(DFunDef false "serveStateOf" ((PVar "ops") (PVar "capture") (PVar "gctx") (PVar "modules") (PTuple (PVar "chain") (PVar "steps"))) (ERecordCreate "ServeState" ((fa "ssOps" (EVar "ops")) (fa "ssTrees" (EVar "False")) (fa "ssCapture" (EVar "capture")) (fa "ssKeys" (EVar "steps")) (fa "ssGraph" (EIf (EApp (EApp (EVar "anyList") (EVar "isSome")) (EVar "steps")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcKey"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "generationLine") (EVar "chain")))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "chainGraphKey") (EVar "modules")))) (ELit (LString ""))) (ELit (LString "")))) (fa "ssIfaces" (EListLit)) (fa "ssIdents" (EVar "omEmpty")) (fa "ssUnrecorded" (EVar "omEmpty")) (fa "ssRows" (ELit (LInt 0))) (fa "ssFrozen" (ELit (LInt 0))) (fa "ssServed" (ELit (LInt 0))))))
(DTypeSig false "generationLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "generationLine" ((PVar "chain")) (EMatch (EApp (EVar "lines") (EVar "chain")) (arm (PCons (PVar "first") PWild) () (EVar "first")) (arm (PList) () (ELit (LString "")))))
(DTypeSig true "diagsServe" (TyFun (TyCon "ServeState") (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))
(DFunDef false "diagsServe" ((PVar "st")) (ERecordCreate "ModuleServe" ((fa "msServed" (EFieldAccess (EVar "st") "ssServed")) (fa "msFrozen" (EFieldAccess (EVar "st") "ssFrozen")) (fa "msStep" (EApp (EVar "serveStep") (EVar "st"))))))
(DTypeSig true "treeServe" (TyFun (TyCon "ServeState") (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))
(DFunDef false "treeServe" ((PVar "st")) (EApp (EVar "diagsServe") (ERecordUpdate (EVar "st") ((fa "ssTrees" (EVar "True"))))))
(DTypeSig false "serveStep" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "ServeStep") (TyCon "DiagsPayload")))))))
(DFunDef false "serveStep" ((PVar "st") (PVar "mid") (PVar "prog") (PVar "prev")) (EBlock (DoLet false false (PVar "next") (ERecordUpdate (EVar "st") ((fa "ssKeys" (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "st") "ssKeys"))) (fa "ssIfaces" (EBinOp "++" (EFieldAccess (EVar "st") "ssIfaces") (EApp (EApp (EVar "interfaceRows") (EVar "mid")) (EVar "prog")))) (fa "ssRows" (EBinOp "+" (EFieldAccess (EVar "st") "ssRows") (ELit (LInt 1))))))) (DoLet false true (PVar "unrecorded") (ELam ((PVar "done")) (ETuple (EVar "done") (EApp (EVar "diagsServe") (EApp (EApp (EVar "unrecordedState") (EVar "next")) (EVar "mid")))))) (DoExpr (EMatch (EFieldAccess (EVar "st") "ssKeys") (arm (PCons (PCon "Some" (PVar "source")) PWild) () (EBlock (DoLet false false (PVar "key") (ERecordCreate "ModuleKey" ((fa "mkModule" (EVar "mid")) (fa "mkSource" (EVar "source")) (fa "mkImports" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EVar "st") "ssIdents")))))) (EApp (EVar "dedup") (EApp (EVar "useModuleIds") (EVar "prog"))))) (fa "mkGraph" (EApp (EApp (EVar "graphPart") (EVar "st")) (EVar "prev")))))) (DoExpr (EMatch (EApp (EApp (EVar "servable") (EVar "st")) (EApp (EVar "moduleCacheHit") (EVar "key"))) (arm (PCon "Some" (PVar "mi")) () (EBlock (DoLet false false (PTuple (PTuple PWild (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))) (PVar "own")) (EApp (EApp (EVar "applyModuleInterface") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mi"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ServeHit") (EVar "own")) (EIf (EApp (EApp (EVar "isSubject") (EVar "prev")) (EVar "mid")) (EApp (EVar "privateBindingsOf") (EVar "mi")) (EListLit))) (ETuple (EApp (EApp (EApp (EVar "servedTrees") (EVar "st")) (EVar "prev")) (EVar "mi")) (EVar "schemes") (EVar "errs") (EVar "warns") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EVar "st") "ssCapture")) (EApp (EVar "Some") (EApp (EVar "readInvocationView") (EFieldAccess (EVar "mi") "miInvocationView"))) (EVar "None")))) (EApp (EVar "diagsServe") (EApp (EApp (EApp (EVar "servedState") (EVar "next")) (EVar "mid")) (EVar "mi"))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "before") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "prev") "mcGraph"))) (DoLet false false (PVar "mark") (EApp (EVar "queueMarkOf") (EFieldAccess (EVar "prev") "mcGraph"))) (DoExpr (EApp (EVar "ServeCheck") (ELam ((PVar "mctx") (PVar "own") (PVar "private") (PVar "done")) (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EVar "st") "ssUnrecorded")))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EFieldAccess (EVar "key") "mkImports"))) (EApp (EApp (EApp (EVar "ownRootsOpen") (EFieldAccess (EVar "st") "ssOps")) (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mark"))) (EApp (EVar "unrecorded") (EVar "done")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordScoped") (EVar "next")) (EVar "key")) (EVar "before")) (EVar "mctx")) (EVar "own")) (EVar "private")) (EVar "done")) (EVar "mark")))))))))))) (arm PWild () (EApp (EVar "ServeCheck") (ELam (PWild PWild PWild (PVar "done")) (EApp (EVar "unrecorded") (EVar "done")))))))))
(DTypeSig true "isSubject" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isSubject" ((PVar "prev") (PVar "mid")) (EApp (EApp (EVar "isSubjectIn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "config") "value") "tcSibling")) (EVar "mid")))
(DTypeSig false "graphPart" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleCtx") (TyCon "String"))))
(DFunDef false "graphPart" ((PVar "st") (PVar "prev")) (EBlock (DoLet false false (PVar "graph") (EApp (EVar "joinNl") (EBinOp "::" (EFieldAccess (EVar "st") "ssGraph") (EFieldAccess (EVar "st") "ssIfaces")))) (DoExpr (EIf (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "joinNl") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "graph"))) (ELit (LString "\ntrees"))) (EApp (EVar "sort") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef") "value")))) (EVar "graph")))))
(DTypeSig false "servable" (TyFun (TyCon "ServeState") (TyFun (TyApp (TyCon "Option") (TyCon "ModuleInterface")) (TyApp (TyCon "Option") (TyCon "ModuleInterface")))))
(DFunDef false "servable" ((PVar "st") (PCon "Some" (PVar "mi"))) (EIf (EBinOp "&&" (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "isNone") (EFieldAccess (EVar "mi") "miTrees"))) (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "servable" (PWild (PVar "hit")) (EVar "hit"))
(DTypeSig false "servedTrees" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleInterface") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "servedTrees" ((PVar "st") (PVar "prev") (PVar "mi")) (EMatch (EFieldAccess (EVar "mi") "miTrees") (arm (PCon "Some" (PVar "trees")) ((GBool (EFieldAccess (EVar "st") "ssTrees"))) (EApp (EApp (EVar "applyModuleTrees") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "trees"))) (arm PWild () (EListLit))))
(DTypeSig false "servedState" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyCon "ModuleInterface") (TyCon "ServeState")))))
(DFunDef false "servedState" ((PVar "st") (PVar "mid") (PVar "mi")) (ERecordUpdate (EApp (EApp (EApp (EVar "rowFrozen") (EVar "st")) (EVar "mid")) (EVar "mi")) ((fa "ssServed" (EBinOp "+" (EFieldAccess (EVar "st") "ssServed") (ELit (LInt 1)))))))
(DTypeSig false "rowFrozen" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyFun (TyCon "ModuleInterface") (TyCon "ServeState")))))
(DFunDef false "rowFrozen" ((PVar "st") (PVar "mid") (PVar "mi")) (ERecordUpdate (EVar "st") ((fa "ssIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EVar "moduleInterfaceIdentity") (EVar "mi"))) (EFieldAccess (EVar "st") "ssIdents"))) (fa "ssFrozen" (EIf (EBinOp "==" (EBinOp "+" (EFieldAccess (EVar "st") "ssFrozen") (ELit (LInt 1))) (EFieldAccess (EVar "st") "ssRows")) (EFieldAccess (EVar "st") "ssRows") (EFieldAccess (EVar "st") "ssFrozen"))))))
(DTypeSig false "unrecordedState" (TyFun (TyCon "ServeState") (TyFun (TyCon "String") (TyCon "ServeState"))))
(DFunDef false "unrecordedState" ((PVar "st") (PVar "mid")) (ERecordUpdate (EVar "st") ((fa "ssIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "freshModuleSerial") (ELit LUnit)))) (EFieldAccess (EVar "st") "ssIdents"))) (fa "ssUnrecorded" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EFieldAccess (EVar "st") "ssUnrecorded"))))))
(DData Private "QueueMark" () ((variant "QueueMark" (ConNamed (field "qmCtxs" (TyCon "Int")) (field "qmRoots" (TyCon "Int")) (field "qmNumRoots" (TyCon "Int")) (field "qmNumGoals" (TyCon "Int")) (field "qmBinders" (TyCon "Int")) (field "qmEvidence" (TyCon "Int"))))) ())
(DTypeSig false "queueMarkOf" (TyFun (TyCon "GraphCtx") (TyCon "QueueMark")))
(DFunDef false "queueMarkOf" ((PVar "gctx")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (ERecordCreate "QueueMark" ((fa "qmCtxs" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value"))) (fa "qmRoots" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value"))) (fa "qmNumRoots" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value"))) (fa "qmNumGoals" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))) (fa "qmBinders" (EApp (EVar "listLen") (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value"))) (fa "qmEvidence" (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")))))))
(DTypeSig false "ownRootsOpen" (TyFun (TyCon "ServeOps") (TyFun (TyCon "GraphCtx") (TyFun (TyCon "QueueMark") (TyCon "Bool")))))
(DFunDef false "ownRootsOpen" ((PVar "ops") (PVar "gctx") (PVar "mark")) (EBlock (DoLet false false (PVar "roots") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "liveRoots") "value")) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EVar "isNonEmptyL") (EApp (EFieldAccess (EVar "ops") "soUnboundIds") (EVar "m"))))) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "roots")) (EFieldAccess (EVar "mark") "qmRoots"))) (EVar "roots"))))))
(DTypeSig false "queueOlder" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "queueOlder" ((PVar "n") (PVar "xs")) (EApp (EApp (EVar "drop") (EBinOp "-" (EApp (EVar "listLen") (EVar "xs")) (EVar "n"))) (EVar "xs")))
(DTypeSig false "queueNewer" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "queueNewer" ((PVar "n") (PVar "xs")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "xs")) (EVar "n"))) (EVar "xs")))
(DTypeSig false "recordScoped" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyFun (TyCon "QueueMark") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload"))))))))))))
(DFunDef false "recordScoped" ((PVar "st") (PVar "key") (PVar "before") (PVar "mctx") (PVar "own") (PVar "private") (PVar "done") (PVar "mark")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "mid") (EFieldAccess (EVar "key") "mkModule")) (DoLet false false (PVar "ctxs") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmCtxs")) (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value"))) (DoLet false false (PVar "roots") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value"))) (DoLet false false (PVar "numRoots") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmNumRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value"))) (DoLet false false (PVar "numGoals") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmNumGoals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))) (DoLet false false (PVar "binders") (EApp (EApp (EVar "queueOlder") (EFieldAccess (EVar "mark") "qmBinders")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value"))) (DoLet false false (PVar "goals") (EApp (EApp (EVar "filterList") (ELam ((PVar "lg")) (EBinOp "/=" (EFieldAccess (EVar "lg") "lgModule") (EVar "mid")))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoLet false false (PVar "judged") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoLet false false (PVar "from") (EApp (EApp (EMethodRef "max") (EVar "judged")) (EFieldAccess (EVar "mark") "qmEvidence"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "stampCtxs")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmCtxs")) (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmNumRoots")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmNumGoals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EApp (EApp (EVar "queueNewer") (EFieldAccess (EVar "mark") "qmBinders")) (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EApp (EApp (EVar "filterList") (ELam ((PVar "lg")) (EBinOp "==" (EFieldAccess (EVar "lg") "lgModule") (EVar "mid")))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EVar "from"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordChecked") (EVar "st")) (EVar "key")) (EVar "before")) (EVar "mctx")) (EVar "own")) (EVar "private")) (EVar "done"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evScopedJudged")) (EBinOp "::" (ETuple (EVar "from") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EVar "judged"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "stampCtxs")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "stampCtxs") "value") (EVar "ctxs")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value") (EVar "roots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value") (EVar "numRoots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value") (EVar "numGoals")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value") (EVar "binders")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value") (EVar "goals")))) (DoExpr (EVar "result"))))
(DTypeSig false "recordChecked" (TyFun (TyCon "ServeState") (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "ModuleServe") (TyCon "DiagsPayload")))))))))))
(DFunDef false "recordChecked" ((PVar "st") (PVar "key") (PVar "before") (PVar "mctx") (PVar "own") (PVar "private") (PVar "done")) (EBlock (DoLet false false (PVar "drained") (EApp (EApp (EVar "withModDiags") (EApp (EFieldAccess (EFieldAccess (EVar "st") "ssOps") "soDrain") (EVar "mctx"))) (EVar "done"))) (DoExpr (EMatch (EVar "drained") (arm (PList) () (ETuple (EVar "drained") (EApp (EVar "diagsServe") (EVar "st")))) (arm (PCons (PTuple (PVar "mid") (PTuple (PVar "marked") (PVar "schemes") (PVar "errs") (PVar "warns") PWild)) (PVar "older")) () (EBlock (DoLet false false (PVar "published") (EApp (EVar "freezeRows") (EVar "schemes"))) (DoLet false false (PVar "trees") (EIf (EFieldAccess (EVar "st") "ssTrees") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "freezeModuleTrees") (EVar "mid")) (EVar "marked")) (EVar "published")) (EVar "before")) (EVar "mctx"))) (EVar "None"))) (DoLet false false (PVar "mi") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "freezeModuleInterface") (EVar "key")) (EApp (EVar "freshModuleSerial") (ELit LUnit))) (ETuple (EVar "mid") (ETuple (EVar "published") (EVar "errs") (EVar "warns")))) (EVar "own")) (EVar "private")) (EVar "before")) (EVar "mctx")) (EVar "trees"))) (DoExpr (EApp (EVar "recordModuleInterface") (EVar "mi"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "mid") (ETuple (EVar "marked") (EVar "published") (EVar "errs") (EVar "warns") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EVar "st") "ssCapture")) (EApp (EVar "Some") (EApp (EVar "readInvocationView") (EFieldAccess (EVar "mi") "miInvocationView"))) (EVar "None")))) (EVar "older")) (EApp (EVar "diagsServe") (EApp (EApp (EApp (EVar "rowFrozen") (EVar "st")) (EVar "mid")) (EVar "mi")))))))))))
(DTypeSig false "withModDiags" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DiagsPayload"))))))
(DFunDef false "withModDiags" ((PVar "f") (PVar "done")) (EApp (EApp (EMethodRef "map") (EVar "withMarked")) (EApp (EApp (EVar "zipL") (EVar "done")) (EApp (EVar "f") (EApp (EApp (EMethodRef "map") (EVar "payloadRow")) (EVar "done"))))))
(DTypeSig false "payloadRow" (TyFun (TyTuple (TyCon "String") (TyCon "DiagsPayload")) (TyCon "ModDiags")))
(DFunDef false "payloadRow" ((PTuple (PVar "mid") (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns") PWild))) (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns"))))
(DTypeSig false "withMarked" (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "DiagsPayload")) (TyCon "ModDiags")) (TyTuple (TyCon "String") (TyCon "DiagsPayload"))))
(DFunDef false "withMarked" ((PTuple (PTuple (PVar "mid") (PTuple (PVar "marked") PWild PWild PWild (PVar "view"))) (PTuple PWild (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))))) (ETuple (EVar "mid") (ETuple (EVar "marked") (EVar "schemes") (EVar "errs") (EVar "warns") (EVar "view"))))
