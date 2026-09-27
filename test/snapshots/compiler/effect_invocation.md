# META
source_lines=149
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
-- read at the head's own position, so a row written inside a monomorphic
-- field is charged as well. Only the head's authority arguments are
-- substituted into its fields, and an opening is done once per (head,
-- position, authority arguments): a type or row argument is already
-- charged where it lands, by the argument walk at the slot's variance, so
-- substituting it would add nothing but a key that grows with the type. An
-- abstract or builtin head has no visible fields and is read through its
-- variance only.
import types.repr.{
  Scheme(..), Mono(..), normalize, spineParts, tupleSpine, ppMono
}
import types.effect_rows.{Atom, EffRow, effrowLabels, atomsUnion}
import support.util.{joinWith}
import map as M
import map.{Map(..)}

public export data Variance = VCo | VContra | VInv

public export data InvocationOps = InvocationOps {
  -- The variance of each parameter of the head's declaration, in order;
  -- `None` when the summary cannot see the declaration.
  headVariances : Mono -> Option (List Variance),
  -- The field types of every constructor of an applied head's declaration,
  -- its authority parameters instantiated at the head's authority
  -- arguments; empty for an abstract or builtin head.
  appliedFields : Mono -> List Mono,
  -- A key naming the head's declaration.
  headKey : Mono -> String,
}

-- The atoms a host can reach through [scheme]: its forcing row, and every
-- row charged by the walk above.
export
invocationSummary : InvocationOps -> Scheme -> List Atom
invocationSummary ops (Forall _ _ _ _ force mono) =
  let st = reach ops VCo mono (Walk [] Tip)
  atomsUnion (effrowLabels force) (walkAtoms st)

-- The walk's state: the atoms charged so far, and the openings done, each
-- keyed by head, position and authority arguments.
data Walk = Walk (List Atom) (Map String Unit)

walkAtoms : Walk -> List Atom
walkAtoms (Walk atoms _) = atoms

reach : InvocationOps -> Variance -> Mono -> Walk -> Walk
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
      openHead
        ops
        pol
        (TApp a b)
        h
        args
        (reachArgs ops pol (ops.headVariances h) 0 args st)
  h@(TCon _ _) => openHead ops pol h h [] st
  _ => st

chargeRow : Variance -> EffRow -> Walk -> Walk
chargeRow VContra _ st = st
chargeRow _ row (Walk atoms done) =
  Walk (atomsUnion atoms (effrowLabels row)) done

reachAll : InvocationOps -> Variance -> List Mono -> Walk -> Walk
reachAll _ _ [] st = st
reachAll ops pol (m :: rest) st = reachAll ops pol rest (reach ops pol m st)

-- Each argument at the head's variance for its slot, composed with the
-- context; a slot the head does not declare is invariant.
reachArgs : InvocationOps ->
  Variance ->
  Option (List Variance) ->
  Int ->
  List Mono ->
  Walk ->
  Walk
reachArgs _ _ _ _ [] st = st
reachArgs ops pol vs i (arg :: rest) st =
  let slot = match vs
    Some known => varianceAt known i
    None => VInv
  reachArgs ops pol vs (i + 1) rest (reach ops (mulV pol slot) arg st)

-- Open an applied head once per (position, authority arguments).
openHead : InvocationOps ->
  Variance ->
  Mono ->
  Mono ->
  List Mono ->
  Walk ->
  Walk
openHead ops pol applied h args (Walk atoms done) =
  let key =
    "\{ops.headKey h}@\{varianceTag pol}:\{joinWith "," (authorityArgs args)}"
  if M.has key done then
    Walk atoms done
  else
    reachAll
      ops
      pol
      (ops.appliedFields applied)
      (Walk atoms (M.set key () done))

authorityArgs : List Mono -> List String
authorityArgs [] = []
authorityArgs (a :: rest) = match normalize a
  TAuth q => ppMono (TAuth q) :: authorityArgs rest
  _ => authorityArgs rest

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
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false) (mem "tupleSpine" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "EffRow" false) (mem "effrowLabels" false) (mem "atomsUnion" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Variance" () ((variant "VCo" (ConPos)) (variant "VContra" (ConPos)) (variant "VInv" (ConPos))) ())
(DData Public "InvocationOps" () ((variant "InvocationOps" (ConNamed (field "headVariances" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))) (field "appliedFields" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))) (field "headKey" (TyFun (TyCon "Mono") (TyCon "String")))))) ())
(DTypeSig true "invocationSummary" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "invocationSummary" ((PVar "ops") (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "VCo")) (EVar "mono")) (EApp (EApp (EVar "Walk") (EListLit)) (EVar "Tip")))) (DoExpr (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "walkAtoms") (EVar "st"))))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit"))))) ())
(DTypeSig false "walkAtoms" (TyFun (TyCon "Walk") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "walkAtoms" ((PCon "Walk" (PVar "atoms") PWild)) (EVar "atoms"))
(DTypeSig false "reach" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "reach" ((PVar "ops") (PVar "pol") (PVar "m") (PVar "st")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoLet false false (PVar "charged") (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "res")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EVar "flipV") (EVar "pol"))) (EVar "dom")) (EVar "charged")))))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "inner")) (EVar "st"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "elems")) () (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "elems")) (EVar "st"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (EVar "h")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headVariances") (EVar "h"))) (ELit (LInt 0))) (EVar "args")) (EVar "st")))))))) (arm (PAs "h" (PCon "TCon" PWild PWild)) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EVar "h")) (EListLit)) (EVar "st"))) (arm PWild () (EVar "st"))))
(DTypeSig false "chargeRow" (TyFun (TyCon "Variance") (TyFun (TyCon "EffRow") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "chargeRow" ((PCon "VContra") PWild (PVar "st")) (EVar "st"))
(DFunDef false "chargeRow" (PWild (PVar "row") (PCon "Walk" (PVar "atoms") (PVar "done"))) (EApp (EApp (EVar "Walk") (EApp (EApp (EVar "atomsUnion") (EVar "atoms")) (EApp (EVar "effrowLabels") (EVar "row")))) (EVar "done")))
(DTypeSig false "reachAll" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "reachAll" (PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachAll" ((PVar "ops") (PVar "pol") (PCons (PVar "m") (PVar "rest")) (PVar "st")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "m")) (EVar "st"))))
(DTypeSig false "reachArgs" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "reachArgs" (PWild PWild PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachArgs" ((PVar "ops") (PVar "pol") (PVar "vs") (PVar "i") (PCons (PVar "arg") (PVar "rest")) (PVar "st")) (EBlock (DoLet false false (PVar "slot") (EMatch (EVar "vs") (arm (PCon "Some" (PVar "known")) () (EApp (EApp (EVar "varianceAt") (EVar "known")) (EVar "i"))) (arm (PCon "None") () (EVar "VInv")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EApp (EVar "mulV") (EVar "pol")) (EVar "slot"))) (EVar "arg")) (EVar "st"))))))
(DTypeSig false "openHead" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "openHead" ((PVar "ops") (PVar "pol") (PVar "applied") (PVar "h") (PVar "args") (PCon "Walk" (PVar "atoms") (PVar "done"))) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EFieldAccess (EVar "ops") "headKey") (EVar "h")))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "varianceTag") (EVar "pol")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EVar "authorityArgs") (EVar "args"))))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "M.has") (EVar "key")) (EVar "done")) (EApp (EApp (EVar "Walk") (EVar "atoms")) (EVar "done")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "appliedFields") (EVar "applied"))) (EApp (EApp (EVar "Walk") (EVar "atoms")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (ELit LUnit)) (EVar "done"))))))))
(DTypeSig false "authorityArgs" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "authorityArgs" ((PList)) (EListLit))
(DFunDef false "authorityArgs" ((PCons (PVar "a") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TAuth" (PVar "q")) () (EBinOp "::" (EApp (EVar "ppMono") (EApp (EVar "TAuth") (EVar "q"))) (EApp (EVar "authorityArgs") (EVar "rest")))) (arm PWild () (EApp (EVar "authorityArgs") (EVar "rest")))))
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
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false) (mem "tupleSpine" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "EffRow" false) (mem "effrowLabels" false) (mem "atomsUnion" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Variance" () ((variant "VCo" (ConPos)) (variant "VContra" (ConPos)) (variant "VInv" (ConPos))) ())
(DData Public "InvocationOps" () ((variant "InvocationOps" (ConNamed (field "headVariances" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))) (field "appliedFields" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))) (field "headKey" (TyFun (TyCon "Mono") (TyCon "String")))))) ())
(DTypeSig true "invocationSummary" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "invocationSummary" ((PVar "ops") (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "VCo")) (EVar "mono")) (EApp (EApp (EVar "Walk") (EListLit)) (EVar "Tip")))) (DoExpr (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "walkAtoms") (EVar "st"))))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit"))))) ())
(DTypeSig false "walkAtoms" (TyFun (TyCon "Walk") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "walkAtoms" ((PCon "Walk" (PVar "atoms") PWild)) (EVar "atoms"))
(DTypeSig false "reach" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "reach" ((PVar "ops") (PVar "pol") (PVar "m") (PVar "st")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoLet false false (PVar "charged") (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "res")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EVar "flipV") (EVar "pol"))) (EVar "dom")) (EVar "charged")))))) (arm (PCon "TEff" (PVar "row")) () (EApp (EApp (EApp (EVar "chargeRow") (EVar "pol")) (EVar "row")) (EVar "st"))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "inner")) (EVar "st"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "elems")) () (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "elems")) (EVar "st"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (EVar "h")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "headVariances") (EVar "h"))) (ELit (LInt 0))) (EVar "args")) (EVar "st")))))))) (arm (PAs "h" (PCon "TCon" PWild PWild)) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openHead") (EVar "ops")) (EVar "pol")) (EVar "h")) (EVar "h")) (EListLit)) (EVar "st"))) (arm PWild () (EVar "st"))))
(DTypeSig false "chargeRow" (TyFun (TyCon "Variance") (TyFun (TyCon "EffRow") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "chargeRow" ((PCon "VContra") PWild (PVar "st")) (EVar "st"))
(DFunDef false "chargeRow" (PWild (PVar "row") (PCon "Walk" (PVar "atoms") (PVar "done"))) (EApp (EApp (EVar "Walk") (EApp (EApp (EVar "atomsUnion") (EVar "atoms")) (EApp (EVar "effrowLabels") (EVar "row")))) (EVar "done")))
(DTypeSig false "reachAll" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "reachAll" (PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachAll" ((PVar "ops") (PVar "pol") (PCons (PVar "m") (PVar "rest")) (PVar "st")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EVar "pol")) (EVar "m")) (EVar "st"))))
(DTypeSig false "reachArgs" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "reachArgs" (PWild PWild PWild PWild (PList) (PVar "st")) (EVar "st"))
(DFunDef false "reachArgs" ((PVar "ops") (PVar "pol") (PVar "vs") (PVar "i") (PCons (PVar "arg") (PVar "rest")) (PVar "st")) (EBlock (DoLet false false (PVar "slot") (EMatch (EVar "vs") (arm (PCon "Some" (PVar "known")) () (EApp (EApp (EVar "varianceAt") (EVar "known")) (EVar "i"))) (arm (PCon "None") () (EVar "VInv")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reachArgs") (EVar "ops")) (EVar "pol")) (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "reach") (EVar "ops")) (EApp (EApp (EVar "mulV") (EVar "pol")) (EVar "slot"))) (EVar "arg")) (EVar "st"))))))
(DTypeSig false "openHead" (TyFun (TyCon "InvocationOps") (TyFun (TyCon "Variance") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "openHead" ((PVar "ops") (PVar "pol") (PVar "applied") (PVar "h") (PVar "args") (PCon "Walk" (PVar "atoms") (PVar "done"))) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EFieldAccess (EVar "ops") "headKey") (EVar "h")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "varianceTag") (EVar "pol")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EVar "authorityArgs") (EVar "args"))))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "M.has") (EVar "key")) (EVar "done")) (EApp (EApp (EVar "Walk") (EVar "atoms")) (EVar "done")) (EApp (EApp (EApp (EApp (EVar "reachAll") (EVar "ops")) (EVar "pol")) (EApp (EFieldAccess (EVar "ops") "appliedFields") (EVar "applied"))) (EApp (EApp (EVar "Walk") (EVar "atoms")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (ELit LUnit)) (EVar "done"))))))))
(DTypeSig false "authorityArgs" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "authorityArgs" ((PList)) (EListLit))
(DFunDef false "authorityArgs" ((PCons (PVar "a") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TAuth" (PVar "q")) () (EBinOp "::" (EApp (EVar "ppMono") (EApp (EVar "TAuth") (EVar "q"))) (EApp (EVar "authorityArgs") (EVar "rest")))) (arm PWild () (EApp (EVar "authorityArgs") (EVar "rest")))))
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
