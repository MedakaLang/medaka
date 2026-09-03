# META
source_lines=188
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted `test "…" = <expr>` runner (Phase 127 restored 2026-07-11).
--
-- A `test "name" = body` declaration is symmetric with `prop`: the host
-- (test_cmd.mdk) discovers every `DTest` decl, evaluates its body to an
-- `Expectation` VALUE (never catching panics — a genuinely-crashing body is
-- unrecoverable and aborts the run, per the `no-catchable-panics` invariant),
-- and reports pass/fail using the SAME reporting shape as doctests (ok/FAIL +
-- loc + per-file summary + exit code, P0-6).
--
-- This module owns discovery (`collectTests`/`hasTests`) and the single-body
-- evaluator (`runOneTest`); test_cmd owns the incremental print loop + summary
-- (it can't live here — test_cmd imports this module, not the reverse).  Like
-- prop_runner, results are printed AS each test is evaluated, so a body that
-- aborts the run does not mask the tests that already passed.

import frontend.ast.{Decl, DAttrib, DExtern, DFunDef, DTest, Expr(..), Loc(..)}
import frontend.marker.{declRefs, localBoundNames}
import eval.eval.{Value(..), EvalEnv(..), eval, extendEnv, force, ppValue}
import support.util.{filterList}
import tools.doctest.{ExResult(..)}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}

-- True iff the program declares at least one `test "…"`.
export
hasTests : List Decl -> Bool
hasTests [] = False
hasTests ((DTest _ _ _) :: _) = True
hasTests (_ :: rest) = hasTests rest

-- Line number of a body expr (peel the transparent ELoc wrapper).
exprLine : Expr -> Int
exprLine (ELoc (Loc _ l _ _ _) _) = l
exprLine (EApp f _) = exprLine f
exprLine (EAnnot e _) = exprLine e
exprLine (EHeadAnnot e _) = exprLine e
exprLine _ = 0

-- Each `test "…" = body` as (name, line, body), in source order.
export
collectTests : List Decl -> List (String, Int, Expr)
collectTests [] = []
collectTests ((DTest _ name body) :: rest) =
  (name, exprLine body, body) :: collectTests rest
collectTests (_ :: rest) = collectTests rest

-- One rendered operand out of an `Expectation` payload.  The field is already
-- a `String` in every assertion stdlib `test.mdk` builds, so the `ppValue`
-- arm is for a hand-built `Expectation` carrying something else.
operandText : Value e -> <e> String
operandText v = match force v
  VString s => s
  other => ppValue other

-- Evaluate one test body to an Expectation value and classify it.  A body that
-- does not reduce to Pass/Fail is an `Errored` (e.g. a partial closure); a body
-- that genuinely panics is unrecoverable and aborts the whole run.
export
runOneTest : List (String, Value e) -> Expr -> <e> ExResult
runOneTest evalEnv body =
  let env = extendEnv (EvalEnv [[]]) evalEnv
  match force (eval env body)
    VCon "Pass" [e, a] => Pass (operandText e) (operandText a)
    VCon "Fail" [m, e, a] =>
      Fail (operandText m) (operandText e) (operandText a)
    other =>
      Errored
        ("test body did not evaluate to an Expectation: " ++ ppValue other)

-- ── the eval arm's capability pre-check (#2588) ──────────────────────────────
-- `medaka test` runs `test "…"` bodies under a capability policy
-- (eval.testCapableExterns): the clock, the GC counter and stderr, and nothing
-- that touches the filesystem, the environment, stdin, the network, or another
-- process.  An extern outside that policy is simply ABSENT from the evaluation
-- environment, so reaching one used to surface as `unbound identifier
-- runCommand` from inside eval — a message about the interpreter's internals,
-- attributed to no test, raised after some tests had already run.
--
-- This answers the same question BEFORE anything runs, and answers it by name:
-- which externs can the file's `test "…"` bodies reach that the environment
-- does not bind?  The reachable set is computed over the SAME elaborated decls
-- the interpreter will evaluate, transitively, so a body calling a safe-looking
-- stdlib wrapper (`runCommandOk`) is caught by the extern underneath it.
--
-- ⚠️ It is an OVER-approximation of what the run would EXECUTE (a branch never
-- taken still counts) and an UNDER-approximation of the call graph (a reference
-- reached only through a dictionary-passed method is not walked, and a decl
-- that binds a name locally is treated as not referencing the global of that
-- name anywhere in it).  Missing a reference is safe — eval's own panic still
-- catches it.  INVENTING one is not, which is why the local binders are
-- subtracted: `runCommandOk cmd args` has a PARAMETER named `args`, and without
-- the subtraction every file reaching it was refused for the `args` extern it
-- does not touch.
export
uncapableExterns : List Decl ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  List String
uncapableExterns corpus env tests =
  let unbound = unboundExternNames corpus (boundNameSet env)
  match unbound
    [] => []
    _ =>
      let seen = new ()
      let _ =
        closureOver
          (refGraph corpus)
          seen
          (flatMap (t => freeRefsOf (DFunDef False "" [] (thd3 t))) tests)
      filterList (n => has n seen) unbound

thd3 : (a, b, c) -> c
thd3 (_, _, c) = c

boundNameSet : List (String, Value e) -> HashMap String Unit
boundNameSet env =
  let s = new ()
  let _ = insertNames (map fst env) s
  s

insertNames : List String -> HashMap String Unit -> Unit
insertNames [] _ = ()
insertNames (n :: rest) s =
  let _ = setInPlace n () s
  insertNames rest s

-- Every `extern` the corpus declares that the environment does not bind, in
-- declaration order and without duplicates.
unboundExternNames : List Decl -> HashMap String Unit -> List String
unboundExternNames corpus bound = externScan corpus bound (new ())

externScan : List Decl ->
  HashMap String Unit ->
  HashMap String Unit ->
  List String
externScan [] _ _ = []
externScan ((DAttrib _ d) :: rest) bound emitted =
  externScan (d :: rest) bound emitted
externScan ((DExtern _ n _) :: rest) bound emitted
  | has n bound || has n emitted = externScan rest bound emitted
  | otherwise =
    let _ = setInPlace n () emitted
    n :: externScan rest bound emitted
externScan (_ :: rest) bound emitted = externScan rest bound emitted

-- The names a decl references GLOBALLY: everything its bodies mention, minus
-- everything it binds locally (its own parameters included).  `dce.mdk` walks
-- the unsubtracted `declRefs` because keeping too much code is harmless there;
-- here an extra name is a wrong accusation, so the binders come off.
freeRefsOf : Decl -> List String
freeRefsOf d =
  let bound = new ()
  let _ = insertNames (localBoundNames [d]) bound
  filterList (n => not (has n bound)) (declRefs d)

-- name -> globally-referenced names, over every decl that carries a body.  No
-- `core__` canonicalization: extern names are never mangled.
refGraph : List Decl -> HashMap String (List String)
refGraph decls =
  let g = new ()
  let _ = refGraphInto decls g
  g

refGraphInto : List Decl -> HashMap String (List String) -> Unit
refGraphInto [] _ = ()
refGraphInto ((DAttrib _ d) :: rest) g = refGraphInto (d :: rest) g
refGraphInto ((DFunDef _ n ps body) :: rest) g =
  let _ =
    setInPlace
      n
      (freeRefsOf (DFunDef False n ps body) ++ findWithDefault [] n g)
      g
  refGraphInto rest g
-- A non-function body (impl method, interface default, let group) has no single
-- name for the walk to arrive at, so it contributes no edge.  That is the
-- under-approximation the header names: an extern reachable ONLY through a
-- dictionary-passed method is missed here and still caught by eval's panic.
refGraphInto (_ :: rest) g = refGraphInto rest g

closureOver : HashMap String (List String) ->
  HashMap String Unit ->
  List String ->
  Unit
closureOver _ _ [] = ()
closureOver graph seen (w :: work)
  | has w seen = closureOver graph seen work
  | otherwise =
    let _ = setInPlace w () seen
    closureOver graph seen (findWithDefault [] w graph ++ work)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DAttrib" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DTest" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "hasTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasTests" ((PList)) (EVar "False"))
(DFunDef false "hasTests" ((PCons (PCon "DTest" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTests") (EVar "rest")))
(DTypeSig false "exprLine" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLine" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLine" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLine") (EVar "f")))
(DFunDef false "exprLine" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" (PWild) (ELit (LInt 0)))
(DTypeSig true "collectTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "collectTests" ((PList)) (EListLit))
(DFunDef false "collectTests" ((PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body")) (EVar "body")) (EApp (EVar "collectTests") (EVar "rest"))))
(DFunDef false "collectTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectTests") (EVar "rest")))
(DTypeSig false "operandText" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyCon "String"))))
(DFunDef false "operandText" ((PVar "v")) (EMatch (EApp (EVar "force") (EVar "v")) (arm (PCon "VString" (PVar "s")) () (EVar "s")) (arm (PVar "other") () (EApp (EVar "ppValue") (EVar "other")))))
(DTypeSig true "runOneTest" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyCon "ExResult")))))
(DFunDef false "runOneTest" ((PVar "evalEnv") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VCon" (PLit (LString "Pass")) (PList (PVar "e") (PVar "a"))) () (EApp (EApp (EVar "Pass") (EApp (EVar "operandText") (EVar "e"))) (EApp (EVar "operandText") (EVar "a")))) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PVar "m") (PVar "e") (PVar "a"))) () (EApp (EApp (EApp (EVar "Fail") (EApp (EVar "operandText") (EVar "m"))) (EApp (EVar "operandText") (EVar "e"))) (EApp (EVar "operandText") (EVar "a")))) (arm (PVar "other") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "test body did not evaluate to an Expectation: ")) (EApp (EVar "ppValue") (EVar "other")))))))))
(DTypeSig true "uncapableExterns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "uncapableExterns" ((PVar "corpus") (PVar "env") (PVar "tests")) (EBlock (DoLet false false (PVar "unbound") (EApp (EApp (EVar "unboundExternNames") (EVar "corpus")) (EApp (EVar "boundNameSet") (EVar "env")))) (DoExpr (EMatch (EVar "unbound") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closureOver") (EApp (EVar "refGraph") (EVar "corpus"))) (EVar "seen")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "t")) (EApp (EVar "freeRefsOf") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (ELit (LString ""))) (EListLit)) (EApp (EVar "thd3") (EVar "t")))))) (EVar "tests")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")))) (EVar "unbound")))))))))
(DTypeSig false "thd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "c")))
(DFunDef false "thd3" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig false "boundNameSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "boundNameSet" ((PVar "env")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "insertNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "env"))) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "insertNames" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertNames" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "insertNames") (EVar "rest")) (EVar "s")))))
(DTypeSig false "unboundExternNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unboundExternNames" ((PVar "corpus") (PVar "bound")) (EApp (EApp (EApp (EVar "externScan") (EVar "corpus")) (EVar "bound")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig false "externScan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "externScan" ((PList) PWild PWild) (EListLit))
(DFunDef false "externScan" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "bound") (PVar "emitted")) (EApp (EApp (EApp (EVar "externScan") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "bound")) (EVar "emitted")))
(DFunDef false "externScan" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest")) (PVar "bound") (PVar "emitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "has") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "emitted"))) (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "emitted"))) (DoExpr (EBinOp "::" (EVar "n") (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "externScan" ((PCons PWild (PVar "rest")) (PVar "bound") (PVar "emitted")) (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted")))
(DTypeSig false "freeRefsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "freeRefsOf" ((PVar "d")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "insertNames") (EApp (EVar "localBoundNames") (EListLit (EVar "d")))) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "bound"))))) (EApp (EVar "declRefs") (EVar "d"))))))
(DTypeSig false "refGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "refGraphInto") (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "refGraphInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "refGraphInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "refGraphInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EVar "refGraphInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "refGraphInto" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body")) (PVar "rest")) (PVar "g")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EVar "freeRefsOf") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body"))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EVar "refGraphInto") (EVar "rest")) (EVar "g")))))
(DFunDef false "refGraphInto" ((PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EVar "refGraphInto") (EVar "rest")) (EVar "g")))
(DTypeSig false "closureOver" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closureOver" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closureOver" ((PVar "graph") (PVar "seen") (PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closureOver") (EVar "graph")) (EVar "seen")) (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closureOver") (EVar "graph")) (EVar "seen")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DAttrib" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DTest" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "hasTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasTests" ((PList)) (EVar "False"))
(DFunDef false "hasTests" ((PCons (PCon "DTest" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTests") (EVar "rest")))
(DTypeSig false "exprLine" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLine" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLine" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLine") (EVar "f")))
(DFunDef false "exprLine" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" (PWild) (ELit (LInt 0)))
(DTypeSig true "collectTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "collectTests" ((PList)) (EListLit))
(DFunDef false "collectTests" ((PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body")) (EVar "body")) (EApp (EVar "collectTests") (EVar "rest"))))
(DFunDef false "collectTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectTests") (EVar "rest")))
(DTypeSig false "operandText" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyCon "String"))))
(DFunDef false "operandText" ((PVar "v")) (EMatch (EApp (EVar "force") (EVar "v")) (arm (PCon "VString" (PVar "s")) () (EVar "s")) (arm (PVar "other") () (EApp (EVar "ppValue") (EVar "other")))))
(DTypeSig true "runOneTest" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyCon "ExResult")))))
(DFunDef false "runOneTest" ((PVar "evalEnv") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VCon" (PLit (LString "Pass")) (PList (PVar "e") (PVar "a"))) () (EApp (EApp (EVar "Pass") (EApp (EVar "operandText") (EVar "e"))) (EApp (EVar "operandText") (EVar "a")))) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PVar "m") (PVar "e") (PVar "a"))) () (EApp (EApp (EApp (EVar "Fail") (EApp (EVar "operandText") (EVar "m"))) (EApp (EVar "operandText") (EVar "e"))) (EApp (EVar "operandText") (EVar "a")))) (arm (PVar "other") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "test body did not evaluate to an Expectation: ")) (EApp (EVar "ppValue") (EVar "other")))))))))
(DTypeSig true "uncapableExterns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "uncapableExterns" ((PVar "corpus") (PVar "env") (PVar "tests")) (EBlock (DoLet false false (PVar "unbound") (EApp (EApp (EVar "unboundExternNames") (EVar "corpus")) (EApp (EVar "boundNameSet") (EVar "env")))) (DoExpr (EMatch (EVar "unbound") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closureOver") (EApp (EVar "refGraph") (EVar "corpus"))) (EVar "seen")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "t")) (EApp (EVar "freeRefsOf") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (ELit (LString ""))) (EListLit)) (EApp (EVar "thd3") (EVar "t")))))) (EVar "tests")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")))) (EVar "unbound")))))))))
(DTypeSig false "thd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "c")))
(DFunDef false "thd3" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig false "boundNameSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "boundNameSet" ((PVar "env")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "insertNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "env"))) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "insertNames" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertNames" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "insertNames") (EVar "rest")) (EVar "s")))))
(DTypeSig false "unboundExternNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unboundExternNames" ((PVar "corpus") (PVar "bound")) (EApp (EApp (EApp (EVar "externScan") (EVar "corpus")) (EVar "bound")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig false "externScan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "externScan" ((PList) PWild PWild) (EListLit))
(DFunDef false "externScan" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "bound") (PVar "emitted")) (EApp (EApp (EApp (EVar "externScan") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "bound")) (EVar "emitted")))
(DFunDef false "externScan" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest")) (PVar "bound") (PVar "emitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "has") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "emitted"))) (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "emitted"))) (DoExpr (EBinOp "::" (EVar "n") (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "externScan" ((PCons PWild (PVar "rest")) (PVar "bound") (PVar "emitted")) (EApp (EApp (EApp (EVar "externScan") (EVar "rest")) (EVar "bound")) (EVar "emitted")))
(DTypeSig false "freeRefsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "freeRefsOf" ((PVar "d")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "insertNames") (EApp (EVar "localBoundNames") (EListLit (EVar "d")))) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "bound"))))) (EApp (EVar "declRefs") (EVar "d"))))))
(DTypeSig false "refGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "refGraphInto") (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "refGraphInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "refGraphInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "refGraphInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EVar "refGraphInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "refGraphInto" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body")) (PVar "rest")) (PVar "g")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EVar "freeRefsOf") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body"))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EVar "refGraphInto") (EVar "rest")) (EVar "g")))))
(DFunDef false "refGraphInto" ((PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EVar "refGraphInto") (EVar "rest")) (EVar "g")))
(DTypeSig false "closureOver" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closureOver" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closureOver" ((PVar "graph") (PVar "seen") (PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closureOver") (EVar "graph")) (EVar "seen")) (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closureOver") (EVar "graph")) (EVar "seen")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
