# META
source_lines=31
stages=DESUGAR,MARK
# SOURCE
-- Engine-neutral property-test planning primitives.
--
-- A property runner may represent a candidate as an eval `Value`, while a
-- native probe renders it as typed Medaka source.  Candidate ORDER is still a
-- semantic part of shrinking: greedy shrinking takes the first smaller value
-- that keeps the law false.  Keep that order here so an engine cannot grow its
-- own near-duplicate shrink policy.

-- Every one-element deletion, left to right.  List shrinking tries these before
-- recursively shrinking elements, so a shorter counterexample wins when both
-- are failing.
export
deleteEach : List a -> List (List a)
deleteEach [] = []
deleteEach (x :: xs) = xs :: map (prepend x) (deleteEach xs)

export
prepend : a -> List a -> List a
prepend x xs = x :: xs

-- Rebuilds candidates obtained by changing one element at a time, left to
-- right.  `smaller` is supplied by the type-specific plan interpreter.
export
replaceEach : (a -> List a) -> List a -> List (List a)
replaceEach _ [] = []
replaceEach smaller (x :: xs) =
  map (prependBefore xs) (smaller x) ++ map (prepend x) (replaceEach smaller xs)

export
prependBefore : List a -> a -> List a
prependBefore xs x = x :: xs
# DESUGAR
(DTypeSig true "deleteEach" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "deleteEach" ((PList)) (EListLit))
(DFunDef false "deleteEach" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "xs") (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EVar "deleteEach") (EVar "xs")))))
(DTypeSig true "prepend" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prepend" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig true "replaceEach" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceEach" (PWild (PList)) (EListLit))
(DFunDef false "replaceEach" ((PVar "smaller") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "prependBefore") (EVar "xs"))) (EApp (EVar "smaller") (EVar "x"))) (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EApp (EVar "replaceEach") (EVar "smaller")) (EVar "xs")))))
(DTypeSig true "prependBefore" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prependBefore" ((PVar "xs") (PVar "x")) (EBinOp "::" (EVar "x") (EVar "xs")))
# MARK
(DTypeSig true "deleteEach" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "deleteEach" ((PList)) (EListLit))
(DFunDef false "deleteEach" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "xs") (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EVar "deleteEach") (EVar "xs")))))
(DTypeSig true "prepend" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prepend" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig true "replaceEach" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceEach" (PWild (PList)) (EListLit))
(DFunDef false "replaceEach" ((PVar "smaller") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "prependBefore") (EVar "xs"))) (EApp (EVar "smaller") (EVar "x"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EApp (EVar "replaceEach") (EVar "smaller")) (EVar "xs")))))
(DTypeSig true "prependBefore" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prependBefore" ((PVar "xs") (PVar "x")) (EBinOp "::" (EVar "x") (EVar "xs")))
