# META
source_lines=11
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
combine m n =
  do
    x <- m
    y <- n
    pure (x + y)

chained m =
  do
    a <- m
    b <- f a
    g b
# PARSE
(DFunDef false "combine" ((PVar "m") (PVar "n")) (EDo (DoBind (PVar "x") (EVar "m")) (DoBind (PVar "y") (EVar "n")) (DoExpr (EApp (EVar "pure") (EBinOp "+" (EVar "x") (EVar "y"))))))
(DFunDef false "chained" ((PVar "m")) (EDo (DoBind (PVar "a") (EVar "m")) (DoBind (PVar "b") (EApp (EVar "f") (EVar "a"))) (DoExpr (EApp (EVar "g") (EVar "b")))))
# PRINTER
combine m n = do
  x <- m
  y <- n
  pure (x + y)
chained m = do
  a <- m
  b <- f a
  g b
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DFunDef false "combine" ((PVar "m") (PVar "n")) (EApp (EApp (EVar "$core.andThen") (EVar "m")) (ELam ((PVar "x")) (EApp (EApp (EVar "$core.andThen") (EVar "n")) (ELam ((PVar "y")) (EApp (EVar "pure") (EBinOp "+" (EVar "x") (EVar "y"))))))))
(DFunDef false "chained" ((PVar "m")) (EApp (EApp (EVar "$core.andThen") (EVar "m")) (ELam ((PVar "a")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "f") (EVar "a"))) (ELam ((PVar "b")) (EApp (EVar "g") (EVar "b")))))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DFunDef false "combine" ((PVar "m") (PVar "n")) (EApp (EApp (EVar "$core.andThen") (EVar "m")) (ELam ((PVar "x")) (EApp (EApp (EVar "$core.andThen") (EVar "n")) (ELam ((PVar "y")) (EApp (EMethodRef "pure") (EBinOp "+" (EVar "x") (EVar "y"))))))))
(DFunDef false "chained" ((PVar "m")) (EApp (EApp (EVar "$core.andThen") (EVar "m")) (ELam ((PVar "a")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "f") (EVar "a"))) (ELam ((PVar "b")) (EApp (EVar "g") (EVar "b")))))))
