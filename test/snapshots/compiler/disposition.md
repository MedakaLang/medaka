# META
source_lines=161
stages=DESUGAR,MARK
# SOURCE
-- The whole-graph per-method disposition table (#1112 A-3, #1403 X-E's future
-- input): for every accepted instance, whether each method of its interface is
-- SUPPLIED by the impl or INHERITED from the interface's default body.  No
-- method-less slot is ever represented here — an impl that omits a required
-- method with no default is rejected upstream (M1), never given an `Absent` row.
--
-- Depends only on `types.repr`'s identity types, so `compiler/ir/*`,
-- `compiler/eval/*` and `compiler/backend/*` can import this module without
-- reaching `types.typecheck` — the producer (`buildDispositions`) lives there;
-- this module is the shared carrier plus the installed lookup, mirroring
-- `types/route_key.mdk`'s `evidenceRef`/`installEvidence`.
import types.repr.{IfaceRef(..)}
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert}

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

export data DispositionTable = DispositionTable {
  dtRows : List MethodDisposition,
  dtIndex : OrdMap MethodDisposition,
}

export
emptyDispositionTable : DispositionTable
emptyDispositionTable = DispositionTable { dtRows = [], dtIndex = omEmpty }

export
dispositionRows : DispositionTable -> List MethodDisposition
dispositionRows table = table.dtRows

-- Fold [rows] into the table's map index, panicking on the first duplicate
-- (instance, method) key — two rows publishing the same slot is a producer
-- bug, never a case with a policy: `dispositionLookup` below must answer with
-- exactly one row or none.
export
buildDispositionTable : List MethodDisposition -> DispositionTable
buildDispositionTable rows =
  DispositionTable { dtRows = rows, dtIndex = insertDispositions rows omEmpty }

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

-- Assert every one of [expected] (instance, iface, method) triples has exactly
-- one row in [table], of the same interface. The production producer can never
-- omit a slot it just built by construction, so this exists for the negative
-- case: a test exercising this validator on a hand-built table (one row
-- deliberately dropped) must see it panic, not silently pass.
export
validateDispositionTable : List (InstId, IfaceRef, String) ->
  DispositionTable ->
  Unit
validateDispositionTable [] _ = ()
validateDispositionTable ((inst, iface, method) :: rest) table =
  let key = dispositionKey inst method
  let _ = match dispositionLookup inst method table
    None => panic "disposition table: missing disposition for \{key}"
    Some row =>
      if ifaceRefSameSpelling iface (dispositionIface row) then
        ()
      else
        panic "disposition table: \{key} answered by a different interface"
  validateDispositionTable rest table

-- ── the installed table ────────────────────────────────────────────────────
-- No production reader exists yet (X-E, #1403, is the first). `elaborateModules`
-- installs one every elaboration so a future reader need not thread the table
-- through every call site by hand, exactly as `installEvidence` does today.
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
# DESUGAR
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
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
(DData Abstract "DispositionTable" () ((variant "DispositionTable" (ConNamed (field "dtRows" (TyApp (TyCon "List") (TyCon "MethodDisposition"))) (field "dtIndex" (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))) ())
(DTypeSig true "emptyDispositionTable" (TyCon "DispositionTable"))
(DFunDef false "emptyDispositionTable" () (ERecordCreate "DispositionTable" ((fa "dtRows" (EListLit)) (fa "dtIndex" (EVar "omEmpty")))))
(DTypeSig true "dispositionRows" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "MethodDisposition"))))
(DFunDef false "dispositionRows" ((PVar "table")) (EFieldAccess (EVar "table") "dtRows"))
(DTypeSig true "buildDispositionTable" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyCon "DispositionTable")))
(DFunDef false "buildDispositionTable" ((PVar "rows")) (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))))))
(DTypeSig false "insertDispositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")) (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))
(DFunDef false "insertDispositions" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertDispositions" ((PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: two rows published for ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "insertDispositions") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "d")) (EVar "acc"))))))))
(DTypeSig true "dispositionLookup" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "Option") (TyCon "MethodDisposition"))))))
(DFunDef false "dispositionLookup" ((PVar "inst") (PVar "method") (PVar "table")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (EFieldAccess (EVar "table") "dtIndex")))
(DTypeSig false "ifaceRefSameSpelling" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ifaceRefSameSpelling" ((PVar "a") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName")))
(DTypeSig true "validateDispositionTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyCon "Unit"))))
(DFunDef false "validateDispositionTable" ((PList) PWild) (ELit LUnit))
(DFunDef false "validateDispositionTable" ((PCons (PTuple (PVar "inst") (PVar "iface") (PVar "method")) (PVar "rest")) (PVar "table")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (DoLet false false PWild (EMatch (EApp (EApp (EApp (EVar "dispositionLookup") (EVar "inst")) (EVar "method")) (EVar "table")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: missing disposition for ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "ifaceRefSameSpelling") (EVar "iface")) (EApp (EVar "dispositionIface") (EVar "row"))) (ELit LUnit) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString " answered by a different interface")))))))) (DoExpr (EApp (EApp (EVar "validateDispositionTable") (EVar "rest")) (EVar "table")))))
(DTypeSig false "dispositionsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "dispositionsRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installDispositions" (TyFun (TyCon "DispositionTable") (TyCon "Unit")))
(DFunDef false "installDispositions" ((PVar "table")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EApp (EVar "Some") (EVar "table"))))
(DTypeSig true "installedDispositions" (TyFun (TyCon "Unit") (TyCon "DispositionTable")))
(DFunDef false "installedDispositions" (PWild) (EMatch (EUnOp "!" (EVar "dispositionsRef")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "disposition table: no elaboration has published one")))) (arm (PCon "Some" (PVar "table")) () (EVar "table"))))
# MARK
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
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
(DData Abstract "DispositionTable" () ((variant "DispositionTable" (ConNamed (field "dtRows" (TyApp (TyCon "List") (TyCon "MethodDisposition"))) (field "dtIndex" (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))) ())
(DTypeSig true "emptyDispositionTable" (TyCon "DispositionTable"))
(DFunDef false "emptyDispositionTable" () (ERecordCreate "DispositionTable" ((fa "dtRows" (EListLit)) (fa "dtIndex" (EVar "omEmpty")))))
(DTypeSig true "dispositionRows" (TyFun (TyCon "DispositionTable") (TyApp (TyCon "List") (TyCon "MethodDisposition"))))
(DFunDef false "dispositionRows" ((PVar "table")) (EFieldAccess (EVar "table") "dtRows"))
(DTypeSig true "buildDispositionTable" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyCon "DispositionTable")))
(DFunDef false "buildDispositionTable" ((PVar "rows")) (ERecordCreate "DispositionTable" ((fa "dtRows" (EVar "rows")) (fa "dtIndex" (EApp (EApp (EVar "insertDispositions") (EVar "rows")) (EVar "omEmpty"))))))
(DTypeSig false "insertDispositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodDisposition")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")) (TyApp (TyCon "OrdMap") (TyCon "MethodDisposition")))))
(DFunDef false "insertDispositions" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "insertDispositions" ((PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: two rows published for ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "insertDispositions") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "d")) (EVar "acc"))))))))
(DTypeSig true "dispositionLookup" (TyFun (TyCon "InstId") (TyFun (TyCon "String") (TyFun (TyCon "DispositionTable") (TyApp (TyCon "Option") (TyCon "MethodDisposition"))))))
(DFunDef false "dispositionLookup" ((PVar "inst") (PVar "method") (PVar "table")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (EFieldAccess (EVar "table") "dtIndex")))
(DTypeSig false "ifaceRefSameSpelling" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ifaceRefSameSpelling" ((PVar "a") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName")))
(DTypeSig true "validateDispositionTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))) (TyFun (TyCon "DispositionTable") (TyCon "Unit"))))
(DFunDef false "validateDispositionTable" ((PList) PWild) (ELit LUnit))
(DFunDef false "validateDispositionTable" ((PCons (PTuple (PVar "inst") (PVar "iface") (PVar "method")) (PVar "rest")) (PVar "table")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EVar "inst")) (EVar "method"))) (DoLet false false PWild (EMatch (EApp (EApp (EApp (EVar "dispositionLookup") (EVar "inst")) (EVar "method")) (EVar "table")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: missing disposition for ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "ifaceRefSameSpelling") (EVar "iface")) (EApp (EVar "dispositionIface") (EVar "row"))) (ELit LUnit) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "disposition table: ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString " answered by a different interface")))))))) (DoExpr (EApp (EApp (EVar "validateDispositionTable") (EVar "rest")) (EVar "table")))))
(DTypeSig false "dispositionsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "DispositionTable"))))
(DFunDef false "dispositionsRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installDispositions" (TyFun (TyCon "DispositionTable") (TyCon "Unit")))
(DFunDef false "installDispositions" ((PVar "table")) (EApp (EApp (EVar "setRef") (EVar "dispositionsRef")) (EApp (EVar "Some") (EVar "table"))))
(DTypeSig true "installedDispositions" (TyFun (TyCon "Unit") (TyCon "DispositionTable")))
(DFunDef false "installedDispositions" (PWild) (EMatch (EUnOp "!" (EVar "dispositionsRef")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "disposition table: no elaboration has published one")))) (arm (PCon "Some" (PVar "table")) () (EVar "table"))))
