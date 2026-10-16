# META
source_lines=59
stages=DESUGAR,MARK
# SOURCE
-- Deterministic per-stage CALL counter: how many times each pipeline stage ran in
-- this process, so a duplicated stage shows up as a count rather than as wall time.
--
-- The counter is write-only.  Only `stageDump` reads it, and only to print; no
-- compiler pass may read it, so the output of any pass is the same whether counting
-- is on or off.  `Ref`/`setRef` are typed pure (stdlib/runtime.mdk), so `stageBump`
-- carries no effect row and can sit inside pure stage bodies.
--
-- Counting is off unless MEDAKA_STAGE_COUNTS is set non-empty, read once by
-- `stageCountInit`.  The dump goes to stderr only, as `[stage]<TAB>key<TAB>n`; the
-- prefix differs from MEDAKA_STATS's `[stats]` so a filtered read never mixes them.

import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}

stageCountOn : Ref Bool
stageCountOn = Ref False

stageCounts : Ref (OrdMap Int)
stageCounts = Ref omEmpty

-- Count one run of the stage named `key`; a no-op when counting is off.
export
stageBump : String -> Unit
stageBump key = match !stageCountOn
  True => stageCounts := omInsert key (countOf key + 1) !stageCounts
  False => ()

countOf : String -> Int
countOf key = match omLookup key !stageCounts
  Some n => n
  None => 0

-- Turn counting on when MEDAKA_STAGE_COUNTS is set and non-empty.
export
stageCountInit : Unit -> <IO> Unit
stageCountInit () = match getEnv "MEDAKA_STAGE_COUNTS"
  Some v => stageCountOn := v /= ""
  None => ()

-- Print one `[stage]` line per key, sorted, to stderr; silent when counting is off.
export
stageDump : Unit -> <IO> Unit
stageDump () = match !stageCountOn
  True => stageDumpKeys (omKeys !stageCounts)
  False => ()

-- Every process exit goes through here, so the dump runs on error exits too.
-- `stageDump` is the only dump, so each process prints its counts exactly once.
export
stageExit : Int -> <IO> Unit
stageExit code =
  let _ = stageDump ()
  exit code

stageDumpKeys : List String -> <IO> Unit
stageDumpKeys [] = ()
stageDumpKeys (k :: rest) =
  let _ = ePutStrLn "[stage]\t\{k}\t\{countOf k}"
  stageDumpKeys rest
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DTypeSig false "stageCountOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "stageCountOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "stageCounts" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "stageCounts" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig true "stageBump" (TyFun (TyCon "String") (TyCon "Unit")))
(DFunDef false "stageBump" ((PVar "key")) (EMatch (EUnOp "!" (EVar "stageCountOn")) (arm (PCon "True") () (EApp (EApp (EVar "setRef") (EVar "stageCounts")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "+" (EApp (EVar "countOf") (EVar "key")) (ELit (LInt 1)))) (EUnOp "!" (EVar "stageCounts"))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig false "countOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countOf" ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "stageCounts"))) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "stageCountInit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageCountInit" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_STAGE_COUNTS"))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "setRef") (EVar "stageCountOn")) (EBinOp "/=" (EVar "v") (ELit (LString ""))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "stageDump" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDump" ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "stageCountOn")) (arm (PCon "True") () (EApp (EVar "stageDumpKeys") (EApp (EVar "omKeys") (EUnOp "!" (EVar "stageCounts"))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig true "stageExit" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageExit" ((PVar "code")) (EBlock (DoLet false false PWild (EApp (EVar "stageDump") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (EVar "code")))))
(DTypeSig false "stageDumpKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDumpKeys" ((PList)) (ELit LUnit))
(DFunDef false "stageDumpKeys" ((PCons (PVar "k") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[stage]\t")) (EApp (EVar "display") (EVar "k"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "countOf") (EVar "k")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageDumpKeys") (EVar "rest")))))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DTypeSig false "stageCountOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "stageCountOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "stageCounts" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "stageCounts" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig true "stageBump" (TyFun (TyCon "String") (TyCon "Unit")))
(DFunDef false "stageBump" ((PVar "key")) (EMatch (EUnOp "!" (EVar "stageCountOn")) (arm (PCon "True") () (EApp (EApp (EVar "setRef") (EVar "stageCounts")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "+" (EApp (EVar "countOf") (EVar "key")) (ELit (LInt 1)))) (EUnOp "!" (EVar "stageCounts"))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig false "countOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countOf" ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "stageCounts"))) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "stageCountInit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageCountInit" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_STAGE_COUNTS"))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "setRef") (EVar "stageCountOn")) (EBinOp "/=" (EVar "v") (ELit (LString ""))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "stageDump" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDump" ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "stageCountOn")) (arm (PCon "True") () (EApp (EVar "stageDumpKeys") (EApp (EVar "omKeys") (EUnOp "!" (EVar "stageCounts"))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig true "stageExit" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageExit" ((PVar "code")) (EBlock (DoLet false false PWild (EApp (EVar "stageDump") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (EVar "code")))))
(DTypeSig false "stageDumpKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDumpKeys" ((PList)) (ELit LUnit))
(DFunDef false "stageDumpKeys" ((PCons (PVar "k") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[stage]\t")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "countOf") (EVar "k")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageDumpKeys") (EVar "rest")))))
