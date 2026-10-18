# META
source_lines=84
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

import list.{partition}
import string.{split, startsWith}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}
import support.util.{joinNl}

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

stagePrefix : String
stagePrefix = "[stage]\t"

-- True for a line `stageDump` printed; the build driver separates a child's
-- stage lines from its other stderr with it.
export
isStageLine : String -> Bool
isStageLine l = startsWith stagePrefix l

-- A child process's `[stage]` lines belong to this process's stderr on every
-- route, `--json` included, so they are lifted out of the child's captured
-- stderr before any route decides what to embed or forward.  The rest of the
-- child's stream is returned unchanged when it has no stage lines.
export
forwardStageLines : String -> <IO> String
forwardStageLines err =
  let (stage, rest) = partition isStageLine (split "\n" err)
  let _ = match stage
    [] => ()
    _ => ePutStrLn (joinNl stage)
  joinNl rest

stageDumpKeys : List String -> <IO> Unit
stageDumpKeys [] = ()
stageDumpKeys (k :: rest) =
  let _ = ePutStrLn "\{stagePrefix}\{k}\t\{countOf k}"
  stageDumpKeys rest
# DESUGAR
(DUse false (UseGroup ("list") ((mem "partition" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
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
(DTypeSig false "stagePrefix" (TyCon "String"))
(DFunDef false "stagePrefix" () (ELit (LString "[stage]\t")))
(DTypeSig true "isStageLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStageLine" ((PVar "l")) (EApp (EApp (EVar "startsWith") (EVar "stagePrefix")) (EVar "l")))
(DTypeSig true "forwardStageLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "forwardStageLines" ((PVar "err")) (EBlock (DoLet false false (PTuple (PVar "stage") (PVar "rest")) (EApp (EApp (EVar "partition") (EVar "isStageLine")) (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "err")))) (DoLet false false PWild (EMatch (EVar "stage") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "stage")))))) (DoExpr (EApp (EVar "joinNl") (EVar "rest")))))
(DTypeSig false "stageDumpKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDumpKeys" ((PList)) (ELit LUnit))
(DFunDef false "stageDumpKeys" ((PCons (PVar "k") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "stagePrefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "countOf") (EVar "k")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageDumpKeys") (EVar "rest")))))
# MARK
(DUse false (UseGroup ("list") ((mem "partition" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
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
(DTypeSig false "stagePrefix" (TyCon "String"))
(DFunDef false "stagePrefix" () (ELit (LString "[stage]\t")))
(DTypeSig true "isStageLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStageLine" ((PVar "l")) (EApp (EApp (EVar "startsWith") (EVar "stagePrefix")) (EVar "l")))
(DTypeSig true "forwardStageLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "forwardStageLines" ((PVar "err")) (EBlock (DoLet false false (PTuple (PVar "stage") (PVar "rest")) (EApp (EApp (EVar "partition") (EVar "isStageLine")) (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "err")))) (DoLet false false PWild (EMatch (EVar "stage") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "stage")))))) (DoExpr (EApp (EVar "joinNl") (EVar "rest")))))
(DTypeSig false "stageDumpKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "stageDumpKeys" ((PList)) (ELit LUnit))
(DFunDef false "stageDumpKeys" ((PCons (PVar "k") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "stagePrefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "countOf") (EVar "k")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageDumpKeys") (EVar "rest")))))
