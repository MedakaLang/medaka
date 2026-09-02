# META
source_lines=43
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- `defer` blocks (#824): the same statement grammar as `do`, lowered to
-- `deferThen`/`deferPure` instead of `andThen`/`pure`.  This fixture pins the
-- surface shapes only — parse, print, and a byte-for-byte fmt round-trip.
import async.{Async, runAsync, liftIO}

-- bare-statement and bind forms
plain : Async <Stdout> Int
plain = defer
  x <- liftIO (u => 20)
  y <- deferPure 22
  deferPure (x + y)

-- a `let` statement between two binds
withLet : Async <Stdout> Int
withLet = defer
  x <- deferPure 20
  let d = 22
  y <- deferPure d
  deferPure (x + y)

-- a refutable bind pattern lowers through the same match-and-fallthrough
-- continuation a `do` bind does
refutable : Async <Stdout> Int
refutable = defer
  (Some x) <- deferPure (Some 20)
  (a, b) <- deferPure (2, 20)
  deferPure (x + a + b)

-- nested: a `defer` block as an argument, and a `do` block inside a `defer` one
nested : Async <Stdout> Int
nested = defer
  x <- deferPure (unOpt (do
    n <- Some 20
    pure (n + 1)))
  deferPure (x + 21)

unOpt : Option Int -> Int
unOpt (Some n) = n
unOpt None = 0

main =
  println
    (runAsync plain + runAsync withLet + runAsync refutable + runAsync nested)
# PARSE
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "runAsync" false) (mem "liftIO" false))))
(DTypeSig false "plain" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "plain" () (EDefer (DoBind (PVar "x") (EApp (EVar "liftIO") (ELam ((PVar "u")) (ELit (LInt 20))))) (DoBind (PVar "y") (EApp (EVar "deferPure") (ELit (LInt 22)))) (DoExpr (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (EVar "y"))))))
(DTypeSig false "withLet" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "withLet" () (EDefer (DoBind (PVar "x") (EApp (EVar "deferPure") (ELit (LInt 20)))) (DoLet false false (PVar "d") (ELit (LInt 22))) (DoBind (PVar "y") (EApp (EVar "deferPure") (EVar "d"))) (DoExpr (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (EVar "y"))))))
(DTypeSig false "refutable" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "refutable" () (EDefer (DoBind (PCon "Some" (PVar "x")) (EApp (EVar "deferPure") (EApp (EVar "Some") (ELit (LInt 20))))) (DoBind (PTuple (PVar "a") (PVar "b")) (EApp (EVar "deferPure") (ETuple (ELit (LInt 2)) (ELit (LInt 20))))) (DoExpr (EApp (EVar "deferPure") (EBinOp "+" (EBinOp "+" (EVar "x") (EVar "a")) (EVar "b"))))))
(DTypeSig false "nested" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "nested" () (EDefer (DoBind (PVar "x") (EApp (EVar "deferPure") (EApp (EVar "unOpt") (EDo (DoBind (PVar "n") (EApp (EVar "Some") (ELit (LInt 20)))) (DoExpr (EApp (EVar "pure") (EBinOp "+" (EVar "n") (ELit (LInt 1))))))))) (DoExpr (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (ELit (LInt 21)))))))
(DTypeSig false "unOpt" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "unOpt" ((PCon "Some" (PVar "n"))) (EVar "n"))
(DFunDef false "unOpt" ((PCon "None")) (ELit (LInt 0)))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runAsync") (EVar "plain")) (EApp (EVar "runAsync") (EVar "withLet"))) (EApp (EVar "runAsync") (EVar "refutable"))) (EApp (EVar "runAsync") (EVar "nested")))))
# PRINTER
import async.{Async, runAsync, liftIO}
plain : Async <Stdout> Int
plain = defer
  x <- liftIO (u => 20)
  y <- deferPure 22
  deferPure (x + y)
withLet : Async <Stdout> Int
withLet = defer
  x <- deferPure 20
  let d = 22
  y <- deferPure d
  deferPure (x + y)
refutable : Async <Stdout> Int
refutable = defer
  (Some x) <- deferPure (Some 20)
  (a, b) <- deferPure (2, 20)
  deferPure (x + a + b)
nested : Async <Stdout> Int
nested = defer
  x <- deferPure (unOpt (do
    n <- Some 20
    pure (n + 1)))
  deferPure (x + 21)
unOpt : Option Int -> Int
unOpt (Some n) = n
unOpt None = 0
main =
  println
    (runAsync plain + runAsync withLet + runAsync refutable + runAsync nested)
# DESUGAR
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "runAsync" false) (mem "liftIO" false))))
(DTypeSig false "plain" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "plain" () (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (ELit (LInt 20))))) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (ELit (LInt 22)))) (ELam ((PVar "y")) (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (EVar "y"))))))))
(DTypeSig false "withLet" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "withLet" () (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (ELit (LInt 20)))) (ELam ((PVar "x")) (ELet false (PVar "d") (ELit (LInt 22)) (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (EVar "d"))) (ELam ((PVar "y")) (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (EVar "y")))))))))
(DTypeSig false "refutable" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "refutable" () (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (EApp (EVar "Some") (ELit (LInt 20))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Some" (PVar "x")) () (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (ETuple (ELit (LInt 2)) (ELit (LInt 20))))) (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EVar "deferPure") (EBinOp "+" (EBinOp "+" (EVar "x") (EVar "a")) (EVar "b")))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nested" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "nested" () (EApp (EApp (EVar "deferThen") (EApp (EVar "deferPure") (EApp (EVar "unOpt") (EApp (EApp (EVar "andThen") (EApp (EVar "Some") (ELit (LInt 20)))) (ELam ((PVar "n")) (EApp (EVar "pure") (EBinOp "+" (EVar "n") (ELit (LInt 1))))))))) (ELam ((PVar "x")) (EApp (EVar "deferPure") (EBinOp "+" (EVar "x") (ELit (LInt 21)))))))
(DTypeSig false "unOpt" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "unOpt" ((PCon "Some" (PVar "n"))) (EVar "n"))
(DFunDef false "unOpt" ((PCon "None")) (ELit (LInt 0)))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runAsync") (EVar "plain")) (EApp (EVar "runAsync") (EVar "withLet"))) (EApp (EVar "runAsync") (EVar "refutable"))) (EApp (EVar "runAsync") (EVar "nested")))))
# MARK
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "runAsync" false) (mem "liftIO" false))))
(DTypeSig false "plain" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "plain" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (ELit (LInt 20))))) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (ELit (LInt 22)))) (ELam ((PVar "y")) (EApp (EMethodRef "deferPure") (EBinOp "+" (EVar "x") (EVar "y"))))))))
(DTypeSig false "withLet" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "withLet" () (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (ELit (LInt 20)))) (ELam ((PVar "x")) (ELet false (PVar "d") (ELit (LInt 22)) (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (EVar "d"))) (ELam ((PVar "y")) (EApp (EMethodRef "deferPure") (EBinOp "+" (EVar "x") (EVar "y")))))))))
(DTypeSig false "refutable" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "refutable" () (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (EApp (EVar "Some") (ELit (LInt 20))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Some" (PVar "x")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (ETuple (ELit (LInt 2)) (ELit (LInt 20))))) (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EMethodRef "deferPure") (EBinOp "+" (EBinOp "+" (EVar "x") (EVar "a")) (EVar "b")))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nested" (TyApp (TyApp (TyCon "Async") (TyRow ("Stdout") None)) (TyCon "Int")))
(DFunDef false "nested" () (EApp (EApp (EMethodRef "deferThen") (EApp (EMethodRef "deferPure") (EApp (EVar "unOpt") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "Some") (ELit (LInt 20)))) (ELam ((PVar "n")) (EApp (EMethodRef "pure") (EBinOp "+" (EVar "n") (ELit (LInt 1))))))))) (ELam ((PVar "x")) (EApp (EMethodRef "deferPure") (EBinOp "+" (EVar "x") (ELit (LInt 21)))))))
(DTypeSig false "unOpt" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "unOpt" ((PCon "Some" (PVar "n"))) (EVar "n"))
(DFunDef false "unOpt" ((PCon "None")) (ELit (LInt 0)))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runAsync") (EVar "plain")) (EApp (EVar "runAsync") (EVar "withLet"))) (EApp (EVar "runAsync") (EVar "refutable"))) (EApp (EVar "runAsync") (EVar "nested")))))
