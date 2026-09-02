# META
source_lines=17
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- A lambda whose body is a statement block, written directly as a
-- parenthesized argument — in any argument position, not only the last
-- (#834): a line-final `=>` inside a bracket arms the block.
wrap : (Unit -> String) -> Int -> (Unit -> String, Int)
wrap f n = (f, n)

pair : (Unit -> String, Int)
pair = wrap (u =>
  let s = "woof"
  s) 1

doubled : List Int -> List Int
doubled xs = map (x =>
  let y = x * 2
  y) xs

main = putStrLn ((fst pair) ())
# PARSE
(DTypeSig false "wrap" (TyFun (TyFun (TyCon "Unit") (TyCon "String")) (TyFun (TyCon "Int") (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "wrap" ((PVar "f") (PVar "n")) (ETuple (EVar "f") (EVar "n")))
(DTypeSig false "pair" (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))
(DFunDef false "pair" () (EApp (EApp (EVar "wrap") (ELam ((PVar "u")) (EBlock (DoLet false false (PVar "s") (ELit (LString "woof"))) (DoExpr (EVar "s"))))) (ELit (LInt 1))))
(DTypeSig false "doubled" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "doubled" ((PVar "xs")) (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBlock (DoLet false false (PVar "y") (EBinOp "*" (EVar "x") (ELit (LInt 2)))) (DoExpr (EVar "y"))))) (EVar "xs")))
(DFunDef false "main" () (EApp (EVar "putStrLn") (EApp (EApp (EVar "fst") (EVar "pair")) (ELit LUnit))))
# PRINTER
wrap : (Unit -> String) -> Int -> (Unit -> String, Int)
wrap f n = (f, n)
pair : (Unit -> String, Int)
pair =
  wrap
    (u =>
      let s = "woof"
      s)
    1
doubled : List Int -> List Int
doubled xs =
  map
    (x =>
      let y = x * 2
      y)
    xs
main = putStrLn (fst pair ())
# DESUGAR
(DTypeSig false "wrap" (TyFun (TyFun (TyCon "Unit") (TyCon "String")) (TyFun (TyCon "Int") (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "wrap" ((PVar "f") (PVar "n")) (ETuple (EVar "f") (EVar "n")))
(DTypeSig false "pair" (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))
(DFunDef false "pair" () (EApp (EApp (EVar "wrap") (ELam ((PVar "u")) (EBlock (DoLet false false (PVar "s") (ELit (LString "woof"))) (DoExpr (EVar "s"))))) (ELit (LInt 1))))
(DTypeSig false "doubled" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "doubled" ((PVar "xs")) (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBlock (DoLet false false (PVar "y") (EBinOp "*" (EVar "x") (ELit (LInt 2)))) (DoExpr (EVar "y"))))) (EVar "xs")))
(DFunDef false "main" () (EApp (EVar "putStrLn") (EApp (EApp (EVar "fst") (EVar "pair")) (ELit LUnit))))
# MARK
(DTypeSig false "wrap" (TyFun (TyFun (TyCon "Unit") (TyCon "String")) (TyFun (TyCon "Int") (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "wrap" ((PVar "f") (PVar "n")) (ETuple (EVar "f") (EVar "n")))
(DTypeSig false "pair" (TyTuple (TyFun (TyCon "Unit") (TyCon "String")) (TyCon "Int")))
(DFunDef false "pair" () (EApp (EApp (EVar "wrap") (ELam ((PVar "u")) (EBlock (DoLet false false (PVar "s") (ELit (LString "woof"))) (DoExpr (EVar "s"))))) (ELit (LInt 1))))
(DTypeSig false "doubled" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "doubled" ((PVar "xs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBlock (DoLet false false (PVar "y") (EBinOp "*" (EVar "x") (ELit (LInt 2)))) (DoExpr (EVar "y"))))) (EVar "xs")))
(DFunDef false "main" () (EApp (EVar "putStrLn") (EApp (EApp (EVar "fst") (EVar "pair")) (ELit LUnit))))
