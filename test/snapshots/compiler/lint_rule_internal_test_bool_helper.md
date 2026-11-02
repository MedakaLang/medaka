# META
source_lines=129
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-test-bool-helper: a `-> Bool` helper in a `*_test.mdk` graded with `expectTrue`/`expectFalse`. Return an `Expect` from the helper instead.

import frontend.ast.{Expr(..), Decl(..), Ty(..)}
import frontend.ast_walk.{DeclBody(..), declBodies}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{anyList, endsWith}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  mkRule,
}
import tools.lint_shared.{
  appSpineOf,
  childExprs,
  mentionsVar,
  ruleNameTestBoolHelper,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameTestBoolHelper,
      summary =
        "a `-> Bool` helper in a `*_test.mdk` whose call is graded with `expectTrue`/`expectFalse`. Return an `Expect` (`expectErrContains`, `expectEqual`, ...) so a failure says what was expected",
      doc =
        "A `Bool` helper graded with `expectTrue`/`expectFalse` fails with \"expected True, got False\" and names nothing. Make the helper return an `Expect` built from the verb that fits (`expectErrContains`, `expectEqual`, `expectOk`, ...; see the `write-tests` table) and drop the `expectTrue`/`expectFalse` wrapper at its call sites. A helper that a `prop` in the same file references keeps `Bool`, because a prop's oracle is `Bool`. Covered call shapes: `expectTrue (h a b)`, `expectFalse (h a b)`, `h a b |> expectTrue`, `x |> h |> expectTrue`. Not covered: a call nested deeper in the argument (`expectTrue (a && h b)`, `expectTrue (not (h b))`).\n\nBefore:\n  rejects : String -> Bool\n  test \"t\" = expectTrue (rejects \"x\")\nAfter:\n  rejects : String -> Expect\n  test \"t\" = rejects \"x\"",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleTestBoolHelper
    None

-- ── rule: test-bool-helper (R38, R46) ─────────────────────────────────────────
-- File-local: the helper's declared signature and every call of it come from
-- the one file.  A helper counts when its signature ends in `Bool` (any arity,
-- a zero-argument `Bool` value included) and some call of it, with the helper
-- as the head of the graded expression, is the argument of `expectTrue` or
-- `expectFalse`.  The finding sits on the signature.  A `prop` is the one
-- consumer that needs `Bool`, so a helper any `prop` body mentions is exempt.
ruleTestBoolHelper : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleTestBoolHelper _ path _ _ decls
  | endsWith "_test.mdk" path =
    let graded = flatMap gradedHeads (allBodies decls)
    let propBodies = flatMap propBodyOf decls
    flatMap (helperFinding graded propBodies) decls
  | otherwise = []

helperFinding : List String -> List Expr -> Decl -> List Finding
helperFinding graded propBodies (DTypeSig _ name ty loc)
  | endsInBool ty
    && elem name graded
    && not (anyList (mentionsVar name) propBodies) = [
    Finding {
      rule = ruleNameTestBoolHelper,
      message =
        "`\{name}` returns `Bool` and is graded with `expectTrue`/`expectFalse`, which reports no expectation on failure. Return an `Expect` (for example `expectErrContains`, `expectEqual`) and drop the wrapper at its call sites",
      severity = SevWarning,
      loc = Some loc,
      fix = None,
    },
  ]
helperFinding graded propBodies (DAttrib _ d) =
  helperFinding graded propBodies d
helperFinding _ _ _ = []

endsInBool : Ty -> Bool
endsInBool (TyFun _ r) = endsInBool r
endsInBool (TyConstrained _ t) = endsInBool t
endsInBool (TyNamed _ t _) = endsInBool t
endsInBool (TyCon { tyConName = n }) = n == "Bool"
endsInBool _ = False

propBodyOf : Decl -> List Expr
propBodyOf (DProp _ _ _ body) = [body]
propBodyOf (DAttrib _ d) = propBodyOf d
propBodyOf _ = []

allBodies : List Decl -> List Expr
allBodies decls = flatMap (d => map bodyExpr (declBodies d)) decls

bodyExpr : DeclBody -> Expr
bodyExpr (DeclBody _ e) = e

-- The callee names of every expression graded by `expectTrue`/`expectFalse`
-- somewhere inside `e`.
gradedHeads : Expr -> List String
gradedHeads e = here (unwrapLoc e) ++ flatMap gradedHeads (childExprs e)

here : Expr -> List String
here (EApp f a)
  | isVerb f = headNames a
here (EBinOp "|>" a f _)
  | isVerb f = headNames a
here _ = []

isVerb : Expr -> Bool
isVerb f = match unwrapLoc f
  EVar "expectTrue" => True
  EVar "expectFalse" => True
  _ => False

-- The callee of a graded expression: the head of an application, or, for a
-- pipeline, the head of its last stage.
headNames : Expr -> List String
headNames e = match unwrapLoc e
  EBinOp "|>" _ rhs _ => headNames rhs
  other => match appSpineOf other
    (EVar n, _) => [n]
    _ => []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Decl" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "DeclBody" true) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "childExprs" false) (mem "mentionsVar" false) (mem "ruleNameTestBoolHelper" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolHelper")) (fa "summary" (ELit (LString "a `-> Bool` helper in a `*_test.mdk` whose call is graded with `expectTrue`/`expectFalse`. Return an `Expect` (`expectErrContains`, `expectEqual`, ...) so a failure says what was expected"))) (fa "doc" (ELit (LString "A `Bool` helper graded with `expectTrue`/`expectFalse` fails with \"expected True, got False\" and names nothing. Make the helper return an `Expect` built from the verb that fits (`expectErrContains`, `expectEqual`, `expectOk`, ...; see the `write-tests` table) and drop the `expectTrue`/`expectFalse` wrapper at its call sites. A helper that a `prop` in the same file references keeps `Bool`, because a prop's oracle is `Bool`. Covered call shapes: `expectTrue (h a b)`, `expectFalse (h a b)`, `h a b |> expectTrue`, `x |> h |> expectTrue`. Not covered: a call nested deeper in the argument (`expectTrue (a && h b)`, `expectTrue (not (h b))`).\n\nBefore:\n  rejects : String -> Bool\n  test \"t\" = expectTrue (rejects \"x\")\nAfter:\n  rejects : String -> Expect\n  test \"t\" = rejects \"x\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestBoolHelper")) (EVar "None")))
(DTypeSig false "ruleTestBoolHelper" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleTestBoolHelper" (PWild (PVar "path") PWild PWild (PVar "decls")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path")) (EBlock (DoLet false false (PVar "graded") (EApp (EApp (EVar "flatMap") (EVar "gradedHeads")) (EApp (EVar "allBodies") (EVar "decls")))) (DoLet false false (PVar "propBodies") (EApp (EApp (EVar "flatMap") (EVar "propBodyOf")) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "helperFinding") (EVar "graded")) (EVar "propBodies"))) (EVar "decls")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "helperFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "helperFinding" ((PVar "graded") (PVar "propBodies") (PCon "DTypeSig" PWild (PVar "name") (PVar "ty") (PVar "loc"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "endsInBool") (EVar "ty")) (EApp (EApp (EVar "elem") (EVar "name")) (EVar "graded"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "name"))) (EVar "propBodies")))) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestBoolHelper")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` returns `Bool` and is graded with `expectTrue`/`expectFalse`, which reports no expectation on failure. Return an `Expect` (for example `expectErrContains`, `expectEqual`) and drop the wrapper at its call sites")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "None"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "helperFinding" ((PVar "graded") (PVar "propBodies") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "helperFinding") (EVar "graded")) (EVar "propBodies")) (EVar "d")))
(DFunDef false "helperFinding" (PWild PWild PWild) (EListLit))
(DTypeSig false "endsInBool" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "endsInBool" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "endsInBool") (EVar "r")))
(DFunDef false "endsInBool" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "endsInBool") (EVar "t")))
(DFunDef false "endsInBool" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "endsInBool") (EVar "t")))
(DFunDef false "endsInBool" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "==" (EVar "n") (ELit (LString "Bool"))))
(DFunDef false "endsInBool" (PWild) (EVar "False"))
(DTypeSig false "propBodyOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "propBodyOf" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "propBodyOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "propBodyOf") (EVar "d")))
(DFunDef false "propBodyOf" (PWild) (EListLit))
(DTypeSig false "allBodies" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "allBodies" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "map") (EVar "bodyExpr")) (EApp (EVar "declBodies") (EVar "d"))))) (EVar "decls")))
(DTypeSig false "bodyExpr" (TyFun (TyCon "DeclBody") (TyCon "Expr")))
(DFunDef false "bodyExpr" ((PCon "DeclBody" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "gradedHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gradedHeads" ((PVar "e")) (EBinOp "++" (EApp (EVar "here") (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "flatMap") (EVar "gradedHeads")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "here" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "here" ((PCon "EApp" (PVar "f") (PVar "a"))) (EIf (EApp (EVar "isVerb") (EVar "f")) (EApp (EVar "headNames") (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "here" ((PCon "EBinOp" (PLit (LString "|>")) (PVar "a") (PVar "f") PWild)) (EIf (EApp (EVar "isVerb") (EVar "f")) (EApp (EVar "headNames") (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "here" (PWild) (EListLit))
(DTypeSig false "isVerb" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isVerb" ((PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PLit (LString "expectTrue"))) () (EVar "True")) (arm (PCon "EVar" (PLit (LString "expectFalse"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "headNames" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headNames" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "|>")) PWild (PVar "rhs") PWild) () (EApp (EVar "headNames") (EVar "rhs"))) (arm (PVar "other") () (EMatch (EApp (EVar "appSpineOf") (EVar "other")) (arm (PTuple (PCon "EVar" (PVar "n")) PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Decl" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "DeclBody" true) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "childExprs" false) (mem "mentionsVar" false) (mem "ruleNameTestBoolHelper" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolHelper")) (fa "summary" (ELit (LString "a `-> Bool` helper in a `*_test.mdk` whose call is graded with `expectTrue`/`expectFalse`. Return an `Expect` (`expectErrContains`, `expectEqual`, ...) so a failure says what was expected"))) (fa "doc" (ELit (LString "A `Bool` helper graded with `expectTrue`/`expectFalse` fails with \"expected True, got False\" and names nothing. Make the helper return an `Expect` built from the verb that fits (`expectErrContains`, `expectEqual`, `expectOk`, ...; see the `write-tests` table) and drop the `expectTrue`/`expectFalse` wrapper at its call sites. A helper that a `prop` in the same file references keeps `Bool`, because a prop's oracle is `Bool`. Covered call shapes: `expectTrue (h a b)`, `expectFalse (h a b)`, `h a b |> expectTrue`, `x |> h |> expectTrue`. Not covered: a call nested deeper in the argument (`expectTrue (a && h b)`, `expectTrue (not (h b))`).\n\nBefore:\n  rejects : String -> Bool\n  test \"t\" = expectTrue (rejects \"x\")\nAfter:\n  rejects : String -> Expect\n  test \"t\" = rejects \"x\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestBoolHelper")) (EVar "None")))
(DTypeSig false "ruleTestBoolHelper" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleTestBoolHelper" (PWild (PVar "path") PWild PWild (PVar "decls")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path")) (EBlock (DoLet false false (PVar "graded") (EApp (EApp (EDictApp "flatMap") (EVar "gradedHeads")) (EApp (EVar "allBodies") (EVar "decls")))) (DoLet false false (PVar "propBodies") (EApp (EApp (EDictApp "flatMap") (EVar "propBodyOf")) (EVar "decls"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "helperFinding") (EVar "graded")) (EVar "propBodies"))) (EVar "decls")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "helperFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "helperFinding" ((PVar "graded") (PVar "propBodies") (PCon "DTypeSig" PWild (PVar "name") (PVar "ty") (PVar "loc"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "endsInBool") (EVar "ty")) (EApp (EApp (EDictApp "elem") (EVar "name")) (EVar "graded"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "name"))) (EVar "propBodies")))) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestBoolHelper")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` returns `Bool` and is graded with `expectTrue`/`expectFalse`, which reports no expectation on failure. Return an `Expect` (for example `expectErrContains`, `expectEqual`) and drop the wrapper at its call sites")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "None"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "helperFinding" ((PVar "graded") (PVar "propBodies") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "helperFinding") (EVar "graded")) (EVar "propBodies")) (EVar "d")))
(DFunDef false "helperFinding" (PWild PWild PWild) (EListLit))
(DTypeSig false "endsInBool" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "endsInBool" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "endsInBool") (EVar "r")))
(DFunDef false "endsInBool" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "endsInBool") (EVar "t")))
(DFunDef false "endsInBool" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "endsInBool") (EVar "t")))
(DFunDef false "endsInBool" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "==" (EVar "n") (ELit (LString "Bool"))))
(DFunDef false "endsInBool" (PWild) (EVar "False"))
(DTypeSig false "propBodyOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "propBodyOf" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "propBodyOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "propBodyOf") (EVar "d")))
(DFunDef false "propBodyOf" (PWild) (EListLit))
(DTypeSig false "allBodies" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "allBodies" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EMethodRef "map") (EVar "bodyExpr")) (EApp (EVar "declBodies") (EVar "d"))))) (EVar "decls")))
(DTypeSig false "bodyExpr" (TyFun (TyCon "DeclBody") (TyCon "Expr")))
(DFunDef false "bodyExpr" ((PCon "DeclBody" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "gradedHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "gradedHeads" ((PVar "e")) (EBinOp "++" (EApp (EVar "here") (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EDictApp "flatMap") (EVar "gradedHeads")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "here" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "here" ((PCon "EApp" (PVar "f") (PVar "a"))) (EIf (EApp (EVar "isVerb") (EVar "f")) (EApp (EVar "headNames") (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "here" ((PCon "EBinOp" (PLit (LString "|>")) (PVar "a") (PVar "f") PWild)) (EIf (EApp (EVar "isVerb") (EVar "f")) (EApp (EVar "headNames") (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "here" (PWild) (EListLit))
(DTypeSig false "isVerb" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isVerb" ((PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PLit (LString "expectTrue"))) () (EVar "True")) (arm (PCon "EVar" (PLit (LString "expectFalse"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "headNames" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headNames" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "|>")) PWild (PVar "rhs") PWild) () (EApp (EVar "headNames") (EVar "rhs"))) (arm (PVar "other") () (EMatch (EApp (EVar "appSpineOf") (EVar "other")) (arm (PTuple (PCon "EVar" (PVar "n")) PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))))
