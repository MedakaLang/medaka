# META
source_lines=45
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
export interface Eq a where
  eq : a -> a -> Bool

export interface Ord a requires Eq a where
  compare : a -> a -> Ordering
  lte x y = compare x y

export impl Eq Int where
  eq a b = a == b

impl Eq (Option a) requires Eq a where
  eq None None = True
  eq (Some a) (Some b) = eq a b
  eq _ _ = False

impl Debug a where
  debug _ = "?"

-- #508: a guarded clause parses inside an impl method body, same shapes as a
-- top-level multi-clause function (inline `|` and an indented arm block).
interface Sz a where
  eq2 : a -> a -> Bool

data T = T Int

impl Sz T where
  eq2 (T a) (T b) | a == b = True
  eq2 _ _ = False

impl Ord2 T where
  compare2 (T a) (T b)
    | a < b = LT
    | a > b = GT
    | otherwise = EQ

clamp lo hi = min hi >> max lo

combine = f << g

deleteAt x count =
  if has x then
    remove x
    setRef count (count.value - 1)

divides a b = mod a b == 0
# PARSE
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DInterface false false "Sz" ("a") () ((imethod "eq2" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DData Private "T" () ((variant "T" (ConPos (TyCon "Int")))) ())
(DImpl false "Sz" ((TyCon "T")) () ((im "eq2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EGuards (garm ((GBool (EBinOp "==" (EVar "a") (EVar "b")))) (EVar "True")))) (im "eq2" (PWild PWild) (EVar "False"))))
(DImpl false "Ord2" ((TyCon "T")) () ((im "compare2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EGuards (garm ((GBool (EBinOp "<" (EVar "a") (EVar "b")))) (EVar "LT")) (garm ((GBool (EBinOp ">" (EVar "a") (EVar "b")))) (EVar "GT")) (garm ((GBool (EVar "otherwise"))) (EVar "EQ"))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EVar "min") (EVar "hi")) (EApp (EVar "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
# PRINTER
export interface Eq a where
  eq : a -> a -> Bool
export interface Ord a requires Eq a where
  compare : a -> a -> Ordering
  lte x y = compare x y
export impl Eq Int where
  eq a b = a == b
impl Eq (Option a) requires Eq a where
  eq None None = True
  eq (Some a) (Some b) = eq a b
  eq _ _ = False
impl Debug a where
  debug _ = "?"
interface Sz a where
  eq2 : a -> a -> Bool
data T = T Int
impl Sz T where
  eq2 (T a) (T b)
    | a == b = True
  eq2 _ _ = False
impl Ord2 T where
  compare2 (T a) (T b)
    | a < b = LT
    | a > b = GT
    | otherwise = EQ
clamp lo hi = min hi >> max lo
combine = f << g
deleteAt x count =
  if has x then
    remove x
    setRef count (count.value - 1)
divides a b = mod a b == 0
# DESUGAR
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DInterface false false "Sz" ("a") () ((imethod "eq2" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DData Private "T" () ((variant "T" (ConPos (TyCon "Int")))) ())
(DImpl false "Sz" ((TyCon "T")) () ((im "eq2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit)))) (im "eq2" (PWild PWild) (EVar "False"))))
(DImpl false "Ord2" ((TyCon "T")) () ((im "compare2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "LT") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "GT") (EIf (EVar "otherwise") (EVar "EQ") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EVar "min") (EVar "hi")) (EApp (EVar "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
# MARK
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DInterface false false "Sz" ("a") () ((imethod "eq2" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DData Private "T" () ((variant "T" (ConPos (TyCon "Int")))) ())
(DImpl false "Sz" ((TyCon "T")) () ((im "eq2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit)))) (im "eq2" (PWild PWild) (EVar "False"))))
(DImpl false "Ord2" ((TyCon "T")) () ((im "compare2" ((PCon "T" (PVar "a")) (PCon "T" (PVar "b"))) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "LT") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "GT") (EIf (EVar "otherwise") (EVar "EQ") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EMethodRef "min") (EVar "hi")) (EApp (EMethodRef "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
