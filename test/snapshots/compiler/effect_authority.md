# META
source_lines=194
stages=DESUGAR,MARK
# SOURCE
-- Authority terms: the parameter of an effect atom as inference sees it. A
-- term is a concrete element of the label's domain, a scoped authority
-- variable, or a symbolic join of terms. A join stays symbolic while any
-- operand is a variable; concrete operands fold through the domain join.
-- Coverage is decided only where it is provable now: a variable covers itself
-- and is covered by top, a join is covered when every operand is and covers
-- when any operand does. Anything else is not proven, never assumed.

import types.effect_domain.{
  Param(..), djoin, dsub, canonParam, drender, isSubTop, subTopOf
}
import support.util.{joinWith}
import string.{trimLeft}
import map as M
import map.{Map(..)}

public export data Authority =
  | AConst Param
  | AVar (Ref Authvar)
  | AJoin (List Authority)

-- id, inference level, the domain's top, and the source binder's name when
-- the variable came from a written signature. Identity belongs to the cell
-- and survives linking, as an effect variable's does.
public export data Authvar =
  | AUnbound Int Int Param (Option String)
  | ALink Int Authority

export
authvarId : Ref Authvar -> Int
authvarId cell = match !cell
  AUnbound id _ _ _ => id
  ALink id _ => id

export
authvarLevel : Ref Authvar -> Int
authvarLevel cell = match !cell
  AUnbound _ level _ _ => level
  ALink _ a => authLevelOf a

authLevelOf : Authority -> Int
authLevelOf (AVar cell) = authvarLevel cell
authLevelOf (AJoin ms) = fold (acc m => max acc (authLevelOf m)) 0 ms
authLevelOf _ = 0

export
authvarDomain : Ref Authvar -> Param
authvarDomain cell = match !cell
  AUnbound _ _ top _ => top
  ALink _ a => authDomainTop a

export
authvarName : Ref Authvar -> Option String
authvarName cell = match !cell
  AUnbound _ _ _ name => name
  ALink _ _ => None

export
linkAuthvar : Ref Authvar -> Authority -> Unit
linkAuthvar cell a = cell := ALink (authvarId cell) a

export
authTop : Param -> Authority
authTop top = AConst (subTopOf top)

-- The domain's top for a term: from a constant's shape, or a variable's
-- declared domain. An empty join has no domain; callers never build one.
export
authDomainTop : Authority -> Param
authDomainTop (AConst p) = subTopOf p
authDomainTop (AVar cell) = authvarDomain cell
authDomainTop (AJoin (m :: _)) = authDomainTop m
authDomainTop (AJoin []) = PUnit

-- Canonical form: links followed, joins flattened, constants folded into at
-- most one operand, variables deduplicated by identity, a top constant
-- absorbing everything, and a one-operand join collapsed.
export
authNorm : Authority -> Authority
authNorm a =
  let (const, vars) = collect [a] None Tip
  match const
    Some c => if isSubTop c then AConst c else assemble (Some c) vars
    None => assemble None vars

collect : List Authority ->
  Option Param ->
  Map Int (Ref Authvar) ->
  (Option Param, Map Int (Ref Authvar))
collect [] const vars = (const, vars)
collect ((AConst p) :: rest) const vars =
  collect rest (Some (foldConst const (canonParam p))) vars
collect ((AVar cell) :: rest) const vars = match !cell
  ALink _ target => collect (target :: rest) const vars
  AUnbound id _ _ _ => collect rest const (M.set id cell vars)
collect ((AJoin ms) :: rest) const vars = collect (ms ++ rest) const vars

foldConst : Option Param -> Param -> Param
foldConst None p = p
foldConst (Some c) p = djoin c p

assemble : Option Param -> Map Int (Ref Authvar) -> Authority
assemble const vars =
  let members = map AVar (M.values vars)
  match (const, members)
    (None, []) => AJoin []
    (None, [m]) => m
    (None, ms) => AJoin ms
    (Some c, []) => AConst c
    (Some c, ms) => AJoin (AConst c :: ms)

export
authJoin : Authority -> Authority -> Authority
authJoin a b = authNorm (AJoin [a, b])

export
authJoinAll : List Authority -> Authority
authJoinAll ms = authNorm (AJoin ms)

-- The concrete element a term denotes, when it has no variable left.
export
authConst : Authority -> Option Param
authConst a = match authNorm a
  AConst p => Some p
  _ => None

export
authIsTop : Authority -> Bool
authIsTop a = match authNorm a
  AConst p => isSubTop p
  _ => False

-- The unbound variables a term mentions, deduplicated by identity.
export
authVars : Authority -> List (Ref Authvar)
authVars a =
  let (_, vars) = collect [a] None Tip
  M.values vars

export
authHasVars : Authority -> Bool
authHasVars a = match authVars a
  [] => False
  _ => True

-- `lo ⊑ hi`, decided only where provable now. False means "not proven": the
-- caller decides whether that is a failure or a pending obligation.
export
authSub : Authority -> Authority -> Bool
authSub lo hi = authSubN (authNorm lo) (authNorm hi)

authSubN : Authority -> Authority -> Bool
authSubN (AConst c) (AConst d) = dsub c d
authSubN _ (AConst d)
  | isSubTop d = True
authSubN _ (AConst _) = False
authSubN (AJoin ms) hi = allSub ms hi
authSubN lo (AJoin ms) = anySub lo ms
authSubN (AVar v) (AVar w) = authvarId v == authvarId w
authSubN _ _ = False

allSub : List Authority -> Authority -> Bool
allSub [] _ = True
allSub (m :: ms) hi = authSubN m hi && allSub ms hi

anySub : Authority -> List Authority -> Bool
anySub _ [] = False
anySub lo (m :: ms) = authSubN lo m || anySub lo ms

-- Render with a caller-supplied variable namer, so a scheme printer can share
-- its naming context. A join renders its operands separated by ` | `.
export
renderAuthorityWith : (Ref Authvar -> String) -> Authority -> String
renderAuthorityWith name a = match authNorm a
  AConst p => drender p
  AVar cell => " " ++ name cell
  AJoin ms => " (" ++ joinWith " | " (map (renderOperand name) ms) ++ ")"

renderOperand : (Ref Authvar -> String) -> Authority -> String
renderOperand _ (AConst p) = trimLeft (drender p)
renderOperand name (AVar cell) = name cell
renderOperand name a = renderAuthorityWith name a

-- The default namer: a binder's own name where the variable came from a
-- signature, else a stable id-based spelling.
export
authvarDefaultName : Ref Authvar -> String
authvarDefaultName cell = match authvarName cell
  Some n => n
  None => "k" ++ intToString (authvarId cell)

export
renderAuthority : Authority -> String
renderAuthority a = renderAuthorityWith authvarDefaultName a
# DESUGAR
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "djoin" false) (mem "dsub" false) (mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("string") ((mem "trimLeft" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Authority" () ((variant "AConst" (ConPos (TyCon "Param"))) (variant "AVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Authvar")))) (variant "AJoin" (ConPos (TyApp (TyCon "List") (TyCon "Authority"))))) ())
(DData Public "Authvar" () ((variant "AUnbound" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Param") (TyApp (TyCon "Option") (TyCon "String")))) (variant "ALink" (ConPos (TyCon "Int") (TyCon "Authority")))) ())
(DTypeSig true "authvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild) () (EVar "id")) (arm (PCon "ALink" (PVar "id") PWild) () (EVar "id"))))
(DTypeSig true "authvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild (PVar "level") PWild PWild) () (EVar "level")) (arm (PCon "ALink" PWild (PVar "a")) () (EApp (EVar "authLevelOf") (EVar "a")))))
(DTypeSig false "authLevelOf" (TyFun (TyCon "Authority") (TyCon "Int")))
(DFunDef false "authLevelOf" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarLevel") (EVar "cell")))
(DFunDef false "authLevelOf" ((PCon "AJoin" (PVar "ms"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EVar "m"))))) (ELit (LInt 0))) (EVar "ms")))
(DFunDef false "authLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig true "authvarDomain" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Param")))
(DFunDef false "authvarDomain" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild (PVar "top") PWild) () (EVar "top")) (arm (PCon "ALink" PWild (PVar "a")) () (EApp (EVar "authDomainTop") (EVar "a")))))
(DTypeSig true "authvarName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "authvarName" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild (PVar "name")) () (EVar "name")) (arm (PCon "ALink" PWild PWild) () (EVar "None"))))
(DTypeSig true "linkAuthvar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "linkAuthvar" ((PVar "cell") (PVar "a")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ALink") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "a"))))
(DTypeSig true "authTop" (TyFun (TyCon "Param") (TyCon "Authority")))
(DFunDef false "authTop" ((PVar "top")) (EApp (EVar "AConst") (EApp (EVar "subTopOf") (EVar "top"))))
(DTypeSig true "authDomainTop" (TyFun (TyCon "Authority") (TyCon "Param")))
(DFunDef false "authDomainTop" ((PCon "AConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authDomainTop" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell")))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PCons (PVar "m") PWild))) (EApp (EVar "authDomainTop") (EVar "m")))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PList))) (EVar "PUnit"))
(DTypeSig true "authNorm" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authNorm" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EVar "None")) (EVar "Tip"))) (DoExpr (EMatch (EVar "const") (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EVar "isSubTop") (EVar "c")) (EApp (EVar "AConst") (EVar "c")) (EApp (EApp (EVar "assemble") (EApp (EVar "Some") (EVar "c"))) (EVar "vars")))) (arm (PCon "None") () (EApp (EApp (EVar "assemble") (EVar "None")) (EVar "vars")))))))
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyTuple (TyApp (TyCon "Option") (TyCon "Param")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "collect" ((PList) (PVar "const") (PVar "vars")) (ETuple (EVar "const") (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "foldConst") (EVar "const")) (EApp (EVar "canonParam") (EVar "p"))))) (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PVar "const") (PVar "vars")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild (PVar "target")) () (EApp (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "target") (EVar "rest"))) (EVar "const")) (EVar "vars"))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild) () (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EVar "const")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "vars"))))))
(DFunDef false "collect" ((PCons (PCon "AJoin" (PVar "ms")) (PVar "rest")) (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EBinOp "++" (EVar "ms") (EVar "rest"))) (EVar "const")) (EVar "vars")))
(DTypeSig false "foldConst" (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "foldConst" ((PCon "None") (PVar "p")) (EVar "p"))
(DFunDef false "foldConst" ((PCon "Some" (PVar "c")) (PVar "p")) (EApp (EApp (EVar "djoin") (EVar "c")) (EVar "p")))
(DTypeSig false "assemble" (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority"))))
(DFunDef false "assemble" ((PVar "const") (PVar "vars")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "map") (EVar "AVar")) (EApp (EVar "M.values") (EVar "vars")))) (DoExpr (EMatch (ETuple (EVar "const") (EVar "members")) (arm (PTuple (PCon "None") (PList)) () (EApp (EVar "AJoin") (EListLit))) (arm (PTuple (PCon "None") (PList (PVar "m"))) () (EVar "m")) (arm (PTuple (PCon "None") (PVar "ms")) () (EApp (EVar "AJoin") (EVar "ms"))) (arm (PTuple (PCon "Some" (PVar "c")) (PList)) () (EApp (EVar "AConst") (EVar "c"))) (arm (PTuple (PCon "Some" (PVar "c")) (PVar "ms")) () (EApp (EVar "AJoin") (EBinOp "::" (EApp (EVar "AConst") (EVar "c")) (EVar "ms"))))))))
(DTypeSig true "authJoin" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authJoin" ((PVar "a") (PVar "b")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EListLit (EVar "a") (EVar "b")))))
(DTypeSig true "authJoinAll" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))
(DFunDef false "authJoinAll" ((PVar "ms")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EVar "ms"))))
(DTypeSig true "authConst" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "authConst" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EVar "None"))))
(DTypeSig true "authIsTop" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsTop" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isSubTop") (EVar "p"))) (arm PWild () (EVar "False"))))
(DTypeSig true "authVars" (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))
(DFunDef false "authVars" ((PVar "a")) (EBlock (DoLet false false (PTuple PWild (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EVar "None")) (EVar "Tip"))) (DoExpr (EApp (EVar "M.values") (EVar "vars")))))
(DTypeSig true "authHasVars" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authHasVars" ((PVar "a")) (EMatch (EApp (EVar "authVars") (EVar "a")) (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig true "authSub" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSub" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "authSubN") (EApp (EVar "authNorm") (EVar "lo"))) (EApp (EVar "authNorm") (EVar "hi"))))
(DTypeSig false "authSubN" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AConst" (PVar "d"))) (EApp (EApp (EVar "dsub") (EVar "c")) (EVar "d")))
(DFunDef false "authSubN" (PWild (PCon "AConst" (PVar "d"))) (EIf (EApp (EVar "isSubTop") (EVar "d")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "authSubN" (PWild (PCon "AConst" PWild)) (EVar "False"))
(DFunDef false "authSubN" ((PCon "AJoin" (PVar "ms")) (PVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi")))
(DFunDef false "authSubN" ((PVar "lo") (PCon "AJoin" (PVar "ms"))) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms")))
(DFunDef false "authSubN" ((PCon "AVar" (PVar "v")) (PCon "AVar" (PVar "w"))) (EBinOp "==" (EApp (EVar "authvarId") (EVar "v")) (EApp (EVar "authvarId") (EVar "w"))))
(DFunDef false "authSubN" (PWild PWild) (EVar "False"))
(DTypeSig false "allSub" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "allSub" ((PList) PWild) (EVar "True"))
(DFunDef false "allSub" ((PCons (PVar "m") (PVar "ms")) (PVar "hi")) (EBinOp "&&" (EApp (EApp (EVar "authSubN") (EVar "m")) (EVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi"))))
(DTypeSig false "anySub" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "anySub" (PWild (PList)) (EVar "False"))
(DFunDef false "anySub" ((PVar "lo") (PCons (PVar "m") (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "authSubN") (EVar "lo")) (EVar "m")) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms"))))
(DTypeSig true "renderAuthorityWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAuthorityWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "drender") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "++" (ELit (LString " ")) (EApp (EVar "name") (EVar "cell")))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (EApp (EVar "renderOperand") (EVar "name"))) (EVar "ms")))) (ELit (LString ")"))))))
(DTypeSig false "renderOperand" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderOperand" (PWild (PCon "AConst" (PVar "p"))) (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p"))))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AVar" (PVar "cell"))) (EApp (EVar "name") (EVar "cell")))
(DFunDef false "renderOperand" ((PVar "name") (PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "a")))
(DTypeSig true "authvarDefaultName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))
(DFunDef false "authvarDefaultName" ((PVar "cell")) (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))))
(DTypeSig true "renderAuthority" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "renderAuthority" ((PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "authvarDefaultName")) (EVar "a")))
# MARK
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "djoin" false) (mem "dsub" false) (mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("string") ((mem "trimLeft" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Authority" () ((variant "AConst" (ConPos (TyCon "Param"))) (variant "AVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Authvar")))) (variant "AJoin" (ConPos (TyApp (TyCon "List") (TyCon "Authority"))))) ())
(DData Public "Authvar" () ((variant "AUnbound" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Param") (TyApp (TyCon "Option") (TyCon "String")))) (variant "ALink" (ConPos (TyCon "Int") (TyCon "Authority")))) ())
(DTypeSig true "authvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild) () (EVar "id")) (arm (PCon "ALink" (PVar "id") PWild) () (EVar "id"))))
(DTypeSig true "authvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild (PVar "level") PWild PWild) () (EVar "level")) (arm (PCon "ALink" PWild (PVar "a")) () (EApp (EVar "authLevelOf") (EVar "a")))))
(DTypeSig false "authLevelOf" (TyFun (TyCon "Authority") (TyCon "Int")))
(DFunDef false "authLevelOf" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarLevel") (EVar "cell")))
(DFunDef false "authLevelOf" ((PCon "AJoin" (PVar "ms"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EVar "m"))))) (ELit (LInt 0))) (EVar "ms")))
(DFunDef false "authLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig true "authvarDomain" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Param")))
(DFunDef false "authvarDomain" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild (PVar "top") PWild) () (EVar "top")) (arm (PCon "ALink" PWild (PVar "a")) () (EApp (EVar "authDomainTop") (EVar "a")))))
(DTypeSig true "authvarName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "authvarName" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild (PVar "name")) () (EVar "name")) (arm (PCon "ALink" PWild PWild) () (EVar "None"))))
(DTypeSig true "linkAuthvar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "linkAuthvar" ((PVar "cell") (PVar "a")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ALink") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "a"))))
(DTypeSig true "authTop" (TyFun (TyCon "Param") (TyCon "Authority")))
(DFunDef false "authTop" ((PVar "top")) (EApp (EVar "AConst") (EApp (EVar "subTopOf") (EVar "top"))))
(DTypeSig true "authDomainTop" (TyFun (TyCon "Authority") (TyCon "Param")))
(DFunDef false "authDomainTop" ((PCon "AConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authDomainTop" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell")))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PCons (PVar "m") PWild))) (EApp (EVar "authDomainTop") (EVar "m")))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PList))) (EVar "PUnit"))
(DTypeSig true "authNorm" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authNorm" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EVar "None")) (EVar "Tip"))) (DoExpr (EMatch (EVar "const") (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EVar "isSubTop") (EVar "c")) (EApp (EVar "AConst") (EVar "c")) (EApp (EApp (EVar "assemble") (EApp (EVar "Some") (EVar "c"))) (EVar "vars")))) (arm (PCon "None") () (EApp (EApp (EVar "assemble") (EVar "None")) (EVar "vars")))))))
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyTuple (TyApp (TyCon "Option") (TyCon "Param")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "collect" ((PList) (PVar "const") (PVar "vars")) (ETuple (EVar "const") (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "foldConst") (EVar "const")) (EApp (EVar "canonParam") (EVar "p"))))) (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PVar "const") (PVar "vars")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild (PVar "target")) () (EApp (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "target") (EVar "rest"))) (EVar "const")) (EVar "vars"))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild) () (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EVar "const")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "vars"))))))
(DFunDef false "collect" ((PCons (PCon "AJoin" (PVar "ms")) (PVar "rest")) (PVar "const") (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EBinOp "++" (EVar "ms") (EVar "rest"))) (EVar "const")) (EVar "vars")))
(DTypeSig false "foldConst" (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "foldConst" ((PCon "None") (PVar "p")) (EVar "p"))
(DFunDef false "foldConst" ((PCon "Some" (PVar "c")) (PVar "p")) (EApp (EApp (EVar "djoin") (EVar "c")) (EVar "p")))
(DTypeSig false "assemble" (TyFun (TyApp (TyCon "Option") (TyCon "Param")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority"))))
(DFunDef false "assemble" ((PVar "const") (PVar "vars")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EMethodRef "map") (EVar "AVar")) (EApp (EVar "M.values") (EVar "vars")))) (DoExpr (EMatch (ETuple (EVar "const") (EVar "members")) (arm (PTuple (PCon "None") (PList)) () (EApp (EVar "AJoin") (EListLit))) (arm (PTuple (PCon "None") (PList (PVar "m"))) () (EVar "m")) (arm (PTuple (PCon "None") (PVar "ms")) () (EApp (EVar "AJoin") (EVar "ms"))) (arm (PTuple (PCon "Some" (PVar "c")) (PList)) () (EApp (EVar "AConst") (EVar "c"))) (arm (PTuple (PCon "Some" (PVar "c")) (PVar "ms")) () (EApp (EVar "AJoin") (EBinOp "::" (EApp (EVar "AConst") (EVar "c")) (EVar "ms"))))))))
(DTypeSig true "authJoin" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authJoin" ((PVar "a") (PVar "b")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EListLit (EVar "a") (EVar "b")))))
(DTypeSig true "authJoinAll" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))
(DFunDef false "authJoinAll" ((PVar "ms")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EVar "ms"))))
(DTypeSig true "authConst" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "authConst" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EVar "None"))))
(DTypeSig true "authIsTop" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsTop" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isSubTop") (EVar "p"))) (arm PWild () (EVar "False"))))
(DTypeSig true "authVars" (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))
(DFunDef false "authVars" ((PVar "a")) (EBlock (DoLet false false (PTuple PWild (PVar "vars")) (EApp (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EVar "None")) (EVar "Tip"))) (DoExpr (EApp (EVar "M.values") (EVar "vars")))))
(DTypeSig true "authHasVars" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authHasVars" ((PVar "a")) (EMatch (EApp (EVar "authVars") (EVar "a")) (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig true "authSub" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSub" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "authSubN") (EApp (EVar "authNorm") (EVar "lo"))) (EApp (EVar "authNorm") (EVar "hi"))))
(DTypeSig false "authSubN" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AConst" (PVar "d"))) (EApp (EApp (EVar "dsub") (EVar "c")) (EVar "d")))
(DFunDef false "authSubN" (PWild (PCon "AConst" (PVar "d"))) (EIf (EApp (EVar "isSubTop") (EVar "d")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "authSubN" (PWild (PCon "AConst" PWild)) (EVar "False"))
(DFunDef false "authSubN" ((PCon "AJoin" (PVar "ms")) (PVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi")))
(DFunDef false "authSubN" ((PVar "lo") (PCon "AJoin" (PVar "ms"))) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms")))
(DFunDef false "authSubN" ((PCon "AVar" (PVar "v")) (PCon "AVar" (PVar "w"))) (EBinOp "==" (EApp (EVar "authvarId") (EVar "v")) (EApp (EVar "authvarId") (EVar "w"))))
(DFunDef false "authSubN" (PWild PWild) (EVar "False"))
(DTypeSig false "allSub" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "allSub" ((PList) PWild) (EVar "True"))
(DFunDef false "allSub" ((PCons (PVar "m") (PVar "ms")) (PVar "hi")) (EBinOp "&&" (EApp (EApp (EVar "authSubN") (EVar "m")) (EVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi"))))
(DTypeSig false "anySub" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "anySub" (PWild (PList)) (EVar "False"))
(DFunDef false "anySub" ((PVar "lo") (PCons (PVar "m") (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "authSubN") (EVar "lo")) (EVar "m")) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms"))))
(DTypeSig true "renderAuthorityWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAuthorityWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "drender") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "++" (ELit (LString " ")) (EApp (EVar "name") (EVar "cell")))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderOperand") (EVar "name"))) (EVar "ms")))) (ELit (LString ")"))))))
(DTypeSig false "renderOperand" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderOperand" (PWild (PCon "AConst" (PVar "p"))) (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p"))))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AVar" (PVar "cell"))) (EApp (EVar "name") (EVar "cell")))
(DFunDef false "renderOperand" ((PVar "name") (PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "a")))
(DTypeSig true "authvarDefaultName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))
(DFunDef false "authvarDefaultName" ((PVar "cell")) (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))))
(DTypeSig true "renderAuthority" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "renderAuthority" ((PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "authvarDefaultName")) (EVar "a")))
