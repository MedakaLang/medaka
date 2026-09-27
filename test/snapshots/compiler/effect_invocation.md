# META
source_lines=124
stages=DESUGAR,MARK
# SOURCE
-- The invocation summary: the effects a host can make an entry perform.
--
-- The host forces the entry, calls it, and may invoke any function value the
-- entry hands back. A function value the host supplies is the host's own, and
-- its row is not the entry's to answer for. So a row is charged exactly where
-- a function type (or an effect index) sits in a position the entry
-- controls, read by declared variance: a positive position, or an invariant
-- one, which is both. A head whose variance the summary cannot see is read
-- as invariant, so an unknown slot is charged rather than skipped.
--
-- A data head is also opened: every constructor field of its declaration is
-- read at the head's own position, its parameters left as variables, so a
-- row written inside a monomorphic field is charged as well. An abstract or
-- builtin head has no visible fields and is read through its variance only.
import types.repr.{Scheme(..), Mono(..), normalize, spineParts, tupleSpine}
import types.effect_rows.{Atom, EffRow, effrowLabels, atomsUnion}
import support.util.{contains}

public export data Variance = VCo | VContra | VInv

public export data InvocationOps = InvocationOps {
  -- The variance of each parameter of the head's declaration, in order;
  -- `None` when the summary cannot see the declaration.
  headVariances : Mono -> Option (List Variance),
  -- The field types of every constructor of the head's declaration, its
  -- parameters left as variables; empty for an abstract or builtin head.
  headFields : Mono -> List Mono,
  -- A key naming the head's declaration.
  headKey : Mono -> String,
}

-- The atoms a host can reach through [scheme]: its forcing row, and every
-- row charged by the walk above.
export
invocationSummary : InvocationOps -> Scheme -> List Atom
invocationSummary ops (Forall _ _ _ _ force mono) =
  let (atoms, _) = reach ops VCo mono ([], [])
  atomsUnion (effrowLabels force) atoms

-- The walk's state: the atoms charged so far, and the (head, variance) pairs
-- whose fields have been opened, so a recursive declaration is read once.
reach : InvocationOps ->
  Variance ->
  Mono ->
  (List Atom, List String) ->
  (List Atom, List String)
reach ops pol m st = match normalize m
  TFun dom row res =>
    let charged = chargeRow pol row st
    reach ops pol res (reach ops (flipV pol) dom charged)
  TEff row => chargeRow pol row st
  TQual inner _ => reach ops pol inner st
  TApp a b => match tupleSpine (TApp a b)
    Some elems => reachAll ops pol elems st
    None =>
      let (h, args) = spineParts (TApp a b)
      openHead ops pol h (reachArgs ops pol (ops.headVariances h) 0 args st)
  h@(TCon _ _) => openHead ops pol h st
  _ => st

chargeRow : Variance ->
  EffRow ->
  (List Atom, List String) ->
  (List Atom, List String)
chargeRow VContra _ st = st
chargeRow _ row (atoms, seen) = (atomsUnion atoms (effrowLabels row), seen)

reachAll : InvocationOps ->
  Variance ->
  List Mono ->
  (List Atom, List String) ->
  (List Atom, List String)
reachAll _ _ [] st = st
reachAll ops pol (m :: rest) st = reachAll ops pol rest (reach ops pol m st)

-- Each argument at the head's variance for its slot, composed with the
-- context; a slot the head does not declare is invariant.
reachArgs : InvocationOps ->
  Variance ->
  Option (List Variance) ->
  Int ->
  List Mono ->
  (List Atom, List String) ->
  (List Atom, List String)
reachArgs _ _ _ _ [] st = st
reachArgs ops pol vs i (arg :: rest) st =
  let slot = match vs
    Some known => varianceAt known i
    None => VInv
  reachArgs ops pol vs (i + 1) rest (reach ops (mulV pol slot) arg st)

openHead : InvocationOps ->
  Variance ->
  Mono ->
  (List Atom, List String) ->
  (List Atom, List String)
openHead ops pol h (atoms, seen) =
  let key = "\{ops.headKey h}@\{varianceTag pol}"
  if contains key seen then
    (atoms, seen)
  else
    reachAll ops pol (ops.headFields h) (atoms, key :: seen)

varianceAt : List Variance -> Int -> Variance
varianceAt [] _ = VInv
varianceAt (v :: rest) i = if i <= 0 then v else varianceAt rest (i - 1)

flipV : Variance -> Variance
flipV VCo = VContra
flipV VContra = VCo
flipV VInv = VInv

-- Sign composition: `VCo` is the unit and `VInv` absorbs.
mulV : Variance -> Variance -> Variance
mulV VInv _ = VInv
mulV _ VInv = VInv
mulV VCo v = v
mulV VContra VCo = VContra
mulV VContra VContra = VCo

varianceTag : Variance -> String
varianceTag VCo = "+"
varianceTag VContra = "-"
varianceTag VInv = "="
# DESUGAR
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "EffRow" false) (mem "effrowLabels" false) (mem "atomsUnion" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DData Public "Variance" () ((variant "VCo" (ConPos)) (variant "VContra" (ConPos)) (variant "VInv" (ConPos))) ())
(DData Public "InvocationOps" () ((variant "InvocationOps" (ConNamed (field "headVariances" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))) (field "headFields" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))) (field "headKey" (TyFun (TyCon "Mono") (TyCon "String")))))) ())
(DTypeSig true "invocationSummary" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "invocationSummary" ((PVar "ops") (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EBlock (DoLet false false (PTuple (PVar "atoms") PWild) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "VCo")) (EVar "mono")) (ETuple (EListLit) (EListLit)))) (DoExpr (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EVar "atoms")))))
(DTypeSig false "reach" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reach" ((PVar "ops") (PVar "pol") (PVar "m") (PVar "st")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoLet false false (PVar "charged") (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "res")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EVar "flipV") (EVar "pol"))) (EVar "dom")) (EVar "charged")))))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "inner")) (EVar "st"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "elems")) () (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "elems")) (EVar "st"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headVariances") (EVar "h"))) (ELit (LInt 0))) (EVar "args")) (EVar "st")))))))) (arm (PAs "h" (PCon "TCon" PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EVar "st"))) (arm PWild () (EVar "st"))))
(DTypeSig false "chargeRow" (TyFun (TyCon "Variance") (TyFun (TyCon "EffRow") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "chargeRow" ((PCon "VContra") PWild (PVar "st")) (EVar "st"))
(DFunDef false "chargeRow" (PWild (PVar "row") (PTuple (PVar "atoms") (PVar "seen"))) (ETuple (EApp (EApp (EVar "atomsUnion") (EVar "atoms")) (EApp (EVar "effrowLabels") (EVar "row"))) (EVar "seen")))
(DTypeSig false "reachAll" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachAll" (PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachAll" ((PVar "ops") (PVar "pol") (PCons (PVar "m") (PVar "rest")) (PVar "st")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "m")) (EVar "st"))))
(DTypeSig false "reachArgs" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "reachArgs" (PWild PWild PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachArgs" ((PVar "ops") (PVar "pol") (PVar "vs") (PVar "i") (PCons (PVar "arg") (PVar "rest")) (PVar "st")) (EBlock (DoLet false false (PVar "slot") (EMatch (EVar "vs") (arm (PCon "Some" (PVar "known")) () (EApp (EApp (EVar "varianceAt") (EVar "known")) (EVar "i"))) (arm (PCon "None") () (EVar "VInv")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EApp (EVar "mulV") (EVar "pol")) (EVar "slot"))) (EVar "arg")) (EVar "st"))))))
(DTypeSig false "openHead" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "openHead" ((PVar "ops") (PVar "pol") (PVar "h") (PTuple (PVar "atoms") (PVar "seen"))) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EFieldAccess (EVar "ops") "headKey") (EVar "h")))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "varianceTag") (EVar "pol")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "seen")) (ETuple (EVar "atoms") (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headFields") (EVar "h"))) (ETuple (EVar "atoms") (EBinOp "::" (EVar "key") (EVar "seen"))))))))
(DTypeSig false "varianceAt" (TyFun (TyApp (TyCon "List") (TyCon "Variance")) (TyFun (TyCon "Int") (TyCon "Variance"))))
(DFunDef false "varianceAt" ((PList) PWild) (EVar "VInv"))
(DFunDef false "varianceAt" ((PCons (PVar "v") (PVar "rest")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "v") (EApp (EApp (EVar "varianceAt") (EVar "rest")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "flipV" (TyFun (TyCon "Variance") (TyCon "Variance")))
(DFunDef false "flipV" ((PCon "VCo")) (EVar "VContra"))
(DFunDef false "flipV" ((PCon "VContra")) (EVar "VCo"))
(DFunDef false "flipV" ((PCon "VInv")) (EVar "VInv"))
(DTypeSig false "mulV" (TyFun (TyCon "Variance") (TyFun (TyCon "Variance") (TyCon "Variance"))))
(DFunDef false "mulV" ((PCon "VInv") PWild) (EVar "VInv"))
(DFunDef false "mulV" (PWild (PCon "VInv")) (EVar "VInv"))
(DFunDef false "mulV" ((PCon "VCo") (PVar "v")) (EVar "v"))
(DFunDef false "mulV" ((PCon "VContra") (PCon "VCo")) (EVar "VContra"))
(DFunDef false "mulV" ((PCon "VContra") (PCon "VContra")) (EVar "VCo"))
(DTypeSig false "varianceTag" (TyFun (TyCon "Variance") (TyCon "String")))
(DFunDef false "varianceTag" ((PCon "VCo")) (ELit (LString "+")))
(DFunDef false "varianceTag" ((PCon "VContra")) (ELit (LString "-")))
(DFunDef false "varianceTag" ((PCon "VInv")) (ELit (LString "=")))
# MARK
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "EffRow" false) (mem "effrowLabels" false) (mem "atomsUnion" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DData Public "Variance" () ((variant "VCo" (ConPos)) (variant "VContra" (ConPos)) (variant "VInv" (ConPos))) ())
(DData Public "InvocationOps" () ((variant "InvocationOps" (ConNamed (field "headVariances" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))) (field "headFields" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))) (field "headKey" (TyFun (TyCon "Mono") (TyCon "String")))))) ())
(DTypeSig true "invocationSummary" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "invocationSummary" ((PVar "ops") (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EBlock (DoLet false false (PTuple (PVar "atoms") PWild) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "VCo")) (EVar "mono")) (ETuple (EListLit) (EListLit)))) (DoExpr (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EVar "atoms")))))
(DTypeSig false "reach" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reach" ((PVar "ops") (PVar "pol") (PVar "m") (PVar "st")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoLet false false (PVar "charged") (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "res")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EVar "flipV") (EVar "pol"))) (EVar "dom")) (EVar "charged")))))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "inner")) (EVar "st"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "elems")) () (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "elems")) (EVar "st"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headVariances") (EVar "h"))) (ELit (LInt 0))) (EVar "args")) (EVar "st")))))))) (arm (PAs "h" (PCon "TCon" PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EVar "st"))) (arm PWild () (EVar "st"))))
(DTypeSig false "chargeRow" (TyFun (TyCon "Variance") (TyFun (TyCon "EffRow") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "chargeRow" ((PCon "VContra") PWild (PVar "st")) (EVar "st"))
(DFunDef false "chargeRow" (PWild (PVar "row") (PTuple (PVar "atoms") (PVar "seen"))) (ETuple (EApp (EApp (EVar "atomsUnion") (EVar "atoms")) (EApp (EVar "effrowLabels") (EVar "row"))) (EVar "seen")))
(DTypeSig false "reachAll" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachAll" (PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachAll" ((PVar "ops") (PVar "pol") (PCons (PVar "m") (PVar "rest")) (PVar "st")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "m")) (EVar "st"))))
(DTypeSig false "reachArgs" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "reachArgs" (PWild PWild PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachArgs" ((PVar "ops") (PVar "pol") (PVar "vs") (PVar "i") (PCons (PVar "arg") (PVar "rest")) (PVar "st")) (EBlock (DoLet false false (PVar "slot") (EMatch (EVar "vs") (arm (PCon "Some" (PVar "known")) () (EApp (EApp (EVar "varianceAt") (EVar "known")) (EVar "i"))) (arm (PCon "None") () (EVar "VInv")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EApp (EVar "mulV") (EVar "pol")) (EVar "slot"))) (EVar "arg")) (EVar "st"))))))
(DTypeSig false "openHead" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "openHead" ((PVar "ops") (PVar "pol") (PVar "h") (PTuple (PVar "atoms") (PVar "seen"))) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EFieldAccess (EVar "ops") "headKey") (EVar "h")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "varianceTag") (EVar "pol")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "seen")) (ETuple (EVar "atoms") (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headFields") (EVar "h"))) (ETuple (EVar "atoms") (EBinOp "::" (EVar "key") (EVar "seen"))))))))
(DTypeSig false "varianceAt" (TyFun (TyApp (TyCon "List") (TyCon "Variance")) (TyFun (TyCon "Int") (TyCon "Variance"))))
(DFunDef false "varianceAt" ((PList) PWild) (EVar "VInv"))
(DFunDef false "varianceAt" ((PCons (PVar "v") (PVar "rest")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "v") (EApp (EApp (EVar "varianceAt") (EVar "rest")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "flipV" (TyFun (TyCon "Variance") (TyCon "Variance")))
(DFunDef false "flipV" ((PCon "VCo")) (EVar "VContra"))
(DFunDef false "flipV" ((PCon "VContra")) (EVar "VCo"))
(DFunDef false "flipV" ((PCon "VInv")) (EVar "VInv"))
(DTypeSig false "mulV" (TyFun (TyCon "Variance") (TyFun (TyCon "Variance") (TyCon "Variance"))))
(DFunDef false "mulV" ((PCon "VInv") PWild) (EVar "VInv"))
(DFunDef false "mulV" (PWild (PCon "VInv")) (EVar "VInv"))
(DFunDef false "mulV" ((PCon "VCo") (PVar "v")) (EVar "v"))
(DFunDef false "mulV" ((PCon "VContra") (PCon "VCo")) (EVar "VContra"))
(DFunDef false "mulV" ((PCon "VContra") (PCon "VContra")) (EVar "VCo"))
(DTypeSig false "varianceTag" (TyFun (TyCon "Variance") (TyCon "String")))
(DFunDef false "varianceTag" ((PCon "VCo")) (ELit (LString "+")))
(DFunDef false "varianceTag" ((PCon "VContra")) (ELit (LString "-")))
(DFunDef false "varianceTag" ((PCon "VInv")) (ELit (LString "=")))
