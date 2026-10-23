# META
source_lines=329
stages=DESUGAR,MARK
# SOURCE
import ir.core_ir.{CProgram(..), CBind(..), CClause(..)}
import backend.emit_support.{eagerCalleesMap, methodTaintSet}
import support.scc.{tarjanSCCs}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omFromNames, omKeys,
  omMapValues
}
import support.util.{reverseL, filterList, listLen, maxI}
import map as Q

public export data GlobalInitPlan = GlobalInitPlan {
  valueOrder : List String,
  eagerOrder : List String,
}

data Components = Components {
  ids : List String,
  owners : OrdMap String,
  members : OrdMap (List String),
  sourceKeys : OrdMap Int,
  dependencies : OrdMap (List String),
}

nameOf : CBind -> String
nameOf (CBind name _ _ _) = name

isValue : CBind -> Bool
isValue (CBind name [CClause [] _] _ _) = name /= "main"
isValue _ = False

lookup : a -> String -> OrdMap a -> a
lookup d name index = optionOr d (omLookup name index)

owner : Components -> String -> String
owner g name = lookup name name g.owners

indexMembers : List (List String) -> OrdMap String -> OrdMap String
indexMembers [] acc = acc
indexMembers ([] :: rest) acc = indexMembers rest acc
indexMembers ((head :: tail) :: rest) acc =
  indexMembers rest (fold (m n => omInsert n head m) acc (head :: tail))

sourceMembers : OrdMap String -> List String -> OrdMap (List String)
sourceMembers owners names =
  omMapValues
    reverseL
    (fold
      (m n =>
        let c = lookup n n owners
        omInsert c (n :: lookup [] c m) m)
      omEmpty
      names)

sourceKeys : OrdMap String -> List String -> Int -> OrdMap Int -> OrdMap Int
sourceKeys _ [] _ acc = acc
sourceKeys owners (n :: rest) rank acc =
  let c = lookup n n owners
  sourceKeys owners rest (rank + 1) (if omHasKey c acc then
    acc
  else
    omInsert c rank acc)

componentDeps : OrdMap String ->
  OrdMap (List String) ->
  List String ->
  List String
componentDeps owners adj members =
  let same = match members
    n :: _ => lookup n n owners
    [] => ""
  let targets =
    fold
      (acc n =>
        fold
          (seen dep =>
            let c = lookup dep dep owners
            if c == same then seen else omInsert c () seen)
          acc
          (lookup [] n adj))
      omEmpty
      members
  omKeys targets

components : List String -> List String -> OrdMap (List String) -> Components
components names values adj =
  let sccs = tarjanSCCs names adj
  let owners = indexMembers sccs omEmpty
  let ids =
    filterMap
      (s => match s
        n :: _ => Some n
        [] => None)
      sccs
  Components {
    ids = ids,
    owners = owners,
    members = sourceMembers owners values,
    sourceKeys = sourceKeys owners values 0 omEmpty,
    dependencies =
      fold
        (m s => match s
          n :: _ => omInsert n (componentDeps owners adj s) m
          [] => m)
        omEmpty
        sccs,
  }

data QueueState = QueueState {
  ready : Q.Map Int String,
  counts : OrdMap Int,
  users : OrdMap (List String),
}

queueState : Components -> QueueState
queueState g =
  fold
    (q c =>
      let deps = lookup [] c g.dependencies
      let count = listLen deps
      { q |
        counts = omInsert c count q.counts,
        ready =
          if count == 0 then
            Q.set (lookup 0 c g.sourceKeys) c q.ready
          else
            q.ready,
        users = fold (m d => omInsert d (c :: lookup [] d m) m) q.users deps,
      })
    QueueState { ready = Q.Tip, counts = omEmpty, users = omEmpty }
    g.ids

release : Components -> QueueState -> String -> QueueState
release g q c =
  fold
    (acc user =>
      let count = lookup 0 user acc.counts - 1
      { acc |
        counts = omInsert user count acc.counts,
        ready =
          if count == 0 then
            Q.set (lookup 0 user g.sourceKeys) user acc.ready
          else
            acc.ready,
      })
    q
    (lookup [] c q.users)

queueOrder : Components -> QueueState -> List String -> List String
queueOrder g q rev = match Q.minView q.ready
  None => reverseL rev
  Some (_, c, rest) =>
    let next = release g { q | ready = rest } c
    queueOrder g next (fold (acc n => n :: acc) rev (lookup [] c g.members))

export
planGlobals : CProgram -> List String -> OrdMap (List String) -> GlobalInitPlan
planGlobals (CProgram binds _ _ _ _ _) lazy reach =
  let names = map nameOf (filterList isValue binds)
  let universe = omFromNames names omEmpty
  let adj =
    fold
      (m n =>
        omInsert
          n
          (filterList (d => omHasKey d universe) (lookup [] n reach))
          m)
      omEmpty
      names
  let g = components names names adj
  let order = queueOrder g (queueState g) []
  let lazySet = omFromNames lazy omEmpty
  GlobalInitPlan {
    valueOrder = order,
    eagerOrder = filterList (n => not (omHasKey n lazySet)) order,
  }

unique : List String -> OrdMap Unit -> Bool
unique [] _ = True
unique (n :: ns) seen = not (omHasKey n seen) && unique ns (omInsert n () seen)

malformedValue : CBind -> Bool
malformedValue (CBind _ clauses _ _) = match clauses
  [] => True
  [CClause [] _] => False
  _ =>
    any
      (c => match c
        CClause [] _ => True
        _ => False)
      clauses

sameMembers : List String -> List String -> Bool
sameMembers expected actual =
  let names = omFromNames expected omEmpty
  listLen expected == listLen actual
    && unique actual omEmpty
    && all (n => omHasKey n names) actual

componentSequence : Components -> List String -> List String
componentSequence _ [] = []
componentSequence g (n :: ns) =
  let c = owner g n
  c :: sequenceRest g c ns

sequenceRest : Components -> String -> List String -> List String
sequenceRest _ _ [] = []
sequenceRest g previous (n :: ns) =
  let c = owner g n
  if c == previous then sequenceRest g previous ns else c :: sequenceRest g c ns

rankNames : List String -> Int -> OrdMap Int -> OrdMap Int
rankNames [] _ acc = acc
rankNames (n :: ns) rank acc = rankNames ns (rank + 1) (omInsert n rank acc)

-- A dependency's maximum includes its own value rank; helper-only SCCs carry
-- that maximum onward without occupying a position in the supplied order.
data Summary = Summary {
  dependencyRank : Int,
  maximumRank : Int,
  tainted : Bool,
}

summaries : Components ->
  OrdMap (List String) ->
  OrdMap Unit ->
  List String ->
  OrdMap Int ->
  OrdMap Summary
summaries g adj methods names ranks =
  let cyclic =
    fold
      (m n =>
        let c = owner g n
        let self = any (== n) (lookup [] n adj)
        let (count, loop) = lookup (0, False) c m
        omInsert c (count + 1, loop || self || omHasKey n methods) m)
      omEmpty
      names
  fold
    (acc c =>
      let (count, direct) = lookup (0, False) c cyclic
      let (d, taint) =
        fold
          ((maximum, bad) dep => match omLookup dep acc
            Some s => (maxI maximum s.maximumRank, bad || s.tainted)
            None => (maximum, bad))
          (-1, count > 1 || direct)
          (lookup [] c g.dependencies)
      omInsert
        c
        Summary {
          dependencyRank = d,
          maximumRank = maxI d (lookup (-1) c ranks),
          tainted = taint,
        }
        acc)
    omEmpty
    g.ids

dropSmaller : Int -> List (Int, Int) -> List (Int, Int)
dropSmaller _ [] = []
dropSmaller key ((k, r) :: rest) =
  if k <= key then dropSmaller key rest else (k, r) :: rest

-- The nearest earlier component with a larger source key must have run before
-- this component became ready. The decreasing stack finds that witness once.
priorityValid : Components ->
  OrdMap Summary ->
  List String ->
  Int ->
  List (Int, Int) ->
  Bool
priorityValid _ _ [] _ _ = True
priorityValid g facts (c :: cs) rank stack =
  let key = lookup 0 c g.sourceKeys
  let smaller = dropSmaller key stack
  let d = match omLookup c facts
    Some s => s.dependencyRank
    None => -1
  let valid = match smaller
    (_, earlier) :: _ => earlier <= d
    [] => True
  valid && priorityValid g facts cs (rank + 1) ((key, rank) :: smaller)

export
validateGlobalInit : CProgram -> List String -> GlobalInitPlan -> List String
validateGlobalInit (CProgram binds _ _ _ _ _) lazy candidate =
  let names = map nameOf binds
  let values = map nameOf (filterList isValue binds)
  if not (unique names omEmpty) then
    ["global init: duplicate binding"]
  else if any malformedValue binds
    || not (sameMembers values candidate.valueOrder) then
    ["global init: membership"]
  else
    let adj = eagerCalleesMap (omFromNames names omEmpty) binds
    let g = components names values adj
    let sequence = componentSequence g candidate.valueOrder
    let contiguous = unique sequence omEmpty
    let members =
      if contiguous then flatMap (c => lookup [] c g.members) sequence else []
    if not contiguous || members /= candidate.valueOrder then
      ["global init: component order"]
    else
      let ranks = rankNames sequence 0 omEmpty
      let facts = summaries g adj (methodTaintSet binds) names ranks
      let isLazy n = match omLookup (owner g n) facts
        Some s => s.tainted
        None => False
      let expectedLazy = filterList isLazy values
      let lazySet = omFromNames expectedLazy omEmpty
      if not (unique lazy omEmpty) || lazy /= expectedLazy then
        if any (n => omHasKey n lazySet) candidate.eagerOrder then
          ["global init: eager cycle / lazy partition"]
        else
          ["global init: lazy partition"]
      else if any
        (c => match omLookup c facts
          Some s => s.dependencyRank >= lookup (-1) c ranks
          None => True)
        sequence then
        ["global init: dependency order"]
      else if not (priorityValid g facts sequence 0 []) then
        ["global init: source priority"]
      else if candidate.eagerOrder
        /= filterList (n => not (omHasKey n lazySet)) candidate.valueOrder then
        ["global init: lazy partition"]
      else
        []
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerCalleesMap" false) (mem "methodTaintSet" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omKeys" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "maxI" false))))
(DUse false (UseAlias ("map") "Q"))
(DData Public "GlobalInitPlan" () ((variant "GlobalInitPlan" (ConNamed (field "valueOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerOrder" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Private "Components" () ((variant "Components" (ConNamed (field "ids" (TyApp (TyCon "List") (TyCon "String"))) (field "owners" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "members" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "sourceKeys" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "dependencies" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "nameOf" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "nameOf" ((PCon "CBind" (PVar "name") PWild PWild PWild)) (EVar "name"))
(DTypeSig false "isValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValue" ((PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EBinOp "/=" (EVar "name") (ELit (LString "main"))))
(DFunDef false "isValue" (PWild) (EVar "False"))
(DTypeSig false "lookup" (TyFun (TyVar "a") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyVar "a")))))
(DFunDef false "lookup" ((PVar "d") (PVar "name") (PVar "index")) (EApp (EApp (EVar "optionOr") (EVar "d")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "index"))))
(DTypeSig false "owner" (TyFun (TyCon "Components") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "owner" ((PVar "g") (PVar "name")) (EApp (EApp (EApp (EVar "lookup") (EVar "name")) (EVar "name")) (EFieldAccess (EVar "g") "owners")))
(DTypeSig false "indexMembers" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "indexMembers" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "indexMembers" ((PCons (PList) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "indexMembers") (EVar "rest")) (EVar "acc")))
(DFunDef false "indexMembers" ((PCons (PCons (PVar "head") (PVar "tail")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "indexMembers") (EVar "rest")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "head")) (EVar "m")))) (EVar "acc")) (EBinOp "::" (EVar "head") (EVar "tail")))))
(DTypeSig false "sourceMembers" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sourceMembers" ((PVar "owners") (PVar "names")) (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EBinOp "::" (EVar "n") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EVar "m")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "names"))))
(DTypeSig false "sourceKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))))
(DFunDef false "sourceKeys" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "sourceKeys" ((PVar "owners") (PCons (PVar "n") (PVar "rest")) (PVar "rank") (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sourceKeys") (EVar "owners")) (EVar "rest")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EVar "rank")) (EVar "acc")))))))
(DTypeSig false "componentDeps" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "componentDeps" ((PVar "owners") (PVar "adj") (PVar "members")) (EBlock (DoLet false false (PVar "same") (EMatch (EVar "members") (arm (PCons (PVar "n") PWild) () (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (arm (PList) () (ELit (LString ""))))) (DoLet false false (PVar "targets") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "seen") (PVar "dep")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "dep")) (EVar "dep")) (EVar "owners"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "same")) (EVar "seen") (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen"))))))) (EVar "acc")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "adj"))))) (EVar "omEmpty")) (EVar "members"))) (DoExpr (EApp (EVar "omKeys") (EVar "targets")))))
(DTypeSig false "components" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Components")))))
(DFunDef false "components" ((PVar "names") (PVar "values") (PVar "adj")) (EBlock (DoLet false false (PVar "sccs") (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "owners") (EApp (EApp (EVar "indexMembers") (EVar "sccs")) (EVar "omEmpty"))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "filterMap") (ELam ((PVar "s")) (EMatch (EVar "s") (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None"))))) (EVar "sccs"))) (DoExpr (ERecordCreate "Components" ((fa "ids" (EVar "ids")) (fa "owners" (EVar "owners")) (fa "members" (EApp (EApp (EVar "sourceMembers") (EVar "owners")) (EVar "values"))) (fa "sourceKeys" (EApp (EApp (EApp (EApp (EVar "sourceKeys") (EVar "owners")) (EVar "values")) (ELit (LInt 0))) (EVar "omEmpty"))) (fa "dependencies" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "s")) (EMatch (EVar "s") (arm (PCons (PVar "n") PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "componentDeps") (EVar "owners")) (EVar "adj")) (EVar "s"))) (EVar "m"))) (arm (PList) () (EVar "m"))))) (EVar "omEmpty")) (EVar "sccs"))))))))
(DData Private "QueueState" () ((variant "QueueState" (ConNamed (field "ready" (TyApp (TyApp (TyCon "Q.Map") (TyCon "Int")) (TyCon "String"))) (field "counts" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "users" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "queueState" (TyFun (TyCon "Components") (TyCon "QueueState")))
(DFunDef false "queueState" ((PVar "g")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "q") (PVar "c")) (EBlock (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies"))) (DoLet false false (PVar "count") (EApp (EVar "listLen") (EVar "deps"))) (DoExpr (ERecordUpdate (EVar "q") ((fa "counts" (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EVar "count")) (EFieldAccess (EVar "q") "counts"))) (fa "ready" (EIf (EBinOp "==" (EVar "count") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Q.set") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (EVar "c")) (EFieldAccess (EVar "q") "ready")) (EFieldAccess (EVar "q") "ready"))) (fa "users" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "d")) (EApp (EApp (EApp (EVar "omInsert") (EVar "d")) (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "d")) (EVar "m")))) (EVar "m")))) (EFieldAccess (EVar "q") "users")) (EVar "deps"))))))))) (ERecordCreate "QueueState" ((fa "ready" (EVar "Q.Tip")) (fa "counts" (EVar "omEmpty")) (fa "users" (EVar "omEmpty"))))) (EFieldAccess (EVar "g") "ids")))
(DTypeSig false "release" (TyFun (TyCon "Components") (TyFun (TyCon "QueueState") (TyFun (TyCon "String") (TyCon "QueueState")))))
(DFunDef false "release" ((PVar "g") (PVar "q") (PVar "c")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "user")) (EBlock (DoLet false false (PVar "count") (EBinOp "-" (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "user")) (EFieldAccess (EVar "acc") "counts")) (ELit (LInt 1)))) (DoExpr (ERecordUpdate (EVar "acc") ((fa "counts" (EApp (EApp (EApp (EVar "omInsert") (EVar "user")) (EVar "count")) (EFieldAccess (EVar "acc") "counts"))) (fa "ready" (EIf (EBinOp "==" (EVar "count") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Q.set") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "user")) (EFieldAccess (EVar "g") "sourceKeys"))) (EVar "user")) (EFieldAccess (EVar "acc") "ready")) (EFieldAccess (EVar "acc") "ready"))))))))) (EVar "q")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "q") "users"))))
(DTypeSig false "queueOrder" (TyFun (TyCon "Components") (TyFun (TyCon "QueueState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "queueOrder" ((PVar "g") (PVar "q") (PVar "rev")) (EMatch (EApp (EVar "Q.minView") (EFieldAccess (EVar "q") "ready")) (arm (PCon "None") () (EApp (EVar "reverseL") (EVar "rev"))) (arm (PCon "Some" (PTuple PWild (PVar "c") (PVar "rest"))) () (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "release") (EVar "g")) (ERecordUpdate (EVar "q") ((fa "ready" (EVar "rest"))))) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EVar "next")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EBinOp "::" (EVar "n") (EVar "acc")))) (EVar "rev")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))))))))
(DTypeSig true "planGlobals" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "GlobalInitPlan")))))
(DFunDef false "planGlobals" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (PVar "lazy") (PVar "reach")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "universe") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "universe")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "reach")))) (EVar "m")))) (EVar "omEmpty")) (EVar "names"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "order") (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EApp (EVar "queueState") (EVar "g"))) (EListLit))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "lazy")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "GlobalInitPlan" ((fa "valueOrder" (EVar "order")) (fa "eagerOrder" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EVar "order"))))))))
(DTypeSig false "unique" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "unique" ((PList) PWild) (EVar "True"))
(DFunDef false "unique" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen"))) (EApp (EApp (EVar "unique") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig false "malformedValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "malformedValue" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EMatch (EVar "clauses") (arm (PList) () (EVar "True")) (arm (PList (PCon "CClause" (PList) PWild)) () (EVar "False")) (arm PWild () (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "CClause" (PList) PWild) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "clauses")))))
(DTypeSig false "sameMembers" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "sameMembers" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EVar "expected")) (EVar "omEmpty"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "expected")) (EApp (EVar "listLen") (EVar "actual"))) (EApp (EApp (EVar "unique") (EVar "actual")) (EVar "omEmpty"))) (EApp (EApp (EVar "all") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")))) (EVar "actual"))))))
(DTypeSig false "componentSequence" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "componentSequence" (PWild (PList)) (EListLit))
(DFunDef false "componentSequence" ((PVar "g") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoExpr (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "c")) (EVar "ns"))))))
(DTypeSig false "sequenceRest" (TyFun (TyCon "Components") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sequenceRest" (PWild PWild (PList)) (EListLit))
(DFunDef false "sequenceRest" ((PVar "g") (PVar "previous") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "previous")) (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "previous")) (EVar "ns")) (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "c")) (EVar "ns")))))))
(DTypeSig false "rankNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "rankNames" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "rankNames" ((PCons (PVar "n") (PVar "ns")) (PVar "rank") (PVar "acc")) (EApp (EApp (EApp (EVar "rankNames") (EVar "ns")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "rank")) (EVar "acc"))))
(DData Private "Summary" () ((variant "Summary" (ConNamed (field "dependencyRank" (TyCon "Int")) (field "maximumRank" (TyCon "Int")) (field "tainted" (TyCon "Bool"))))) ())
(DTypeSig false "summaries" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Summary"))))))))
(DFunDef false "summaries" ((PVar "g") (PVar "adj") (PVar "methods") (PVar "names") (PVar "ranks")) (EBlock (DoLet false false (PVar "cyclic") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoLet false false (PVar "self") (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "adj")))) (DoLet false false (PTuple (PVar "count") (PVar "loop")) (EApp (EApp (EApp (EVar "lookup") (ETuple (ELit (LInt 0)) (EVar "False"))) (EVar "c")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ETuple (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EBinOp "||" (EBinOp "||" (EVar "loop") (EVar "self")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))) (EVar "m")))))) (EVar "omEmpty")) (EVar "names"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "c")) (EBlock (DoLet false false (PTuple (PVar "count") (PVar "direct")) (EApp (EApp (EApp (EVar "lookup") (ETuple (ELit (LInt 0)) (EVar "False"))) (EVar "c")) (EVar "cyclic"))) (DoLet false false (PTuple (PVar "d") (PVar "taint")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "maximum") (PVar "bad")) (PVar "dep")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EVar "acc")) (arm (PCon "Some" (PVar "s")) () (ETuple (EApp (EApp (EVar "maxI") (EVar "maximum")) (EFieldAccess (EVar "s") "maximumRank")) (EBinOp "||" (EVar "bad") (EFieldAccess (EVar "s") "tainted")))) (arm (PCon "None") () (ETuple (EVar "maximum") (EVar "bad")))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (EBinOp "||" (EBinOp ">" (EVar "count") (ELit (LInt 1))) (EVar "direct")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ERecordCreate "Summary" ((fa "dependencyRank" (EVar "d")) (fa "maximumRank" (EApp (EApp (EVar "maxI") (EVar "d")) (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (fa "tainted" (EVar "taint"))))) (EVar "acc")))))) (EVar "omEmpty")) (EFieldAccess (EVar "g") "ids")))))
(DTypeSig false "dropSmaller" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "dropSmaller" (PWild (PList)) (EListLit))
(DFunDef false "dropSmaller" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "r")) (PVar "rest"))) (EIf (EBinOp "<=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "r")) (EVar "rest"))))
(DTypeSig false "priorityValid" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Summary")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))))))
(DFunDef false "priorityValid" (PWild PWild (PList) PWild PWild) (EVar "True"))
(DFunDef false "priorityValid" ((PVar "g") (PVar "facts") (PCons (PVar "c") (PVar "cs")) (PVar "rank") (PVar "stack")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "stack"))) (DoLet false false (PVar "d") (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "dependencyRank")) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoLet false false (PVar "valid") (EMatch (EVar "smaller") (arm (PCons (PTuple PWild (PVar "earlier")) PWild) () (EBinOp "<=" (EVar "earlier") (EVar "d"))) (arm (PList) () (EVar "True")))) (DoExpr (EBinOp "&&" (EVar "valid") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EVar "cs")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "key") (EVar "rank")) (EVar "smaller")))))))
(DTypeSig true "validateGlobalInit" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateGlobalInit" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (PVar "lazy") (PVar "candidate")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "nameOf")) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "names")) (EVar "omEmpty"))) (EListLit (ELit (LString "global init: duplicate binding"))) (EIf (EBinOp "||" (EApp (EApp (EVar "any") (EVar "malformedValue")) (EVar "binds")) (EApp (EVar "not") (EApp (EApp (EVar "sameMembers") (EVar "values")) (EFieldAccess (EVar "candidate") "valueOrder")))) (EListLit (ELit (LString "global init: membership"))) (EBlock (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "values")) (EVar "adj"))) (DoLet false false (PVar "sequence") (EApp (EApp (EVar "componentSequence") (EVar "g")) (EFieldAccess (EVar "candidate") "valueOrder"))) (DoLet false false (PVar "contiguous") (EApp (EApp (EVar "unique") (EVar "sequence")) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EIf (EVar "contiguous") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))) (EVar "sequence")) (EListLit))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EVar "contiguous")) (EBinOp "/=" (EVar "members") (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: component order"))) (EBlock (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "sequence")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EApp (EVar "summaries") (EVar "g")) (EVar "adj")) (EApp (EVar "methodTaintSet") (EVar "binds"))) (EVar "names")) (EVar "ranks"))) (DoLet false true (PVar "isLazy") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "tainted")) (arm (PCon "None") () (EVar "False"))))) (DoLet false false (PVar "expectedLazy") (EApp (EApp (EVar "filterList") (EVar "isLazy")) (EVar "values"))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "expectedLazy")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "lazy")) (EVar "omEmpty"))) (EBinOp "/=" (EVar "lazy") (EVar "expectedLazy"))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet")))) (EFieldAccess (EVar "candidate") "eagerOrder")) (EListLit (ELit (LString "global init: eager cycle / lazy partition"))) (EListLit (ELit (LString "global init: lazy partition")))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EBinOp ">=" (EFieldAccess (EVar "s") "dependencyRank") (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (arm (PCon "None") () (EVar "True"))))) (EVar "sequence")) (EListLit (ELit (LString "global init: dependency order"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EVar "sequence")) (ELit (LInt 0))) (EListLit))) (EListLit (ELit (LString "global init: source priority"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "candidate") "eagerOrder") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: lazy partition"))) (EListLit)))))))))))))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerCalleesMap" false) (mem "methodTaintSet" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omKeys" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "maxI" false))))
(DUse false (UseAlias ("map") "Q"))
(DData Public "GlobalInitPlan" () ((variant "GlobalInitPlan" (ConNamed (field "valueOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerOrder" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Private "Components" () ((variant "Components" (ConNamed (field "ids" (TyApp (TyCon "List") (TyCon "String"))) (field "owners" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "members" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "sourceKeys" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "dependencies" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "nameOf" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "nameOf" ((PCon "CBind" (PVar "name") PWild PWild PWild)) (EVar "name"))
(DTypeSig false "isValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValue" ((PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EBinOp "/=" (EVar "name") (ELit (LString "main"))))
(DFunDef false "isValue" (PWild) (EVar "False"))
(DTypeSig false "lookup" (TyFun (TyVar "a") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyVar "a")))))
(DFunDef false "lookup" ((PVar "d") (PVar "name") (PVar "index")) (EApp (EApp (EVar "optionOr") (EVar "d")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EMethodRef "index"))))
(DTypeSig false "owner" (TyFun (TyCon "Components") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "owner" ((PVar "g") (PVar "name")) (EApp (EApp (EApp (EVar "lookup") (EVar "name")) (EVar "name")) (EFieldAccess (EVar "g") "owners")))
(DTypeSig false "indexMembers" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "indexMembers" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "indexMembers" ((PCons (PList) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "indexMembers") (EVar "rest")) (EVar "acc")))
(DFunDef false "indexMembers" ((PCons (PCons (PVar "head") (PVar "tail")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "indexMembers") (EVar "rest")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "head")) (EVar "m")))) (EVar "acc")) (EBinOp "::" (EVar "head") (EVar "tail")))))
(DTypeSig false "sourceMembers" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sourceMembers" ((PVar "owners") (PVar "names")) (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EBinOp "::" (EVar "n") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EVar "m")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "names"))))
(DTypeSig false "sourceKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))))
(DFunDef false "sourceKeys" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "sourceKeys" ((PVar "owners") (PCons (PVar "n") (PVar "rest")) (PVar "rank") (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sourceKeys") (EVar "owners")) (EVar "rest")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EVar "rank")) (EVar "acc")))))))
(DTypeSig false "componentDeps" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "componentDeps" ((PVar "owners") (PVar "adj") (PVar "members")) (EBlock (DoLet false false (PVar "same") (EMatch (EVar "members") (arm (PCons (PVar "n") PWild) () (EApp (EApp (EApp (EVar "lookup") (EVar "n")) (EVar "n")) (EVar "owners"))) (arm (PList) () (ELit (LString ""))))) (DoLet false false (PVar "targets") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "seen") (PVar "dep")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "lookup") (EVar "dep")) (EVar "dep")) (EVar "owners"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "same")) (EVar "seen") (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen"))))))) (EVar "acc")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "adj"))))) (EVar "omEmpty")) (EVar "members"))) (DoExpr (EApp (EVar "omKeys") (EVar "targets")))))
(DTypeSig false "components" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Components")))))
(DFunDef false "components" ((PVar "names") (PVar "values") (PVar "adj")) (EBlock (DoLet false false (PVar "sccs") (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "owners") (EApp (EApp (EVar "indexMembers") (EVar "sccs")) (EVar "omEmpty"))) (DoLet false false (PVar "ids") (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "s")) (EMatch (EVar "s") (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None"))))) (EVar "sccs"))) (DoExpr (ERecordCreate "Components" ((fa "ids" (EVar "ids")) (fa "owners" (EVar "owners")) (fa "members" (EApp (EApp (EVar "sourceMembers") (EVar "owners")) (EVar "values"))) (fa "sourceKeys" (EApp (EApp (EApp (EApp (EVar "sourceKeys") (EVar "owners")) (EVar "values")) (ELit (LInt 0))) (EVar "omEmpty"))) (fa "dependencies" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "s")) (EMatch (EVar "s") (arm (PCons (PVar "n") PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "componentDeps") (EVar "owners")) (EVar "adj")) (EVar "s"))) (EVar "m"))) (arm (PList) () (EVar "m"))))) (EVar "omEmpty")) (EVar "sccs"))))))))
(DData Private "QueueState" () ((variant "QueueState" (ConNamed (field "ready" (TyApp (TyApp (TyCon "Q.Map") (TyCon "Int")) (TyCon "String"))) (field "counts" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "users" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "queueState" (TyFun (TyCon "Components") (TyCon "QueueState")))
(DFunDef false "queueState" ((PVar "g")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "q") (PVar "c")) (EBlock (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies"))) (DoLet false false (PVar "count") (EApp (EVar "listLen") (EVar "deps"))) (DoExpr (ERecordUpdate (EVar "q") ((fa "counts" (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EDictApp "count")) (EFieldAccess (EVar "q") "counts"))) (fa "ready" (EIf (EBinOp "==" (EDictApp "count") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Q.set") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (EVar "c")) (EFieldAccess (EVar "q") "ready")) (EFieldAccess (EVar "q") "ready"))) (fa "users" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "d")) (EApp (EApp (EApp (EVar "omInsert") (EVar "d")) (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "d")) (EVar "m")))) (EVar "m")))) (EFieldAccess (EVar "q") "users")) (EVar "deps"))))))))) (ERecordCreate "QueueState" ((fa "ready" (EVar "Q.Tip")) (fa "counts" (EVar "omEmpty")) (fa "users" (EVar "omEmpty"))))) (EFieldAccess (EVar "g") "ids")))
(DTypeSig false "release" (TyFun (TyCon "Components") (TyFun (TyCon "QueueState") (TyFun (TyCon "String") (TyCon "QueueState")))))
(DFunDef false "release" ((PVar "g") (PVar "q") (PVar "c")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "user")) (EBlock (DoLet false false (PVar "count") (EBinOp "-" (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "user")) (EFieldAccess (EVar "acc") "counts")) (ELit (LInt 1)))) (DoExpr (ERecordUpdate (EVar "acc") ((fa "counts" (EApp (EApp (EApp (EVar "omInsert") (EVar "user")) (EDictApp "count")) (EFieldAccess (EVar "acc") "counts"))) (fa "ready" (EIf (EBinOp "==" (EDictApp "count") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Q.set") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "user")) (EFieldAccess (EVar "g") "sourceKeys"))) (EVar "user")) (EFieldAccess (EVar "acc") "ready")) (EFieldAccess (EVar "acc") "ready"))))))))) (EVar "q")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "q") "users"))))
(DTypeSig false "queueOrder" (TyFun (TyCon "Components") (TyFun (TyCon "QueueState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "queueOrder" ((PVar "g") (PVar "q") (PVar "rev")) (EMatch (EApp (EVar "Q.minView") (EFieldAccess (EVar "q") "ready")) (arm (PCon "None") () (EApp (EVar "reverseL") (EVar "rev"))) (arm (PCon "Some" (PTuple PWild (PVar "c") (PVar "rest"))) () (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "release") (EVar "g")) (ERecordUpdate (EVar "q") ((fa "ready" (EVar "rest"))))) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EVar "next")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EBinOp "::" (EVar "n") (EVar "acc")))) (EVar "rev")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))))))))
(DTypeSig true "planGlobals" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "GlobalInitPlan")))))
(DFunDef false "planGlobals" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (PVar "lazy") (PVar "reach")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "universe") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "universe")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "reach")))) (EVar "m")))) (EVar "omEmpty")) (EVar "names"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "order") (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EApp (EVar "queueState") (EVar "g"))) (EListLit))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "lazy")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "GlobalInitPlan" ((fa "valueOrder" (EVar "order")) (fa "eagerOrder" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EVar "order"))))))))
(DTypeSig false "unique" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "unique" ((PList) PWild) (EVar "True"))
(DFunDef false "unique" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen"))) (EApp (EApp (EVar "unique") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig false "malformedValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "malformedValue" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EMatch (EVar "clauses") (arm (PList) () (EVar "True")) (arm (PList (PCon "CClause" (PList) PWild)) () (EVar "False")) (arm PWild () (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "CClause" (PList) PWild) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "clauses")))))
(DTypeSig false "sameMembers" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "sameMembers" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EVar "expected")) (EVar "omEmpty"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "expected")) (EApp (EVar "listLen") (EVar "actual"))) (EApp (EApp (EVar "unique") (EVar "actual")) (EVar "omEmpty"))) (EApp (EApp (EDictApp "all") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")))) (EVar "actual"))))))
(DTypeSig false "componentSequence" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "componentSequence" (PWild (PList)) (EListLit))
(DFunDef false "componentSequence" ((PVar "g") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoExpr (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "c")) (EVar "ns"))))))
(DTypeSig false "sequenceRest" (TyFun (TyCon "Components") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sequenceRest" (PWild PWild (PList)) (EListLit))
(DFunDef false "sequenceRest" ((PVar "g") (PVar "previous") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "previous")) (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "previous")) (EVar "ns")) (EBinOp "::" (EVar "c") (EApp (EApp (EApp (EVar "sequenceRest") (EVar "g")) (EVar "c")) (EVar "ns")))))))
(DTypeSig false "rankNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "rankNames" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "rankNames" ((PCons (PVar "n") (PVar "ns")) (PVar "rank") (PVar "acc")) (EApp (EApp (EApp (EVar "rankNames") (EVar "ns")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "rank")) (EVar "acc"))))
(DData Private "Summary" () ((variant "Summary" (ConNamed (field "dependencyRank" (TyCon "Int")) (field "maximumRank" (TyCon "Int")) (field "tainted" (TyCon "Bool"))))) ())
(DTypeSig false "summaries" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Summary"))))))))
(DFunDef false "summaries" ((PVar "g") (PVar "adj") (PVar "methods") (PVar "names") (PVar "ranks")) (EBlock (DoLet false false (PVar "cyclic") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (DoLet false false (PVar "self") (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "adj")))) (DoLet false false (PTuple (PVar "count") (PVar "loop")) (EApp (EApp (EApp (EVar "lookup") (ETuple (ELit (LInt 0)) (EVar "False"))) (EVar "c")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ETuple (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EBinOp "||" (EBinOp "||" (EVar "loop") (EVar "self")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))) (EVar "m")))))) (EVar "omEmpty")) (EVar "names"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "c")) (EBlock (DoLet false false (PTuple (PVar "count") (PVar "direct")) (EApp (EApp (EApp (EVar "lookup") (ETuple (ELit (LInt 0)) (EVar "False"))) (EVar "c")) (EVar "cyclic"))) (DoLet false false (PTuple (PVar "d") (PVar "taint")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "maximum") (PVar "bad")) (PVar "dep")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EVar "acc")) (arm (PCon "Some" (PVar "s")) () (ETuple (EApp (EApp (EVar "maxI") (EDictApp "maximum")) (EFieldAccess (EVar "s") "maximumRank")) (EBinOp "||" (EVar "bad") (EFieldAccess (EVar "s") "tainted")))) (arm (PCon "None") () (ETuple (EDictApp "maximum") (EVar "bad")))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (EBinOp "||" (EBinOp ">" (EDictApp "count") (ELit (LInt 1))) (EVar "direct")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ERecordCreate "Summary" ((fa "dependencyRank" (EVar "d")) (fa "maximumRank" (EApp (EApp (EVar "maxI") (EVar "d")) (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (fa "tainted" (EVar "taint"))))) (EVar "acc")))))) (EVar "omEmpty")) (EFieldAccess (EVar "g") "ids")))))
(DTypeSig false "dropSmaller" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "dropSmaller" (PWild (PList)) (EListLit))
(DFunDef false "dropSmaller" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "r")) (PVar "rest"))) (EIf (EBinOp "<=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "r")) (EVar "rest"))))
(DTypeSig false "priorityValid" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Summary")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))))))
(DFunDef false "priorityValid" (PWild PWild (PList) PWild PWild) (EVar "True"))
(DFunDef false "priorityValid" ((PVar "g") (PVar "facts") (PCons (PVar "c") (PVar "cs")) (PVar "rank") (PVar "stack")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "stack"))) (DoLet false false (PVar "d") (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "dependencyRank")) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoLet false false (PVar "valid") (EMatch (EVar "smaller") (arm (PCons (PTuple PWild (PVar "earlier")) PWild) () (EBinOp "<=" (EVar "earlier") (EVar "d"))) (arm (PList) () (EVar "True")))) (DoExpr (EBinOp "&&" (EVar "valid") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EVar "cs")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "key") (EVar "rank")) (EVar "smaller")))))))
(DTypeSig true "validateGlobalInit" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateGlobalInit" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (PVar "lazy") (PVar "candidate")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "names")) (EVar "omEmpty"))) (EListLit (ELit (LString "global init: duplicate binding"))) (EIf (EBinOp "||" (EApp (EApp (EDictApp "any") (EVar "malformedValue")) (EVar "binds")) (EApp (EVar "not") (EApp (EApp (EVar "sameMembers") (EVar "values")) (EFieldAccess (EVar "candidate") "valueOrder")))) (EListLit (ELit (LString "global init: membership"))) (EBlock (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "values")) (EVar "adj"))) (DoLet false false (PVar "sequence") (EApp (EApp (EVar "componentSequence") (EVar "g")) (EFieldAccess (EVar "candidate") "valueOrder"))) (DoLet false false (PVar "contiguous") (EApp (EApp (EVar "unique") (EMethodRef "sequence")) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EIf (EVar "contiguous") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))) (EMethodRef "sequence")) (EListLit))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EVar "contiguous")) (EBinOp "/=" (EVar "members") (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: component order"))) (EBlock (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EMethodRef "sequence")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EApp (EVar "summaries") (EVar "g")) (EVar "adj")) (EApp (EVar "methodTaintSet") (EVar "binds"))) (EVar "names")) (EVar "ranks"))) (DoLet false true (PVar "isLazy") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "tainted")) (arm (PCon "None") () (EVar "False"))))) (DoLet false false (PVar "expectedLazy") (EApp (EApp (EVar "filterList") (EVar "isLazy")) (EVar "values"))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "expectedLazy")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "lazy")) (EVar "omEmpty"))) (EBinOp "/=" (EVar "lazy") (EVar "expectedLazy"))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet")))) (EFieldAccess (EVar "candidate") "eagerOrder")) (EListLit (ELit (LString "global init: eager cycle / lazy partition"))) (EListLit (ELit (LString "global init: lazy partition")))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EBinOp ">=" (EFieldAccess (EVar "s") "dependencyRank") (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (arm (PCon "None") () (EVar "True"))))) (EMethodRef "sequence")) (EListLit (ELit (LString "global init: dependency order"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EMethodRef "sequence")) (ELit (LInt 0))) (EListLit))) (EListLit (ELit (LString "global init: source priority"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "candidate") "eagerOrder") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: lazy partition"))) (EListLit)))))))))))))))
