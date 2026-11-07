# META
source_lines=606
stages=DESUGAR,MARK
# SOURCE
import ir.core_ir.{
  CProgram(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  DeclFacts,
  isModuleMain,
  isNullaryMemo,
  originModule,
}
import backend.emit_support.{
  Mention(..),
  bindMentions,
  eagerCalleesMap,
  eagerReachMap,
  implMentions,
  taintSourceSet,
}
import ir.constructor_facts.{planConstructors}
import support.scc.{tarjanSCCs}
import support.symbol_encoding.{encodePair}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omFromNames, omKeys,
  omMapValues
}
import support.util.{reverseL, filterList, listLen, maxI}
import list.{mapWithIndex, zip}
import map as Q

-- `moduleOrder` is the initialisation order the typechecker carried
-- (`DeclFacts.factInitOrder`), one row per module in module order; with none
-- carried it is source order, grouped by declaring module.
public export data GlobalInitPlan = GlobalInitPlan {
  valueOrder : List String,
  eagerOrder : List String,
  moduleOrder : List ModuleInit,
}

public export data ModuleInit = ModuleInit {
  module : String,
  values : List String,
} deriving (Eq, Debug)

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
planGlobals (CProgram binds _ _ _ _ facts) lazy reach =
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
    moduleOrder = moduleOrderOf facts names,
  }

-- The carried order keeps only the values this program holds, because a reach
-- filter (`wasm_reach.wasmReachFilter`) drops values after the facts were
-- lowered.
moduleOrderOf : DeclFacts -> List String -> List ModuleInit
moduleOrderOf facts values = match facts.factInitOrder
  Some rows =>
    let present = omFromNames values omEmpty
    map
      ((m, names) => ModuleInit {
        module = m,
        values = filterList (n => omHasKey n present) names,
      })
      rows
  None => sourceModules facts (filterList (n => not (unplaced facts n)) values)

sourceModules : DeclFacts -> List String -> List ModuleInit
sourceModules facts names =
  let modules = map (originModule facts) names
  let owners = fold (m (n, mid) => omInsert n mid m) omEmpty (zip names modules)
  let grouped = sourceMembers owners names
  map
    (m => ModuleInit { module = m, values = lookup [] m grouped })
    (firstOccurrences modules omEmpty)

firstOccurrences : List String -> OrdMap Unit -> List String
firstOccurrences [] _ = []
firstOccurrences (n :: ns) seen =
  if omHasKey n seen then
    firstOccurrences ns seen
  else
    n :: firstOccurrences ns (omInsert n () seen)

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
priorityValid g facts cs0 rank0 stack0 = go cs0 rank0 stack0
  where
    go [] _ _ = True
    go (c :: cs) rank stack =
      let key = lookup 0 c g.sourceKeys
      let smaller = dropSmaller key stack
      let d = match omLookup c facts
        Some s => s.dependencyRank
        None => -1
      let valid = match smaller
        (_, earlier) :: _ => earlier <= d
        [] => True
      valid && go cs (rank + 1) ((key, rank) :: smaller)

export
validateGlobalInit : CProgram -> List String -> GlobalInitPlan -> List String
validateGlobalInit prog lazy candidate =
  let (CProgram binds _ _ _ _ _) = prog
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
      let sources = taintSourceSet (planConstructors prog).arities binds
      let facts = summaries g adj sources names ranks
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
        validateModuleOrder prog candidate.moduleOrder

-- The module order's own arms, each refusing with its first defect.  Only a
-- carried order is held to membership and dependency: an untyped program still
-- initialises through the lazy partition, so its arms wait in
-- `validateUntypedInit` until that partition goes.
validateModuleOrder : CProgram -> List ModuleInit -> List String
validateModuleOrder prog order =
  let (CProgram _ _ _ _ _ facts) = prog
  match facts.factInitOrder
    Some _ => firstDefect (typedArms prog order)
    None => contiguityDefects facts order

typedArms : CProgram -> List ModuleInit -> List (Unit -> List String)
typedArms prog order =
  let (CProgram binds _ _ impls _ facts) = prog
  let values = map nameOf (filterList isValue binds)
  let placed = flatMap (m => m.values) order
  let ranks = rankNames placed 0 omEmpty
  [
    () => placementDefects facts values placed,
    () => contiguityDefects facts order,
    () => dependencyDefects binds impls placed ranks,
  ]

-- The module-order arms for a program that carries no order: the typed arms,
-- then no value eagerly reaching itself or a value source order initialises
-- after it.  No emit path calls it yet.
export
validateUntypedInit : CProgram -> GlobalInitPlan -> List String
validateUntypedInit prog candidate =
  let (CProgram binds _ _ _ _ _) = prog
  let placed = flatMap (m => m.values) candidate.moduleOrder
  let ranks = rankNames placed 0 omEmpty
  firstDefect
    (typedArms prog candidate.moduleOrder
      ++ [() => untypedDefects binds placed ranks])

firstDefect : List (Unit -> List String) -> List String
firstDefect [] = []
firstDefect (arm :: rest) = match arm ()
  [] => firstDefect rest
  defect :: _ => [defect]

-- The values with no place in the module order, which the dependency arm
-- therefore treats as functions.  A `main` in any module is never initialised
-- (spec rule I4).  A nullary-memo CAF is forced where it is read, until the
-- hoist that makes it goes.
unplaced : DeclFacts -> String -> Bool
unplaced facts n = isModuleMain facts n || isNullaryMemo facts n

-- Membership: every Core value exactly once, except the unplaced ones, and
-- nothing else.
placementDefects : DeclFacts -> List String -> List String -> List String
placementDefects facts values placed =
  let valueSet = omFromNames values omEmpty
  let placedSet = omFromNames placed omEmpty
  map
      (n => "global init: `\{n}` is placed twice in the module order")
      (repeatedNames placed omEmpty)
    ++ map
      (n =>
        "global init: `\{n}` is placed in the module order but is not a Core value")
      (filterList (n => not (omHasKey n valueSet)) placed)
    ++ map
      (n => "global init: Core value `\{n}` has no place in the module order")
      (filterList
        (n => not (omHasKey n placedSet) && not (unplaced facts n))
        values)

repeatedNames : List String -> OrdMap Unit -> List String
repeatedNames [] _ = []
repeatedNames (n :: ns) seen =
  if omHasKey n seen then
    n :: repeatedNames ns seen
  else
    repeatedNames ns (omInsert n () seen)

-- Contiguity: each module has one row, and a row holds only its own module's
-- values.
contiguityDefects : DeclFacts -> List ModuleInit -> List String
contiguityDefects facts order =
  map
      (m => "global init: module `\{m}` is not contiguous in the module order")
      (repeatedNames (map (m => m.module) order) omEmpty)
    ++ flatMap
      (row =>
        map
          (n =>
            "global init: `\{n}` is placed in module `\{row.module}` but declared in `\{originModule facts n}`")
          (filterList (n => originModule facts n /= row.module) row.values))
      order

-- Dependency: a value that [v] may reach and that lies outside [v]'s may-reach
-- component precedes [v].  Within a component the typechecker's rule I3 keeps
-- every initialiser from reading a member, so any order there is safe.  Eager
-- reach is not enough here: it follows an under-saturated application into its
-- callee as if it ran.
dependencyDefects : List CBind ->
  List CImplEntry ->
  List String ->
  OrdMap Int ->
  List String
dependencyDefects binds impls placed ranks =
  let graph = mayReachGraph binds impls placed
  let g = components graph.nodes placed graph.adj
  let latest = latestReached g ranks
  filterMap
    (v =>
      let (rank, w) = lookup (-1, "") (owner g v) latest
      if rank >= lookup 0 v ranks then
        Some
          "global init: `\{v}` may reach `\{w}`, which the module order places after it"
      else
        None)
    placed

data MayReachGraph = MayReachGraph {
  nodes : List String,
  adj : OrdMap (List String),
}

-- The graph of what [roots] may reach: one node per top-level bind, per impl
-- entry and per method.  A method mention reaches the method's node, and the
-- method's node every impl entry of that method, so a mention costs one edge.
-- Impl entry and method node names hold a space, which no bind name can.  A
-- component holding a reached node is reached whole, so the components of this
-- subgraph are those of the whole program.
mayReachGraph : List CBind -> List CImplEntry -> List String -> MayReachGraph
mayReachGraph binds impls roots =
  let bindIndex = fold (m b => omInsert (nameOf b) b m) omEmpty binds
  let entries = mapWithIndex (i e => ("impl " ++ intToString i, e)) impls
  let entryIndex = fold (m (key, e) => omInsert key e m) omEmpty entries
  let methods =
    fold
      (m (key, CImplEntry method _ _ _) =>
        let node = "method " ++ method
        omInsert node (key :: lookup [] node m) m)
      omEmpty
      entries
  let targets mentions = filterMap (mentionTarget bindIndex methods) mentions
  let successors node = match omLookup node bindIndex
    Some b => targets (bindMentions b)
    None => match omLookup node entryIndex
      Some e => targets (implMentions e)
      None => lookup [] node methods
  reachFrom successors roots omEmpty []

reachFrom : (String -> List String) ->
  List String ->
  OrdMap (List String) ->
  List String ->
  MayReachGraph
reachFrom _ [] adj seen = MayReachGraph { nodes = reverseL seen, adj = adj }
reachFrom successors (n :: todo) adj seen =
  if omHasKey n adj then
    reachFrom successors todo adj seen
  else
    let out = successors n
    reachFrom successors (out ++ todo) (omInsert n out adj) (n :: seen)

-- A bare reference to a prelude function synthesized after mangling names its
-- `core`-mangled definition, as `wasm_reach.canonKey` resolves it.
mentionTarget : OrdMap a -> OrdMap (List String) -> Mention -> Option String
mentionTarget bindSet _ (MentionName x) =
  if omHasKey x bindSet then
    Some x
  else
    let mangled = encodePair "core" x
    if omHasKey mangled bindSet then Some mangled else None
mentionTarget _ methods (MentionMethod m) =
  let node = "method " ++ m
  if omHasKey node methods then Some node else None

-- For each component, the latest-placed value it may reach outside itself, as
-- (rank, name), folded in the order Tarjan emits components (dependencies
-- first).
latestReached : Components -> OrdMap Int -> OrdMap (Int, String)
latestReached g ranks =
  let own c =
    fold
      (best n => later best (lookup (-1) n ranks, n))
      (-1, "")
      (lookup [] c g.members)
  fold
    (acc c =>
      omInsert
        c
        (fold
          (best d => later (later best (own d)) (lookup (-1, "") d acc))
          (-1, "")
          (lookup [] c g.dependencies))
        acc)
    omEmpty
    g.ids

later : (Int, String) -> (Int, String) -> (Int, String)
later (r1, n1) (r2, n2) = if r2 > r1 then (r2, n2) else (r1, n1)

-- Untyped programs carry no rule I3, so eager reach must stay acyclic and
-- follow source order.
untypedDefects : List CBind -> List String -> OrdMap Int -> List String
untypedDefects binds placed ranks =
  let reach = eagerReachMap binds
  filterMap
    (v =>
      let rank = lookup 0 v ranks
      match filterList (w => lookup (-1) w ranks >= rank) (lookup [] v reach)
        w :: _ =>
          Some
            "global init: `\{v}` eagerly reaches `\{w}`, which source order does not initialise before it"
        [] => None)
    placed
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "DeclFacts" false) (mem "isModuleMain" false) (mem "isNullaryMemo" false) (mem "originModule" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "Mention" true) (mem "bindMentions" false) (mem "eagerCalleesMap" false) (mem "eagerReachMap" false) (mem "implMentions" false) (mem "taintSourceSet" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "planConstructors" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omKeys" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "maxI" false))))
(DUse false (UseGroup ("list") ((mem "mapWithIndex" false) (mem "zip" false))))
(DUse false (UseAlias ("map") "Q"))
(DData Public "GlobalInitPlan" () ((variant "GlobalInitPlan" (ConNamed (field "valueOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "moduleOrder" (TyApp (TyCon "List") (TyCon "ModuleInit")))))) ())
(DData Public "ModuleInit" () ((variant "ModuleInit" (ConNamed (field "module" (TyCon "String")) (field "values" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DImpl true "Eq" ((TyCon "ModuleInit")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ModuleInit" ((rf "module" (PVar "__a0")) (rf "values" (PVar "__a1"))) false) (PRec "ModuleInit" ((rf "module" (PVar "__b0")) (rf "values" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "ModuleInit")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ModuleInit" ((rf "module" (PVar "__a0")) (rf "values" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ModuleInit {")) (ELit (LString " module = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", values = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString " }"))))))))
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
(DFunDef false "planGlobals" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild (PVar "facts")) (PVar "lazy") (PVar "reach")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "universe") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "universe")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "reach")))) (EVar "m")))) (EVar "omEmpty")) (EVar "names"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "order") (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EApp (EVar "queueState") (EVar "g"))) (EListLit))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "lazy")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "GlobalInitPlan" ((fa "valueOrder" (EVar "order")) (fa "eagerOrder" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EVar "order"))) (fa "moduleOrder" (EApp (EApp (EVar "moduleOrderOf") (EVar "facts")) (EVar "names"))))))))
(DTypeSig false "moduleOrderOf" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleInit")))))
(DFunDef false "moduleOrderOf" ((PVar "facts") (PVar "values")) (EMatch (EFieldAccess (EVar "facts") "factInitOrder") (arm (PCon "Some" (PVar "rows")) () (EBlock (DoLet false false (PVar "present") (EApp (EApp (EVar "omFromNames") (EVar "values")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "m") (PVar "names"))) (ERecordCreate "ModuleInit" ((fa "module" (EVar "m")) (fa "values" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "present")))) (EVar "names"))))))) (EVar "rows"))))) (arm (PCon "None") () (EApp (EApp (EVar "sourceModules") (EVar "facts")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "unplaced") (EVar "facts")) (EVar "n"))))) (EVar "values"))))))
(DTypeSig false "sourceModules" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleInit")))))
(DFunDef false "sourceModules" ((PVar "facts") (PVar "names")) (EBlock (DoLet false false (PVar "modules") (EApp (EApp (EVar "map") (EApp (EVar "originModule") (EVar "facts"))) (EVar "names"))) (DoLet false false (PVar "owners") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "mid"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "mid")) (EVar "m")))) (EVar "omEmpty")) (EApp (EApp (EVar "zip") (EVar "names")) (EVar "modules")))) (DoLet false false (PVar "grouped") (EApp (EApp (EVar "sourceMembers") (EVar "owners")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ERecordCreate "ModuleInit" ((fa "module" (EVar "m")) (fa "values" (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "m")) (EVar "grouped"))))))) (EApp (EApp (EVar "firstOccurrences") (EVar "modules")) (EVar "omEmpty"))))))
(DTypeSig false "firstOccurrences" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "firstOccurrences" ((PList) PWild) (EListLit))
(DFunDef false "firstOccurrences" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "firstOccurrences") (EVar "ns")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "firstOccurrences") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))))))
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
(DFunDef false "priorityValid" ((PVar "g") (PVar "facts") (PVar "cs0") (PVar "rank0") (PVar "stack0")) (ELetGroup ((lgb "go" (clause ((PList) PWild PWild) (EVar "True")) (clause ((PCons (PVar "c") (PVar "cs")) (PVar "rank") (PVar "stack")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "stack"))) (DoLet false false (PVar "d") (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "dependencyRank")) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoLet false false (PVar "valid") (EMatch (EVar "smaller") (arm (PCons (PTuple PWild (PVar "earlier")) PWild) () (EBinOp "<=" (EVar "earlier") (EVar "d"))) (arm (PList) () (EVar "True")))) (DoExpr (EBinOp "&&" (EVar "valid") (EApp (EApp (EApp (EVar "go") (EVar "cs")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "key") (EVar "rank")) (EVar "smaller"))))))))) (EApp (EApp (EApp (EVar "go") (EVar "cs0")) (EVar "rank0")) (EVar "stack0"))))
(DTypeSig true "validateGlobalInit" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateGlobalInit" ((PVar "prog") (PVar "lazy") (PVar "candidate")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (EVar "prog")) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "nameOf")) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "names")) (EVar "omEmpty"))) (EListLit (ELit (LString "global init: duplicate binding"))) (EIf (EBinOp "||" (EApp (EApp (EVar "any") (EVar "malformedValue")) (EVar "binds")) (EApp (EVar "not") (EApp (EApp (EVar "sameMembers") (EVar "values")) (EFieldAccess (EVar "candidate") "valueOrder")))) (EListLit (ELit (LString "global init: membership"))) (EBlock (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "values")) (EVar "adj"))) (DoLet false false (PVar "sequence") (EApp (EApp (EVar "componentSequence") (EVar "g")) (EFieldAccess (EVar "candidate") "valueOrder"))) (DoLet false false (PVar "contiguous") (EApp (EApp (EVar "unique") (EVar "sequence")) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EIf (EVar "contiguous") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))) (EVar "sequence")) (EListLit))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EVar "contiguous")) (EBinOp "/=" (EVar "members") (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: component order"))) (EBlock (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "sequence")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "sources") (EApp (EApp (EVar "taintSourceSet") (EFieldAccess (EApp (EVar "planConstructors") (EVar "prog")) "arities")) (EVar "binds"))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EApp (EVar "summaries") (EVar "g")) (EVar "adj")) (EVar "sources")) (EVar "names")) (EVar "ranks"))) (DoLet false true (PVar "isLazy") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "tainted")) (arm (PCon "None") () (EVar "False"))))) (DoLet false false (PVar "expectedLazy") (EApp (EApp (EVar "filterList") (EVar "isLazy")) (EVar "values"))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "expectedLazy")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "lazy")) (EVar "omEmpty"))) (EBinOp "/=" (EVar "lazy") (EVar "expectedLazy"))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet")))) (EFieldAccess (EVar "candidate") "eagerOrder")) (EListLit (ELit (LString "global init: eager cycle / lazy partition"))) (EListLit (ELit (LString "global init: lazy partition")))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EBinOp ">=" (EFieldAccess (EVar "s") "dependencyRank") (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (arm (PCon "None") () (EVar "True"))))) (EVar "sequence")) (EListLit (ELit (LString "global init: dependency order"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EVar "sequence")) (ELit (LInt 0))) (EListLit))) (EListLit (ELit (LString "global init: source priority"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "candidate") "eagerOrder") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: lazy partition"))) (EApp (EApp (EVar "validateModuleOrder") (EVar "prog")) (EFieldAccess (EVar "candidate") "moduleOrder"))))))))))))))))
(DTypeSig false "validateModuleOrder" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateModuleOrder" ((PVar "prog") (PVar "order")) (EBlock (DoLet false false (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")) (EVar "prog")) (DoExpr (EMatch (EFieldAccess (EVar "facts") "factInitOrder") (arm (PCon "Some" PWild) () (EApp (EVar "firstDefect") (EApp (EApp (EVar "typedArms") (EVar "prog")) (EVar "order")))) (arm (PCon "None") () (EApp (EApp (EVar "contiguityDefects") (EVar "facts")) (EVar "order")))))))
(DTypeSig false "typedArms" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "typedArms" ((PVar "prog") (PVar "order")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "values") (EApp (EApp (EVar "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "placed") (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "values"))) (EVar "order"))) (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "placed")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EListLit (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "placementDefects") (EVar "facts")) (EVar "values")) (EVar "placed"))) (ELam ((PLit LUnit)) (EApp (EApp (EVar "contiguityDefects") (EVar "facts")) (EVar "order"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EApp (EVar "dependencyDefects") (EVar "binds")) (EVar "impls")) (EVar "placed")) (EVar "ranks")))))))
(DTypeSig true "validateUntypedInit" (TyFun (TyCon "CProgram") (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateUntypedInit" ((PVar "prog") (PVar "candidate")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (EVar "prog")) (DoLet false false (PVar "placed") (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "values"))) (EFieldAccess (EVar "candidate") "moduleOrder"))) (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "placed")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "firstDefect") (EBinOp "++" (EApp (EApp (EVar "typedArms") (EVar "prog")) (EFieldAccess (EVar "candidate") "moduleOrder")) (EListLit (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "untypedDefects") (EVar "binds")) (EVar "placed")) (EVar "ranks")))))))))
(DTypeSig false "firstDefect" (TyFun (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "firstDefect" ((PList)) (EListLit))
(DFunDef false "firstDefect" ((PCons (PVar "arm") (PVar "rest"))) (EMatch (EApp (EVar "arm") (ELit LUnit)) (arm (PList) () (EApp (EVar "firstDefect") (EVar "rest"))) (arm (PCons (PVar "defect") PWild) () (EListLit (EVar "defect")))))
(DTypeSig false "unplaced" (TyFun (TyCon "DeclFacts") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "unplaced" ((PVar "facts") (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "isModuleMain") (EVar "facts")) (EVar "n")) (EApp (EApp (EVar "isNullaryMemo") (EVar "facts")) (EVar "n"))))
(DTypeSig false "placementDefects" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "placementDefects" ((PVar "facts") (PVar "values") (PVar "placed")) (EBlock (DoLet false false (PVar "valueSet") (EApp (EApp (EVar "omFromNames") (EVar "values")) (EVar "omEmpty"))) (DoLet false false (PVar "placedSet") (EApp (EApp (EVar "omFromNames") (EVar "placed")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed twice in the module order"))))) (EApp (EApp (EVar "repeatedNames") (EVar "placed")) (EVar "omEmpty"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed in the module order but is not a Core value"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "valueSet"))))) (EVar "placed")))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: Core value `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` has no place in the module order"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "placedSet"))) (EApp (EVar "not") (EApp (EApp (EVar "unplaced") (EVar "facts")) (EVar "n")))))) (EVar "values")))))))
(DTypeSig false "repeatedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatedNames" ((PList) PWild) (EListLit))
(DFunDef false "repeatedNames" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "repeatedNames") (EVar "ns")) (EVar "seen"))) (EApp (EApp (EVar "repeatedNames") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig false "contiguityDefects" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "contiguityDefects" ((PVar "facts") (PVar "order")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: module `")) (EApp (EVar "$core.display") (EVar "m"))) (ELit (LString "` is not contiguous in the module order"))))) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "module"))) (EVar "order"))) (EVar "omEmpty"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "row")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed in module `"))) (EApp (EVar "$core.display") (EFieldAccess (EVar "row") "module"))) (ELit (LString "` but declared in `"))) (EApp (EVar "$core.display") (EApp (EApp (EVar "originModule") (EVar "facts")) (EVar "n")))) (ELit (LString "`"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "/=" (EApp (EApp (EVar "originModule") (EVar "facts")) (EVar "n")) (EFieldAccess (EVar "row") "module")))) (EFieldAccess (EVar "row") "values"))))) (EVar "order"))))
(DTypeSig false "dependencyDefects" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "dependencyDefects" ((PVar "binds") (PVar "impls") (PVar "placed") (PVar "ranks")) (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "mayReachGraph") (EVar "binds")) (EVar "impls")) (EVar "placed"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EFieldAccess (EVar "graph") "nodes")) (EVar "placed")) (EFieldAccess (EVar "graph") "adj"))) (DoLet false false (PVar "latest") (EApp (EApp (EVar "latestReached") (EVar "g")) (EVar "ranks"))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PVar "v")) (EBlock (DoLet false false (PTuple (PVar "rank") (PVar "w")) (EApp (EApp (EApp (EVar "lookup") (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EVar "owner") (EVar "g")) (EVar "v"))) (EVar "latest"))) (DoExpr (EIf (EBinOp ">=" (EVar "rank") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "v")) (EVar "ranks"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` may reach `"))) (EApp (EVar "$core.display") (EVar "w"))) (ELit (LString "`, which the module order places after it")))) (EVar "None")))))) (EVar "placed")))))
(DData Private "MayReachGraph" () ((variant "MayReachGraph" (ConNamed (field "nodes" (TyApp (TyCon "List") (TyCon "String"))) (field "adj" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "mayReachGraph" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "MayReachGraph")))))
(DFunDef false "mayReachGraph" ((PVar "binds") (PVar "impls") (PVar "roots")) (EBlock (DoLet false false (PVar "bindIndex") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "b")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "nameOf") (EVar "b"))) (EVar "b")) (EVar "m")))) (EVar "omEmpty")) (EVar "binds"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "e")) (ETuple (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "intToString") (EVar "i"))) (EVar "e")))) (EVar "impls"))) (DoLet false false (PVar "entryIndex") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "key") (PVar "e"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "e")) (EVar "m")))) (EVar "omEmpty")) (EVar "entries"))) (DoLet false false (PVar "methods") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "key") (PCon "CImplEntry" (PVar "method") PWild PWild PWild))) (EBlock (DoLet false false (PVar "node") (EBinOp "++" (ELit (LString "method ")) (EVar "method"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "node")) (EBinOp "::" (EVar "key") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "node")) (EVar "m")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "entries"))) (DoLet false true (PVar "targets") (ELam ((PVar "mentions")) (EApp (EApp (EVar "filterMap") (EApp (EApp (EVar "mentionTarget") (EVar "bindIndex")) (EVar "methods"))) (EVar "mentions")))) (DoLet false true (PVar "successors") (ELam ((PVar "node")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "node")) (EVar "bindIndex")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "targets") (EApp (EVar "bindMentions") (EVar "b")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "node")) (EVar "entryIndex")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "targets") (EApp (EVar "implMentions") (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "node")) (EVar "methods")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EVar "roots")) (EVar "omEmpty")) (EListLit)))))
(DTypeSig false "reachFrom" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "MayReachGraph"))))))
(DFunDef false "reachFrom" (PWild (PList) (PVar "adj") (PVar "seen")) (ERecordCreate "MayReachGraph" ((fa "nodes" (EApp (EVar "reverseL") (EVar "seen"))) (fa "adj" (EVar "adj")))))
(DFunDef false "reachFrom" ((PVar "successors") (PCons (PVar "n") (PVar "todo")) (PVar "adj") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "adj")) (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EVar "todo")) (EVar "adj")) (EVar "seen")) (EBlock (DoLet false false (PVar "out") (EApp (EVar "successors") (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EBinOp "++" (EVar "out") (EVar "todo"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "out")) (EVar "adj"))) (EBinOp "::" (EVar "n") (EVar "seen")))))))
(DTypeSig false "mentionTarget" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Mention") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mentionTarget" ((PVar "bindSet") PWild (PCon "MentionName" (PVar "x"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "bindSet")) (EApp (EVar "Some") (EVar "x")) (EBlock (DoLet false false (PVar "mangled") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "x"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "mangled")) (EVar "bindSet")) (EApp (EVar "Some") (EVar "mangled")) (EVar "None"))))))
(DFunDef false "mentionTarget" (PWild (PVar "methods") (PCon "MentionMethod" (PVar "m"))) (EBlock (DoLet false false (PVar "node") (EBinOp "++" (ELit (LString "method ")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "node")) (EVar "methods")) (EApp (EVar "Some") (EVar "node")) (EVar "None")))))
(DTypeSig false "latestReached" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "latestReached" ((PVar "g") (PVar "ranks")) (EBlock (DoLet false true (PVar "own") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "best") (PVar "n")) (EApp (EApp (EVar "later") (EVar "best")) (ETuple (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "n")) (EVar "ranks")) (EVar "n"))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members"))))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "c")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "best") (PVar "d")) (EApp (EApp (EVar "later") (EApp (EApp (EVar "later") (EVar "best")) (EApp (EVar "own") (EVar "d")))) (EApp (EApp (EApp (EVar "lookup") (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EVar "d")) (EVar "acc"))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies")))) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EVar "g") "ids")))))
(DTypeSig false "later" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "later" ((PTuple (PVar "r1") (PVar "n1")) (PTuple (PVar "r2") (PVar "n2"))) (EIf (EBinOp ">" (EVar "r2") (EVar "r1")) (ETuple (EVar "r2") (EVar "n2")) (ETuple (EVar "r1") (EVar "n1"))))
(DTypeSig false "untypedDefects" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "untypedDefects" ((PVar "binds") (PVar "placed") (PVar "ranks")) (EBlock (DoLet false false (PVar "reach") (EApp (EVar "eagerReachMap") (EVar "binds"))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PVar "v")) (EBlock (DoLet false false (PVar "rank") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "v")) (EVar "ranks"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "w")) (EBinOp ">=" (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "w")) (EVar "ranks")) (EVar "rank")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "v")) (EVar "reach"))) (arm (PCons (PVar "w") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` eagerly reaches `"))) (EApp (EVar "$core.display") (EVar "w"))) (ELit (LString "`, which source order does not initialise before it"))))) (arm (PList) () (EVar "None"))))))) (EVar "placed")))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "DeclFacts" false) (mem "isModuleMain" false) (mem "isNullaryMemo" false) (mem "originModule" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "Mention" true) (mem "bindMentions" false) (mem "eagerCalleesMap" false) (mem "eagerReachMap" false) (mem "implMentions" false) (mem "taintSourceSet" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "planConstructors" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omKeys" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "maxI" false))))
(DUse false (UseGroup ("list") ((mem "mapWithIndex" false) (mem "zip" false))))
(DUse false (UseAlias ("map") "Q"))
(DData Public "GlobalInitPlan" () ((variant "GlobalInitPlan" (ConNamed (field "valueOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerOrder" (TyApp (TyCon "List") (TyCon "String"))) (field "moduleOrder" (TyApp (TyCon "List") (TyCon "ModuleInit")))))) ())
(DData Public "ModuleInit" () ((variant "ModuleInit" (ConNamed (field "module" (TyCon "String")) (field "values" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DImpl true "Eq" ((TyCon "ModuleInit")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ModuleInit" ((rf "module" (PVar "__a0")) (rf "values" (PVar "__a1"))) false) (PRec "ModuleInit" ((rf "module" (PVar "__b0")) (rf "values" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "ModuleInit")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ModuleInit" ((rf "module" (PVar "__a0")) (rf "values" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ModuleInit {")) (ELit (LString " module = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", values = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString " }"))))))))
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
(DFunDef false "planGlobals" ((PCon "CProgram" (PVar "binds") PWild PWild PWild PWild (PVar "facts")) (PVar "lazy") (PVar "reach")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "universe") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "universe")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "n")) (EVar "reach")))) (EVar "m")))) (EVar "omEmpty")) (EVar "names"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "names")) (EVar "adj"))) (DoLet false false (PVar "order") (EApp (EApp (EApp (EVar "queueOrder") (EVar "g")) (EApp (EVar "queueState") (EVar "g"))) (EListLit))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "lazy")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "GlobalInitPlan" ((fa "valueOrder" (EVar "order")) (fa "eagerOrder" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EVar "order"))) (fa "moduleOrder" (EApp (EApp (EVar "moduleOrderOf") (EVar "facts")) (EVar "names"))))))))
(DTypeSig false "moduleOrderOf" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleInit")))))
(DFunDef false "moduleOrderOf" ((PVar "facts") (PVar "values")) (EMatch (EFieldAccess (EVar "facts") "factInitOrder") (arm (PCon "Some" (PVar "rows")) () (EBlock (DoLet false false (PVar "present") (EApp (EApp (EVar "omFromNames") (EVar "values")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "m") (PVar "names"))) (ERecordCreate "ModuleInit" ((fa "module" (EVar "m")) (fa "values" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "present")))) (EVar "names"))))))) (EVar "rows"))))) (arm (PCon "None") () (EApp (EApp (EVar "sourceModules") (EVar "facts")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "unplaced") (EVar "facts")) (EVar "n"))))) (EVar "values"))))))
(DTypeSig false "sourceModules" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleInit")))))
(DFunDef false "sourceModules" ((PVar "facts") (PVar "names")) (EBlock (DoLet false false (PVar "modules") (EApp (EApp (EMethodRef "map") (EApp (EVar "originModule") (EVar "facts"))) (EVar "names"))) (DoLet false false (PVar "owners") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "mid"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "mid")) (EVar "m")))) (EVar "omEmpty")) (EApp (EApp (EVar "zip") (EVar "names")) (EVar "modules")))) (DoLet false false (PVar "grouped") (EApp (EApp (EVar "sourceMembers") (EVar "owners")) (EVar "names"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ERecordCreate "ModuleInit" ((fa "module" (EVar "m")) (fa "values" (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "m")) (EVar "grouped"))))))) (EApp (EApp (EVar "firstOccurrences") (EVar "modules")) (EVar "omEmpty"))))))
(DTypeSig false "firstOccurrences" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "firstOccurrences" ((PList) PWild) (EListLit))
(DFunDef false "firstOccurrences" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "firstOccurrences") (EVar "ns")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "firstOccurrences") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))))))
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
(DFunDef false "priorityValid" ((PVar "g") (PVar "facts") (PVar "cs0") (PVar "rank0") (PVar "stack0")) (ELetGroup ((lgb "go" (clause ((PList) PWild PWild) (EVar "True")) (clause ((PCons (PVar "c") (PVar "cs")) (PVar "rank") (PVar "stack")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "c")) (EFieldAccess (EVar "g") "sourceKeys"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "dropSmaller") (EVar "key")) (EVar "stack"))) (DoLet false false (PVar "d") (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "dependencyRank")) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoLet false false (PVar "valid") (EMatch (EVar "smaller") (arm (PCons (PTuple PWild (PVar "earlier")) PWild) () (EBinOp "<=" (EVar "earlier") (EVar "d"))) (arm (PList) () (EVar "True")))) (DoExpr (EBinOp "&&" (EVar "valid") (EApp (EApp (EApp (EVar "go") (EVar "cs")) (EBinOp "+" (EVar "rank") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "key") (EVar "rank")) (EVar "smaller"))))))))) (EApp (EApp (EApp (EVar "go") (EVar "cs0")) (EVar "rank0")) (EVar "stack0"))))
(DTypeSig true "validateGlobalInit" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateGlobalInit" ((PVar "prog") (PVar "lazy") (PVar "candidate")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (EVar "prog")) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "names")) (EVar "omEmpty"))) (EListLit (ELit (LString "global init: duplicate binding"))) (EIf (EBinOp "||" (EApp (EApp (EDictApp "any") (EVar "malformedValue")) (EVar "binds")) (EApp (EVar "not") (EApp (EApp (EVar "sameMembers") (EVar "values")) (EFieldAccess (EVar "candidate") "valueOrder")))) (EListLit (ELit (LString "global init: membership"))) (EBlock (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EVar "names")) (EVar "values")) (EVar "adj"))) (DoLet false false (PVar "sequence") (EApp (EApp (EVar "componentSequence") (EVar "g")) (EFieldAccess (EVar "candidate") "valueOrder"))) (DoLet false false (PVar "contiguous") (EApp (EApp (EVar "unique") (EMethodRef "sequence")) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EIf (EVar "contiguous") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members")))) (EMethodRef "sequence")) (EListLit))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EVar "contiguous")) (EBinOp "/=" (EVar "members") (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: component order"))) (EBlock (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EMethodRef "sequence")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "sources") (EApp (EApp (EVar "taintSourceSet") (EFieldAccess (EApp (EVar "planConstructors") (EVar "prog")) "arities")) (EVar "binds"))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EApp (EVar "summaries") (EVar "g")) (EVar "adj")) (EVar "sources")) (EVar "names")) (EVar "ranks"))) (DoLet false true (PVar "isLazy") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "owner") (EVar "g")) (EVar "n"))) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EFieldAccess (EVar "s") "tainted")) (arm (PCon "None") () (EVar "False"))))) (DoLet false false (PVar "expectedLazy") (EApp (EApp (EVar "filterList") (EVar "isLazy")) (EVar "values"))) (DoLet false false (PVar "lazySet") (EApp (EApp (EVar "omFromNames") (EVar "expectedLazy")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "unique") (EVar "lazy")) (EVar "omEmpty"))) (EBinOp "/=" (EVar "lazy") (EVar "expectedLazy"))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet")))) (EFieldAccess (EVar "candidate") "eagerOrder")) (EListLit (ELit (LString "global init: eager cycle / lazy partition"))) (EListLit (ELit (LString "global init: lazy partition")))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "facts")) (arm (PCon "Some" (PVar "s")) () (EBinOp ">=" (EFieldAccess (EVar "s") "dependencyRank") (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "c")) (EVar "ranks")))) (arm (PCon "None") () (EVar "True"))))) (EMethodRef "sequence")) (EListLit (ELit (LString "global init: dependency order"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "priorityValid") (EVar "g")) (EVar "facts")) (EMethodRef "sequence")) (ELit (LInt 0))) (EListLit))) (EListLit (ELit (LString "global init: source priority"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "candidate") "eagerOrder") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "lazySet"))))) (EFieldAccess (EVar "candidate") "valueOrder"))) (EListLit (ELit (LString "global init: lazy partition"))) (EApp (EApp (EVar "validateModuleOrder") (EVar "prog")) (EFieldAccess (EVar "candidate") "moduleOrder"))))))))))))))))
(DTypeSig false "validateModuleOrder" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateModuleOrder" ((PVar "prog") (PVar "order")) (EBlock (DoLet false false (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")) (EVar "prog")) (DoExpr (EMatch (EFieldAccess (EVar "facts") "factInitOrder") (arm (PCon "Some" PWild) () (EApp (EVar "firstDefect") (EApp (EApp (EVar "typedArms") (EVar "prog")) (EVar "order")))) (arm (PCon "None") () (EApp (EApp (EVar "contiguityDefects") (EVar "facts")) (EVar "order")))))))
(DTypeSig false "typedArms" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "typedArms" ((PVar "prog") (PVar "order")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "map") (EVar "nameOf")) (EApp (EApp (EVar "filterList") (EVar "isValue")) (EVar "binds")))) (DoLet false false (PVar "placed") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "values"))) (EVar "order"))) (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "placed")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EListLit (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "placementDefects") (EVar "facts")) (EVar "values")) (EVar "placed"))) (ELam ((PLit LUnit)) (EApp (EApp (EVar "contiguityDefects") (EVar "facts")) (EVar "order"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EApp (EVar "dependencyDefects") (EVar "binds")) (EVar "impls")) (EVar "placed")) (EVar "ranks")))))))
(DTypeSig true "validateUntypedInit" (TyFun (TyCon "CProgram") (TyFun (TyCon "GlobalInitPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateUntypedInit" ((PVar "prog") (PVar "candidate")) (EBlock (DoLet false false (PCon "CProgram" (PVar "binds") PWild PWild PWild PWild PWild) (EVar "prog")) (DoLet false false (PVar "placed") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "values"))) (EFieldAccess (EVar "candidate") "moduleOrder"))) (DoLet false false (PVar "ranks") (EApp (EApp (EApp (EVar "rankNames") (EVar "placed")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "firstDefect") (EBinOp "++" (EApp (EApp (EVar "typedArms") (EVar "prog")) (EFieldAccess (EVar "candidate") "moduleOrder")) (EListLit (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "untypedDefects") (EVar "binds")) (EVar "placed")) (EVar "ranks")))))))))
(DTypeSig false "firstDefect" (TyFun (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "firstDefect" ((PList)) (EListLit))
(DFunDef false "firstDefect" ((PCons (PVar "arm") (PVar "rest"))) (EMatch (EApp (EVar "arm") (ELit LUnit)) (arm (PList) () (EApp (EVar "firstDefect") (EVar "rest"))) (arm (PCons (PVar "defect") PWild) () (EListLit (EVar "defect")))))
(DTypeSig false "unplaced" (TyFun (TyCon "DeclFacts") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "unplaced" ((PVar "facts") (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "isModuleMain") (EVar "facts")) (EVar "n")) (EApp (EApp (EVar "isNullaryMemo") (EVar "facts")) (EVar "n"))))
(DTypeSig false "placementDefects" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "placementDefects" ((PVar "facts") (PVar "values") (PVar "placed")) (EBlock (DoLet false false (PVar "valueSet") (EApp (EApp (EVar "omFromNames") (EVar "values")) (EVar "omEmpty"))) (DoLet false false (PVar "placedSet") (EApp (EApp (EVar "omFromNames") (EVar "placed")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed twice in the module order"))))) (EApp (EApp (EVar "repeatedNames") (EVar "placed")) (EVar "omEmpty"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed in the module order but is not a Core value"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "valueSet"))))) (EVar "placed")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: Core value `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` has no place in the module order"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "placedSet"))) (EApp (EVar "not") (EApp (EApp (EVar "unplaced") (EVar "facts")) (EVar "n")))))) (EVar "values")))))))
(DTypeSig false "repeatedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatedNames" ((PList) PWild) (EListLit))
(DFunDef false "repeatedNames" ((PCons (PVar "n") (PVar "ns")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "repeatedNames") (EVar "ns")) (EVar "seen"))) (EApp (EApp (EVar "repeatedNames") (EVar "ns")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig false "contiguityDefects" (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "List") (TyCon "ModuleInit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "contiguityDefects" ((PVar "facts") (PVar "order")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "global init: module `")) (EApp (EVar "$core.display") (EVar "m"))) (ELit (LString "` is not contiguous in the module order"))))) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "module"))) (EVar "order"))) (EVar "omEmpty"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "row")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString "` is placed in module `"))) (EApp (EVar "$core.display") (EFieldAccess (EVar "row") "module"))) (ELit (LString "` but declared in `"))) (EApp (EVar "$core.display") (EApp (EApp (EVar "originModule") (EVar "facts")) (EVar "n")))) (ELit (LString "`"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "/=" (EApp (EApp (EVar "originModule") (EVar "facts")) (EVar "n")) (EFieldAccess (EVar "row") "module")))) (EFieldAccess (EVar "row") "values"))))) (EVar "order"))))
(DTypeSig false "dependencyDefects" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "dependencyDefects" ((PVar "binds") (PVar "impls") (PVar "placed") (PVar "ranks")) (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "mayReachGraph") (EVar "binds")) (EVar "impls")) (EVar "placed"))) (DoLet false false (PVar "g") (EApp (EApp (EApp (EVar "components") (EFieldAccess (EVar "graph") "nodes")) (EVar "placed")) (EFieldAccess (EVar "graph") "adj"))) (DoLet false false (PVar "latest") (EApp (EApp (EVar "latestReached") (EVar "g")) (EVar "ranks"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "v")) (EBlock (DoLet false false (PTuple (PVar "rank") (PVar "w")) (EApp (EApp (EApp (EVar "lookup") (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EVar "owner") (EVar "g")) (EVar "v"))) (EVar "latest"))) (DoExpr (EIf (EBinOp ">=" (EVar "rank") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "v")) (EVar "ranks"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` may reach `"))) (EApp (EVar "$core.display") (EVar "w"))) (ELit (LString "`, which the module order places after it")))) (EVar "None")))))) (EVar "placed")))))
(DData Private "MayReachGraph" () ((variant "MayReachGraph" (ConNamed (field "nodes" (TyApp (TyCon "List") (TyCon "String"))) (field "adj" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig false "mayReachGraph" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "MayReachGraph")))))
(DFunDef false "mayReachGraph" ((PVar "binds") (PVar "impls") (PVar "roots")) (EBlock (DoLet false false (PVar "bindIndex") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "b")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "nameOf") (EVar "b"))) (EVar "b")) (EVar "m")))) (EVar "omEmpty")) (EVar "binds"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "e")) (ETuple (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "intToString") (EVar "i"))) (EVar "e")))) (EVar "impls"))) (DoLet false false (PVar "entryIndex") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "key") (PVar "e"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "e")) (EVar "m")))) (EVar "omEmpty")) (EVar "entries"))) (DoLet false false (PVar "methods") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "key") (PCon "CImplEntry" (PVar "method") PWild PWild PWild))) (EBlock (DoLet false false (PVar "node") (EBinOp "++" (ELit (LString "method ")) (EVar "method"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "node")) (EBinOp "::" (EVar "key") (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "node")) (EVar "m")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "entries"))) (DoLet false true (PVar "targets") (ELam ((PVar "mentions")) (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EVar "mentionTarget") (EVar "bindIndex")) (EVar "methods"))) (EVar "mentions")))) (DoLet false true (PVar "successors") (ELam ((PVar "node")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "node")) (EVar "bindIndex")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "targets") (EApp (EVar "bindMentions") (EVar "b")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "node")) (EVar "entryIndex")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "targets") (EApp (EVar "implMentions") (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "node")) (EVar "methods")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EVar "roots")) (EVar "omEmpty")) (EListLit)))))
(DTypeSig false "reachFrom" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "MayReachGraph"))))))
(DFunDef false "reachFrom" (PWild (PList) (PVar "adj") (PVar "seen")) (ERecordCreate "MayReachGraph" ((fa "nodes" (EApp (EVar "reverseL") (EVar "seen"))) (fa "adj" (EVar "adj")))))
(DFunDef false "reachFrom" ((PVar "successors") (PCons (PVar "n") (PVar "todo")) (PVar "adj") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "adj")) (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EVar "todo")) (EVar "adj")) (EVar "seen")) (EBlock (DoLet false false (PVar "out") (EApp (EVar "successors") (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reachFrom") (EVar "successors")) (EBinOp "++" (EVar "out") (EVar "todo"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "out")) (EVar "adj"))) (EBinOp "::" (EVar "n") (EVar "seen")))))))
(DTypeSig false "mentionTarget" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Mention") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mentionTarget" ((PVar "bindSet") PWild (PCon "MentionName" (PVar "x"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "bindSet")) (EApp (EVar "Some") (EVar "x")) (EBlock (DoLet false false (PVar "mangled") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "x"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "mangled")) (EVar "bindSet")) (EApp (EVar "Some") (EVar "mangled")) (EVar "None"))))))
(DFunDef false "mentionTarget" (PWild (PVar "methods") (PCon "MentionMethod" (PVar "m"))) (EBlock (DoLet false false (PVar "node") (EBinOp "++" (ELit (LString "method ")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "node")) (EVar "methods")) (EApp (EVar "Some") (EVar "node")) (EVar "None")))))
(DTypeSig false "latestReached" (TyFun (TyCon "Components") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "latestReached" ((PVar "g") (PVar "ranks")) (EBlock (DoLet false true (PVar "own") (ELam ((PVar "c")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "best") (PVar "n")) (EApp (EApp (EVar "later") (EVar "best")) (ETuple (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "n")) (EVar "ranks")) (EVar "n"))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "members"))))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "c")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "best") (PVar "d")) (EApp (EApp (EVar "later") (EApp (EApp (EVar "later") (EVar "best")) (EApp (EVar "own") (EVar "d")))) (EApp (EApp (EApp (EVar "lookup") (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EVar "d")) (EVar "acc"))))) (ETuple (EUnOp "-" (ELit (LInt 1))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "c")) (EFieldAccess (EVar "g") "dependencies")))) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EVar "g") "ids")))))
(DTypeSig false "later" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "later" ((PTuple (PVar "r1") (PVar "n1")) (PTuple (PVar "r2") (PVar "n2"))) (EIf (EBinOp ">" (EVar "r2") (EVar "r1")) (ETuple (EVar "r2") (EVar "n2")) (ETuple (EVar "r1") (EVar "n1"))))
(DTypeSig false "untypedDefects" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "untypedDefects" ((PVar "binds") (PVar "placed") (PVar "ranks")) (EBlock (DoLet false false (PVar "reach") (EApp (EVar "eagerReachMap") (EVar "binds"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "v")) (EBlock (DoLet false false (PVar "rank") (EApp (EApp (EApp (EVar "lookup") (ELit (LInt 0))) (EVar "v")) (EVar "ranks"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "w")) (EBinOp ">=" (EApp (EApp (EApp (EVar "lookup") (EUnOp "-" (ELit (LInt 1)))) (EVar "w")) (EVar "ranks")) (EVar "rank")))) (EApp (EApp (EApp (EVar "lookup") (EListLit)) (EVar "v")) (EVar "reach"))) (arm (PCons (PVar "w") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "global init: `")) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` eagerly reaches `"))) (EApp (EVar "$core.display") (EVar "w"))) (ELit (LString "`, which source order does not initialise before it"))))) (arm (PList) () (EVar "None"))))))) (EVar "placed")))))
