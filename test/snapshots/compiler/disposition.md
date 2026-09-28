# META
source_lines=294
stages=DESUGAR,MARK
# SOURCE
-- The whole-graph per-method disposition table (#1112 A-3, #1403 X-E's future
-- input): for every accepted instance, whether each method of its interface is
-- SUPPLIED by the impl or INHERITED from the interface's default body.  No
-- method-less slot is ever represented here — an impl that omits a required
-- method with no default is rejected upstream (M1), never given an `Absent` row.
--
-- Depends only on `types.repr`'s and `frontend.ast`'s identity types, so
-- `compiler/ir/*`, `compiler/eval/*` and `compiler/backend/*` can import this module
-- without reaching `types.typecheck` — the producer (`buildDispositions`) lives
-- there; this module is the shared carrier plus the installed lookup, mirroring
-- `types/route_key.mdk`'s `evidenceRef`/`installEvidence`.
--
-- Its readers are the two passes that turn an `InheritedDefault` row into code:
-- `core_ir_lower` (one `CImplDefault` entry per row, which every compiled engine
-- dispatches like the instance's own methods) and eval's install (one specialized
-- candidate per row).  Neither chooses a default: the row says which interface's
-- body serves which instance's slot.
import frontend.ast.{Ty}
import types.repr.{IfaceRef(..)}
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert, omKeys}
import support.util.{reverseL}

-- An instance's within-compile identity: the declaring module id and a
-- whole-graph-unique ordinal.  Mirrors `types.typecheck`'s `InstRef` (`mid`,
-- `seq` — see that type's own header for the uniqueness argument) as a
-- separate, minimal carrier rather than an import of it: `InstRef` is
-- typecheck-private, and importing it here would be the exact import cycle
-- this module exists to avoid.
public export data InstId = InstId String Int

export
instIdMid : InstId -> String
instIdMid (InstId m _) = m

export
instIdSeq : InstId -> Int
instIdSeq (InstId _ s) = s

-- One method slot of one accepted instance.  `iface` is carried on both arms so
-- a reader never has to re-derive which interface's default filled a slot from
-- context — two differently-named interfaces sharing a method spelling on one
-- instance must stay two distinct rows (#1265).
public export data MethodDisposition =
  | Supplied {
    instance : InstId,
    iface : IfaceRef,
    method : String,
  }
  | InheritedDefault { instance : InstId, iface : IfaceRef, method : String }

export
dispositionInstance : MethodDisposition -> InstId
dispositionInstance (Supplied { instance = i }) = i
dispositionInstance (InheritedDefault { instance = i }) = i

export
dispositionIface : MethodDisposition -> IfaceRef
dispositionIface (Supplied { iface = ir }) = ir
dispositionIface (InheritedDefault { iface = ir }) = ir

export
dispositionMethod : MethodDisposition -> String
dispositionMethod (Supplied { method = m }) = m
dispositionMethod (InheritedDefault { method = m }) = m

-- The index key: instance identity + method name.  `seq` alone is already
-- whole-graph-unique; `mid` rides along only so a rendered key stays legible
-- without a second lookup.
--
-- > dispositionKey (InstId "dog" 3) "speak"
-- "dog#3@speak"
export
dispositionKey : InstId -> String -> String
dispositionKey inst method =
  "\{instIdMid inst}#\{intToString (instIdSeq inst)}@\{method}"

-- What a pass needs to give one instance an entry for an inherited default, named
-- the way every engine already names the instance.  The entry is the default's body
-- specialized to the instance; the instance's dictionary reaches it as its receiver
-- argument, so nothing about the instance's dictionary is kept here.
public export data InstanceShape = InstanceShape {
  -- the canonical route word (`route_key.implRouteKeyWord` of the impl's own
  -- interface origin and type arguments, no method): the key its supplied
  -- methods carry, so an inherited entry sits beside them under the same word
  isWord : String,
  -- the impl head's type arguments, from which a pass derives the head tag and
  -- specificity score exactly as it does for the impl's own methods
  isTys : List Ty,
}

export data DispositionTable = DispositionTable {
  dtRows : List MethodDisposition,
  dtIndex : OrdMap MethodDisposition,
  -- the instances inheriting each (interface word, method) slot, keyed by
  -- `slotKey`, in producer order
  dtInheritors : OrdMap (List InstanceShape),
  -- each interface's DIRECT superinterface count, keyed by interface word: the
  -- length of the super segment a dictionary of that interface stores ahead of its
  -- `requires` dictionaries
  dtIfaceSuperCounts : OrdMap Int,
}

export
emptyDispositionTable : DispositionTable
emptyDispositionTable = DispositionTable {
  dtRows = [],
  dtIndex = omEmpty,
  dtInheritors = omEmpty,
  dtIfaceSuperCounts = omEmpty,
}

export
dispositionRows : DispositionTable -> List MethodDisposition
dispositionRows table = table.dtRows

-- Fold [rows] into the table's map index, panicking on the first duplicate
-- (instance, method) key — two rows publishing the same slot is a producer
-- bug, never a case with a policy: `dispositionLookup` below must answer with
-- exactly one row or none.
export
buildDispositionTable : List MethodDisposition -> DispositionTable
buildDispositionTable rows = DispositionTable {
  dtRows = rows,
  dtIndex = insertDispositions rows omEmpty,
  dtInheritors = omEmpty,
  dtIfaceSuperCounts = omEmpty,
}

-- The producer's builder: each row with its instance's shape and its interface's
-- word (`route_key.ifaceWordOf`), which also fills the inheritor index, and each
-- interface word with its direct superinterface count.
export
buildDispositionTableWithShapes : List (InstanceShape, String, MethodDisposition) ->
  List (String, Int) ->
  DispositionTable
buildDispositionTableWithShapes shaped superCounts =
  let rows = map ((_, _, d) => d) shaped
  DispositionTable {
    dtRows = rows,
    dtIndex = insertDispositions rows omEmpty,
    dtInheritors = insertInheritors (reverseL shaped) omEmpty,
    dtIfaceSuperCounts = insertSuperCounts superCounts omEmpty,
  }

insertSuperCounts : List (String, Int) -> OrdMap Int -> OrdMap Int
insertSuperCounts [] acc = acc
insertSuperCounts ((word, n) :: rest) acc =
  insertSuperCounts rest (omInsert word n acc)

-- How many superinterface dictionaries a dictionary of the interface with word
-- [ifaceWord] stores ahead of its `requires` dictionaries.  An interface the table
-- does not know has none.
export
ifaceSuperCount : String -> DispositionTable -> Int
ifaceSuperCount ifaceWord table =
  optionOr 0 (omLookup ifaceWord table.dtIfaceSuperCounts)

insertInheritors : List (InstanceShape, String, MethodDisposition) ->
  OrdMap (List InstanceShape) ->
  OrdMap (List InstanceShape)
insertInheritors [] acc = acc
insertInheritors ((shape, ifaceWord, InheritedDefault { method = m }) :: rest) acc =
  let key = slotKey ifaceWord m
  insertInheritors
    rest
    (omInsert key (shape :: optionOr [] (omLookup key acc)) acc)
insertInheritors (_ :: rest) acc = insertInheritors rest acc

-- `#` cannot occur in an interface word or a method name.
--
-- > slotKey "core::Ord" "lt"
-- "core::Ord#lt"
export
slotKey : String -> String -> String
slotKey ifaceWord method = "\{ifaceWord}#\{method}"

-- The instances whose [method] slot of the interface with word [ifaceWord] is
-- filled by that interface's default body, in producer order.  A map lookup.
export
inheritorsOf : String -> String -> DispositionTable -> List InstanceShape
inheritorsOf ifaceWord method table =
  optionOr [] (omLookup (slotKey ifaceWord method) table.dtInheritors)

-- Every (interface slot, inheriting instance word) pair, slot by slot: the
-- draft carrier's copy of the inherited-default rows.
export
inheritedDefaultSlots : DispositionTable -> List (String, String)
inheritedDefaultSlots table =
  flatMap
    (slot => map (shape => (slot, shape.isWord)) (slotInheritors slot table))
    (omKeys table.dtInheritors)

slotInheritors : String -> DispositionTable -> List InstanceShape
slotInheritors slot table = optionOr [] (omLookup slot table.dtInheritors)

insertDispositions : List MethodDisposition ->
  OrdMap MethodDisposition ->
  OrdMap MethodDisposition
insertDispositions [] acc = acc
insertDispositions (d :: rest) acc =
  let key = dispositionKey (dispositionInstance d) (dispositionMethod d)
  match omLookup key acc
    Some _ => panic "disposition table: two rows published for \{key}"
    None => insertDispositions rest (omInsert key d acc)

-- A map lookup, never a List scan.  (`MethodDisposition` derives no `Debug`,
-- so this is exercised as a `test` in `disposition_test.mdk` rather than a
-- doctest that would print one.)
export
dispositionLookup : InstId ->
  String ->
  DispositionTable ->
  Option MethodDisposition
dispositionLookup inst method table =
  omLookup (dispositionKey inst method) table.dtIndex

-- Bare-name comparison only: this module carries no ordinal-scoped visibility
-- of its own (unlike `types.typecheck`'s `ceLookupAt`), so it cannot
-- discriminate two same-spelled interfaces the way the producer can. Used only
-- to confirm a lookup answered with the SAME interface the caller expected, not
-- to select among candidates.
ifaceRefSameSpelling : IfaceRef -> IfaceRef -> Bool
ifaceRefSameSpelling a b = a.irName == b.irName

-- What is wrong with [table] as the disposition of the [expected] (instance,
-- iface, method) slots: a slot with no row, or a slot answered by a different
-- interface.  Empty when every slot is disposed.  (A second row for one slot never
-- reaches here: building the table refuses it.)
export
dispositionProblems : List (InstId, IfaceRef, String) ->
  DispositionTable ->
  List String
dispositionProblems [] _ = []
dispositionProblems ((inst, iface, method) :: rest) table =
  let key = dispositionKey inst method
  let here = match dispositionLookup inst method table
    None => ["missing disposition for \{key}"]
    Some row =>
      if ifaceRefSameSpelling iface (dispositionIface row) then
        []
      else
        ["\{key} answered by a different interface"]
  here ++ dispositionProblems rest table

-- Refuse a table that leaves an [expected] slot without its one disposition.  The
-- producer calls this on every table it publishes, so a consumer never meets a
-- missing or doubled slot it would otherwise have to fill or choose between.
export
validateDispositionTable : List (InstId, IfaceRef, String) ->
  DispositionTable ->
  Unit
validateDispositionTable expected table =
  match dispositionProblems expected table
    [] => ()
    problem :: _ => panic "disposition table: \{problem}"

-- ── the installed table ────────────────────────────────────────────────────
-- `elaborateModules` installs one every elaboration so its readers (see the header)
-- need not thread the table through every call site by hand, exactly as
-- `installEvidence` does.
dispositionsRef : Ref (Option DispositionTable)
dispositionsRef = Ref None

-- Replace the installed table with this elaboration's. Called once per
-- elaboration, so the table never outlives the program it describes.
export
installDispositions : DispositionTable -> Unit
installDispositions table = dispositionsRef := Some table

-- A miss means no elaboration has published one — loud, mirroring
-- `route_key.mdk`'s `evDictRoutes` `None` arm at `evidenceRef`, never a silent
-- empty table.
export
installedDispositions : Unit -> DispositionTable
installedDispositions _ = match !dispositionsRef
  None => panic "disposition table: no elaboration has published one"
  Some table => table

-- For a lowering driver that may run without an elaboration (the untyped Core-IR
-- and eval probes): `None` there means the program was never typechecked, so no
-- instance's inherited defaults are known and none is specialized — an impl that
-- leaves another module's interface method to its default has no body for it on
-- that path (see `core_ir_lower.lowerProgram`).  A typechecked driver reads
-- `installedDispositions`, which refuses a missing table.
export
installedDispositionsOpt : Unit -> Option DispositionTable
installedDispositionsOpt _ = !dispositionsRef

-- Put back a table read with `installedDispositionsOpt`, for a driver that
-- elaborates a program it derived from the user's and must leave the user's own
-- elaboration's table installed for the engine that runs next.
export
restoreDispositions : Option DispositionTable -> Unit
restoreDispositions saved = dispositionsRef := saved
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "InstId" () ((variant "InstId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "instIdMid" (TyFun (TyCon "InstId") (TyCon "String")))
(DFunDef false "instIdMid" ((PCon "InstId" (PVar "m") PWild)) (EVar "m"))
(DTypeSig true "instIdSeq" (TyFun (TyCon "InstId") (TyCon "Int")))
(DFunDef false "instIdSeq" ((PCon "InstId" PWild (PVar "s"))) (EVar "s"))
(DData Public "MethodDisposition" () ((variant "Supplied" (ConNamed (field "instance" (TyCon "InstId")) (field "iface" (TyCon "IfaceRef")) (field "method" (TyCon "String")))) (variant "InheritedDefault" (ConNamed (field "instance" (TyCon "InstId")) (field "iface" (TyCon "IfaceRef")) (field "method" (TyCon "String"))))) ())
(DTypeSig true "dispositionInstance" (TyFun (TyCon "MethodDisposition") (TyCon "InstId")))
(DFunDef false "dispositionInstance" ((PRec "Supplied" ((rf "instance" (PVar "i"))) false)) (EVar "i"))
(DFunDef false "dispositionInstance" ((PRec "InheritedDefault" ((rf "instance" (PVar "i"))) false)) (EVar "i"))
(DTypeSig true "dispositionIface" (TyFun (TyCon "MethodDisposition") (TyCon "IfaceRef")))
(DFunDef false "dispositionIface" ((PRec "Supplied" ((rf "iface" (PVar "ir"))) false)) (EVar "ir"))
(DFunDef false "dispositionIface" ((PRec "InheritedDefault" ((rf "iface" (PVar "ir"))) false)) (EVar "ir"))
(DTypeSig true "dispositionMethod" (TyFun (TyCon "MethodDisposition") (TyCon "String")))
(DFunDef false "dispositionMethod" ((PRec "Supplied" ((rf "method" (PVar "m"))) false)) (EVar "m"))
(DFunDef false "dispositionMethod" ((PRec "InheritedDefault" ((rf "method" (PVar "m"))) false)) (EVar "m"))
(DTypeSig true "dispositionKey" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dispositionKey" ((PVar "inst") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "instIdMid") (EVar "inst")))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "instIdSeq") (EVar "inst"))))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))
(DData Public "InstanceShape" () ((variant "InstanceShape" (ConNamed (field "isWord" (TyCon "String")) (field "isTys" (TyApp (TyCon "List") (TyCon "Ty")))))) ())
(DData Abstract "DispositionTable" () ((variant "DispositionTable" (ConNamed (field "dtRows" (TyApp (TyCon "List") (TyCon "MethodDisposition"))) (field "dtIndex" (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition"))) (field "dtInheritors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape")))) (field "dtIfaceSuperCounts" (TyApp (TyCon "OrdMap") (TyCon "Int")))))) ())
(DTypeSig true "emptyDispositionTable" (TyCon "DispositionTable"))
(DFunDef false "emptyDispositionTable" () (ERecordCreate "DispositionTable" ((fa "dtRows" (EListLit)) (fa "dtIndex" (EVar "omEmpty")) (fa "dtInheritors" (EVar "omEmpty")) (fa "dtIfaceSuperCounts" (EVar "omEmpty")))))
(DTypeSig true "dispositionRows" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "MethodDisposition"))))
(DFunDef false "dispositionRows" ((PVar "table")) (EFieldAccess (EVar "table") "dtRows"))
(DTypeSig true "buildDispositionTable" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyCon "DispositionTable")))
(DFunDef false "buildDispositionTable" ((PVar "rows")) (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))) (fa "dtInheritors" (EVar "omEmpty")) (fa "dtIfaceSuperCounts" (EVar "omEmpty")))))
(DTypeSig true "buildDispositionTableWithShapes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "DispositionTable"))))
(DFunDef false "buildDispositionTableWithShapes" ((PVar "shaped") (PVar "superCounts")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "map") (ELam ((PTuple PWild PWild (PVar "d"))) (EVar "d"))) (EVar "shaped"))) (DoExpr (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))) (fa "dtInheritors" (EApp (EApp (EVar "insertInheritors") (EApp (EVar "reverseL") (EVar "shaped"))) (EVar "omEmpty"))) (fa "dtIfaceSuperCounts" (EApp (EApp (EVar "insertSuperCounts") (EVar "superCounts")) (EVar "omEmpty"))))))))
(DTypeSig false "insertSuperCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertSuperCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertSuperCounts" ((PCons (PTuple (PVar "word") (PVar "n")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "insertSuperCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "n")) (EVar "acc"))))
(DTypeSig true "ifaceSuperCount" (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyCon "Int"))))
(DFunDef false "ifaceSuperCount" ((PVar "ifaceWord") (PVar "table")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ifaceWord")) (EFieldAccess (EVar "table") "dtIfaceSuperCounts"))))
(DTypeSig false "insertInheritors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape"))))))
(DFunDef false "insertInheritors" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertInheritors" ((PCons (PTuple (PVar "shape") (PVar "ifaceWord") (PRec "InheritedDefault" ((rf "method" (PVar "m"))) false)) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "slotKey") (EVar "ifaceWord")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "insertInheritors") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "shape") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc"))))) (EVar "acc"))))))
(DFunDef false "insertInheritors" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "insertInheritors") (EVar "rest")) (EVar "acc")))
(DTypeSig true "slotKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "slotKey" ((PVar "ifaceWord") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig true "inheritorsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "InstanceShape"))))))
(DFunDef false "inheritorsOf" ((PVar "ifaceWord") (PVar "method") (PVar "table")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "slotKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig true "inheritedDefaultSlots" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "inheritedDefaultSlots" ((PVar "table")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "slot")) (EApp (EApp (EVar "map") (ELam ((PVar "shape")) (ETuple (EVar "slot") (EFieldAccess (EVar "shape") "isWord")))) (EApp (EApp (EVar "slotInheritors") (EVar "slot")) (EVar "table"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig false "slotInheritors" (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "InstanceShape")))))
(DFunDef false "slotInheritors" ((PVar "slot") (PVar "table")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "slot")) (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig false "insertDispositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")) (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))
(DFunDef false "insertDispositions" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertDispositions" ((PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: two rows published for ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "insertDispositions") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "d")) (EVar "acc"))))))))
(DTypeSig true "dispositionLookup" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "Option") (TyCon "MethodDisposition"))))))
(DFunDef false "dispositionLookup" ((PVar "inst") (PVar "method") (PVar "table")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (EFieldAccess (EVar "table") "dtIndex")))
(DTypeSig false "ifaceRefSameSpelling" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ifaceRefSameSpelling" ((PVar "a") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName")))
(DTypeSig true "dispositionProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dispositionProblems" ((PList) PWild) (EListLit))
(DFunDef false "dispositionProblems" ((PCons (PTuple (PVar "inst") (PVar "iface") (PVar "method")) (PVar "rest")) (PVar "table")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EVar "dispositionLookup") (EVar "inst")) (EVar "method")) (EVar "table")) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "missing disposition for ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "ifaceRefSameSpelling") (EVar "iface")) (EApp (EVar "dispositionIface") (EVar "row"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "key"))) (ELit (LString " answered by a different interface")))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "dispositionProblems") (EVar "rest")) (EVar "table"))))))
(DTypeSig true "validateDispositionTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyCon "Unit"))))
(DFunDef false "validateDispositionTable" ((PVar "expected") (PVar "table")) (EMatch (EApp (EApp (EVar "dispositionProblems") (EVar "expected")) (EVar "table")) (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "problem") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: ")) (EApp (EVar "display") (EVar "problem"))) (ELit (LString "")))))))
(DTypeSig false "dispositionsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "dispositionsRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installDispositions" (TyFun (TyCon "DispositionTable") (TyCon "Unit")))
(DFunDef false "installDispositions" ((PVar "table")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EApp (EVar "Some") (EVar "table"))))
(DTypeSig true "installedDispositions" (TyFun (TyCon "Unit") (TyCon "DispositionTable")))
(DFunDef false "installedDispositions" (PWild) (EMatch (EUnOp "!" (EVar "dispositionsRef")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "disposition table: no elaboration has published one")))) (arm (PCon "Some" (PVar "table")) () (EVar "table"))))
(DTypeSig true "installedDispositionsOpt" (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "installedDispositionsOpt" (PWild) (EUnOp "!" (EVar "dispositionsRef")))
(DTypeSig true "restoreDispositions" (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyCon "Unit")))
(DFunDef false "restoreDispositions" ((PVar "saved")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EVar "saved")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "InstId" () ((variant "InstId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "instIdMid" (TyFun (TyCon "InstId") (TyCon "String")))
(DFunDef false "instIdMid" ((PCon "InstId" (PVar "m") PWild)) (EVar "m"))
(DTypeSig true "instIdSeq" (TyFun (TyCon "InstId") (TyCon "Int")))
(DFunDef false "instIdSeq" ((PCon "InstId" PWild (PVar "s"))) (EVar "s"))
(DData Public "MethodDisposition" () ((variant "Supplied" (ConNamed (field "instance" (TyCon "InstId")) (field "iface" (TyCon "IfaceRef")) (field "method" (TyCon "String")))) (variant "InheritedDefault" (ConNamed (field "instance" (TyCon "InstId")) (field "iface" (TyCon "IfaceRef")) (field "method" (TyCon "String"))))) ())
(DTypeSig true "dispositionInstance" (TyFun (TyCon "MethodDisposition") (TyCon "InstId")))
(DFunDef false "dispositionInstance" ((PRec "Supplied" ((rf "instance" (PVar "i"))) false)) (EVar "i"))
(DFunDef false "dispositionInstance" ((PRec "InheritedDefault" ((rf "instance" (PVar "i"))) false)) (EVar "i"))
(DTypeSig true "dispositionIface" (TyFun (TyCon "MethodDisposition") (TyCon "IfaceRef")))
(DFunDef false "dispositionIface" ((PRec "Supplied" ((rf "iface" (PVar "ir"))) false)) (EVar "ir"))
(DFunDef false "dispositionIface" ((PRec "InheritedDefault" ((rf "iface" (PVar "ir"))) false)) (EVar "ir"))
(DTypeSig true "dispositionMethod" (TyFun (TyCon "MethodDisposition") (TyCon "String")))
(DFunDef false "dispositionMethod" ((PRec "Supplied" ((rf "method" (PVar "m"))) false)) (EVar "m"))
(DFunDef false "dispositionMethod" ((PRec "InheritedDefault" ((rf "method" (PVar "m"))) false)) (EVar "m"))
(DTypeSig true "dispositionKey" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dispositionKey" ((PVar "inst") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "instIdMid") (EVar "inst")))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "instIdSeq") (EVar "inst"))))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))
(DData Public "InstanceShape" () ((variant "InstanceShape" (ConNamed (field "isWord" (TyCon "String")) (field "isTys" (TyApp (TyCon "List") (TyCon "Ty")))))) ())
(DData Abstract "DispositionTable" () ((variant "DispositionTable" (ConNamed (field "dtRows" (TyApp (TyCon "List") (TyCon "MethodDisposition"))) (field "dtIndex" (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition"))) (field "dtInheritors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape")))) (field "dtIfaceSuperCounts" (TyApp (TyCon "OrdMap") (TyCon "Int")))))) ())
(DTypeSig true "emptyDispositionTable" (TyCon "DispositionTable"))
(DFunDef false "emptyDispositionTable" () (ERecordCreate "DispositionTable" ((fa "dtRows" (EListLit)) (fa "dtIndex" (EVar "omEmpty")) (fa "dtInheritors" (EVar "omEmpty")) (fa "dtIfaceSuperCounts" (EVar "omEmpty")))))
(DTypeSig true "dispositionRows" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "MethodDisposition"))))
(DFunDef false "dispositionRows" ((PVar "table")) (EFieldAccess (EVar "table") "dtRows"))
(DTypeSig true "buildDispositionTable" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyCon "DispositionTable")))
(DFunDef false "buildDispositionTable" ((PVar "rows")) (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))) (fa "dtInheritors" (EVar "omEmpty")) (fa "dtIfaceSuperCounts" (EVar "omEmpty")))))
(DTypeSig true "buildDispositionTableWithShapes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "DispositionTable"))))
(DFunDef false "buildDispositionTableWithShapes" ((PVar "shaped") (PVar "superCounts")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild PWild (PVar "d"))) (EVar "d"))) (EVar "shaped"))) (DoExpr (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))) (fa "dtInheritors" (EApp (EApp (EVar "insertInheritors") (EApp (EVar "reverseL") (EVar "shaped"))) (EVar "omEmpty"))) (fa "dtIfaceSuperCounts" (EApp (EApp (EVar "insertSuperCounts") (EVar "superCounts")) (EVar "omEmpty"))))))))
(DTypeSig false "insertSuperCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertSuperCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertSuperCounts" ((PCons (PTuple (PVar "word") (PVar "n")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "insertSuperCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "n")) (EVar "acc"))))
(DTypeSig true "ifaceSuperCount" (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyCon "Int"))))
(DFunDef false "ifaceSuperCount" ((PVar "ifaceWord") (PVar "table")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ifaceWord")) (EFieldAccess (EVar "table") "dtIfaceSuperCounts"))))
(DTypeSig false "insertInheritors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "InstanceShape"))))))
(DFunDef false "insertInheritors" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertInheritors" ((PCons (PTuple (PVar "shape") (PVar "ifaceWord") (PRec "InheritedDefault" ((rf "method" (PVar "m"))) false)) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "slotKey") (EVar "ifaceWord")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "insertInheritors") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "shape") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc"))))) (EVar "acc"))))))
(DFunDef false "insertInheritors" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "insertInheritors") (EVar "rest")) (EVar "acc")))
(DTypeSig true "slotKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "slotKey" ((PVar "ifaceWord") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig true "inheritorsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "InstanceShape"))))))
(DFunDef false "inheritorsOf" ((PVar "ifaceWord") (PVar "method") (PVar "table")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "slotKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig true "inheritedDefaultSlots" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "inheritedDefaultSlots" ((PVar "table")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "slot")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "shape")) (ETuple (EVar "slot") (EFieldAccess (EVar "shape") "isWord")))) (EApp (EApp (EVar "slotInheritors") (EVar "slot")) (EVar "table"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig false "slotInheritors" (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "InstanceShape")))))
(DFunDef false "slotInheritors" ((PVar "slot") (PVar "table")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "slot")) (EFieldAccess (EVar "table") "dtInheritors"))))
(DTypeSig false "insertDispositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")) (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))
(DFunDef false "insertDispositions" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertDispositions" ((PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: two rows published for ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "insertDispositions") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "d")) (EVar "acc"))))))))
(DTypeSig true "dispositionLookup" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "Option") (TyCon "MethodDisposition"))))))
(DFunDef false "dispositionLookup" ((PVar "inst") (PVar "method") (PVar "table")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (EFieldAccess (EVar "table") "dtIndex")))
(DTypeSig false "ifaceRefSameSpelling" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ifaceRefSameSpelling" ((PVar "a") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName")))
(DTypeSig true "dispositionProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dispositionProblems" ((PList) PWild) (EListLit))
(DFunDef false "dispositionProblems" ((PCons (PTuple (PVar "inst") (PVar "iface") (PVar "method")) (PVar "rest")) (PVar "table")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EVar "dispositionLookup") (EVar "inst")) (EVar "method")) (EVar "table")) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "missing disposition for ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "ifaceRefSameSpelling") (EVar "iface")) (EApp (EVar "dispositionIface") (EVar "row"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString " answered by a different interface")))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "dispositionProblems") (EVar "rest")) (EVar "table"))))))
(DTypeSig true "validateDispositionTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyCon "Unit"))))
(DFunDef false "validateDispositionTable" ((PVar "expected") (PVar "table")) (EMatch (EApp (EApp (EVar "dispositionProblems") (EVar "expected")) (EVar "table")) (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "problem") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: ")) (EApp (EMethodRef "display") (EVar "problem"))) (ELit (LString "")))))))
(DTypeSig false "dispositionsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "dispositionsRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installDispositions" (TyFun (TyCon "DispositionTable") (TyCon "Unit")))
(DFunDef false "installDispositions" ((PVar "table")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EApp (EVar "Some") (EVar "table"))))
(DTypeSig true "installedDispositions" (TyFun (TyCon "Unit") (TyCon "DispositionTable")))
(DFunDef false "installedDispositions" (PWild) (EMatch (EUnOp "!" (EVar "dispositionsRef")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "disposition table: no elaboration has published one")))) (arm (PCon "Some" (PVar "table")) () (EVar "table"))))
(DTypeSig true "installedDispositionsOpt" (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "installedDispositionsOpt" (PWild) (EUnOp "!" (EVar "dispositionsRef")))
(DTypeSig true "restoreDispositions" (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyCon "Unit")))
(DFunDef false "restoreDispositions" ((PVar "saved")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EVar "saved")))
