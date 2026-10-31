# META
source_lines=152
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-eager-default: a call passed as an always-evaluated default. `optionOr d o` and `resultOr d r` evaluate `d` even when `o` holds a value; `optionOrElse` and `resultOrElse` take a function and run it only on the miss.

import frontend.ast.{Decl, Expr(..), Loc, Pat(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_fix.{Binding(..)}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  calledName,
  exprRuleEditVisitors,
  isCtorName,
  isFalseLit,
  noExcl,
  oneLine,
  rebinds,
  replaceFix,
  ruleNameEagerDefault,
  tightSpan,
  unwrapLoc,
  usesPreludeName,
}
import frontend.parser.{Positions(..)}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameEagerDefault,
      summary =
        "a call passed as the default of `optionOr`/`resultOr`, or as the argument of `whenL False`: it runs although its result is discarded. Use `optionOrElse`/`resultOrElse`",
      doc =
        "`optionOr d o` and `resultOr d r` are ordinary calls, so `d` is evaluated before the call even when `o` is `Some` or `r` is `Ok`. A default that is a call is wasted work on every hit, and an effect or a panic in it happens anyway. `optionOrElse` and `resultOrElse` take a function that runs on the miss only. A literal, a variable, a tuple, an operator expression or a constructor application is not reported, and neither is a partial application such as `map (optionOr d) xs`, which the lazy form would run once per miss.\n\n`whenL False (f x)` is reported without a fix: its argument is evaluated although the guard is `False`.\n\nBefore:\n  optionOr (freshVar ctx ()) (lookup n sub)\nAfter:\n  optionOrElse (_ => freshVar ctx ()) (lookup n sub)",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = FixableUnsafe,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    ruleEagerDefault
    None

-- ── detector ──────────────────────────────────────────────────────────────────
-- The fix is `Unsafe`: a default that performs an effect or panics no longer
-- does so on the hit path, which is the point of the rewrite and still a change
-- a reader should look at.  Only a call applied to its option or result is
-- reported: a partial `optionOr d` may be applied many times (`map (optionOr d)
-- xs`), and the lazy form runs the default once per miss where the eager one ran
-- it once, so there the rewrite can change a result.

-- The head name of an application spine.
spineHead : Expr -> Expr
spineHead e = match unwrapLoc e
  EApp f _ => spineHead f
  other => other

-- A call: an application whose head is not a constructor.
isCall : Expr -> Bool
isCall e = match unwrapLoc e
  EApp f _ => match spineHead f
    EVar n => not (isCtorName n)
    _ => True
  _ => False

lazyName : String -> Option String
lazyName "optionOr" = Some "optionOrElse"
lazyName "resultOr" = Some "resultOrElse"
lazyName _ = None

-- `optionOr d o` / `resultOr d o` with a call for `d`: the lazy call that
-- replaces the function `optionOr d`.  `whenL False d` with a call for `d`: the
-- node itself, reported with no fix.
eagerOf : StdlibIndex -> FileFacts -> Expr -> Option Expr
eagerOf idx facts (EApp f x) = match unwrapLoc f
  EApp hd d => match unwrapLoc hd
    EVar "whenL" => if isFalseLit d && isCall x then Some (EApp f x) else None
    EVar n => match lazyName n
      Some lazy =>
        if isCall d && usesPreludeName idx facts hd then
          Some (EApp (EVar lazy) (ELam [PWild] d))
        else
          None
      None => None
    _ => None
  _ => None
eagerOf _ _ _ = None

-- A rewrite is withheld where the file binds the name it writes, or where the
-- enclosing method is that name.  The edit replaces the function `optionOr d`
-- of the call `optionOr d o`, which stands bare in function position and so
-- takes no brackets.
isWhenL : Expr -> Bool
isWhenL e = calledName e == "whenL"

eagerEdit : StdlibIndex -> FileFacts -> Ctx -> Expr -> Expr -> Option Fix
eagerEdit idx facts ctx (EApp f _) rewritten =
  if isWhenL rewritten || rebinds idx facts ctx (calledName rewritten) then
    None
  else
    replaceFix
      Unsafe
      "run the default only on a miss"
      (tightSpan f)
      Closed
      ctx
      (exprToString rewritten)
eagerEdit _ _ _ _ _ = None

eagerFinding : Option Loc -> Expr -> Option Fix -> Finding
eagerFinding loc rewritten fix = Finding {
  rule = ruleNameEagerDefault,
  message =
    if isWhenL rewritten then
      "the argument of 'whenL False' is evaluated although the guard is False"
    else
      "this default is evaluated even when the value is present — rewrite as '"
        ++ oneLine (exprToString rewritten)
        ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

ruleEagerDefault : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleEagerDefault idx _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    (eagerOf idx facts)
    (eagerEdit idx facts)
    eagerFinding
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "calledName" false) (mem "exprRuleEditVisitors" false) (mem "isCtorName" false) (mem "isFalseLit" false) (mem "noExcl" false) (mem "oneLine" false) (mem "rebinds" false) (mem "replaceFix" false) (mem "ruleNameEagerDefault" false) (mem "tightSpan" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameEagerDefault")) (fa "summary" (ELit (LString "a call passed as the default of `optionOr`/`resultOr`, or as the argument of `whenL False`: it runs although its result is discarded. Use `optionOrElse`/`resultOrElse`"))) (fa "doc" (ELit (LString "`optionOr d o` and `resultOr d r` are ordinary calls, so `d` is evaluated before the call even when `o` is `Some` or `r` is `Ok`. A default that is a call is wasted work on every hit, and an effect or a panic in it happens anyway. `optionOrElse` and `resultOrElse` take a function that runs on the miss only. A literal, a variable, a tuple, an operator expression or a constructor application is not reported, and neither is a partial application such as `map (optionOr d) xs`, which the lazy form would run once per miss.\n\n`whenL False (f x)` is reported without a fix: its argument is evaluated although the guard is `False`.\n\nBefore:\n  optionOr (freshVar ctx ()) (lookup n sub)\nAfter:\n  optionOrElse (_ => freshVar ctx ()) (lookup n sub)"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleEagerDefault")) (EVar "None")))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "isCall" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isCall" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EMatch (EApp (EVar "spineHead") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "not") (EApp (EVar "isCtorName") (EVar "n")))) (arm PWild () (EVar "True")))) (arm PWild () (EVar "False"))))
(DTypeSig false "lazyName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lazyName" ((PLit (LString "optionOr"))) (EApp (EVar "Some") (ELit (LString "optionOrElse"))))
(DFunDef false "lazyName" ((PLit (LString "resultOr"))) (EApp (EVar "Some") (ELit (LString "resultOrElse"))))
(DFunDef false "lazyName" (PWild) (EVar "None"))
(DTypeSig false "eagerOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "eagerOf" ((PVar "idx") (PVar "facts") (PCon "EApp" (PVar "f") (PVar "x"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EApp" (PVar "hd") (PVar "d")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PLit (LString "whenL"))) () (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "d")) (EApp (EVar "isCall") (EVar "x"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "None"))) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "lazyName") (EVar "n")) (arm (PCon "Some" (PVar "lazy")) () (EIf (EBinOp "&&" (EApp (EVar "isCall") (EVar "d")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "lazy"))) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EVar "d")))) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DFunDef false "eagerOf" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "isWhenL" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isWhenL" ((PVar "e")) (EBinOp "==" (EApp (EVar "calledName") (EVar "e")) (ELit (LString "whenL"))))
(DTypeSig false "eagerEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "eagerEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PCon "EApp" (PVar "f") PWild) (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EVar "isWhenL") (EVar "rewritten")) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EApp (EVar "calledName") (EVar "rewritten")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Unsafe")) (ELit (LString "run the default only on a miss"))) (EApp (EVar "tightSpan") (EVar "f"))) (EVar "Closed")) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DFunDef false "eagerEdit" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "eagerFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "eagerFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameEagerDefault")) (fa "message" (EIf (EApp (EVar "isWhenL") (EVar "rewritten")) (ELit (LString "the argument of 'whenL False' is evaluated although the guard is False")) (EBinOp "++" (EBinOp "++" (ELit (LString "this default is evaluated even when the value is present — rewrite as '")) (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'"))))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "ruleEagerDefault" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleEagerDefault" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EApp (EApp (EVar "eagerOf") (EVar "idx")) (EVar "facts"))) (EApp (EApp (EVar "eagerEdit") (EVar "idx")) (EVar "facts"))) (EVar "eagerFinding")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "calledName" false) (mem "exprRuleEditVisitors" false) (mem "isCtorName" false) (mem "isFalseLit" false) (mem "noExcl" false) (mem "oneLine" false) (mem "rebinds" false) (mem "replaceFix" false) (mem "ruleNameEagerDefault" false) (mem "tightSpan" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameEagerDefault")) (fa "summary" (ELit (LString "a call passed as the default of `optionOr`/`resultOr`, or as the argument of `whenL False`: it runs although its result is discarded. Use `optionOrElse`/`resultOrElse`"))) (fa "doc" (ELit (LString "`optionOr d o` and `resultOr d r` are ordinary calls, so `d` is evaluated before the call even when `o` is `Some` or `r` is `Ok`. A default that is a call is wasted work on every hit, and an effect or a panic in it happens anyway. `optionOrElse` and `resultOrElse` take a function that runs on the miss only. A literal, a variable, a tuple, an operator expression or a constructor application is not reported, and neither is a partial application such as `map (optionOr d) xs`, which the lazy form would run once per miss.\n\n`whenL False (f x)` is reported without a fix: its argument is evaluated although the guard is `False`.\n\nBefore:\n  optionOr (freshVar ctx ()) (lookup n sub)\nAfter:\n  optionOrElse (_ => freshVar ctx ()) (lookup n sub)"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleEagerDefault")) (EVar "None")))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "isCall" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isCall" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EMatch (EApp (EVar "spineHead") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "not") (EApp (EVar "isCtorName") (EVar "n")))) (arm PWild () (EVar "True")))) (arm PWild () (EVar "False"))))
(DTypeSig false "lazyName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lazyName" ((PLit (LString "optionOr"))) (EApp (EVar "Some") (ELit (LString "optionOrElse"))))
(DFunDef false "lazyName" ((PLit (LString "resultOr"))) (EApp (EVar "Some") (ELit (LString "resultOrElse"))))
(DFunDef false "lazyName" (PWild) (EVar "None"))
(DTypeSig false "eagerOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "eagerOf" ((PVar "idx") (PVar "facts") (PCon "EApp" (PVar "f") (PVar "x"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EApp" (PVar "hd") (PVar "d")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PLit (LString "whenL"))) () (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "d")) (EApp (EVar "isCall") (EVar "x"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "None"))) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "lazyName") (EVar "n")) (arm (PCon "Some" (PVar "lazy")) () (EIf (EBinOp "&&" (EApp (EVar "isCall") (EVar "d")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "lazy"))) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EVar "d")))) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DFunDef false "eagerOf" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "isWhenL" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isWhenL" ((PVar "e")) (EBinOp "==" (EApp (EVar "calledName") (EVar "e")) (ELit (LString "whenL"))))
(DTypeSig false "eagerEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "eagerEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PCon "EApp" (PVar "f") PWild) (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EVar "isWhenL") (EVar "rewritten")) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EApp (EVar "calledName") (EVar "rewritten")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Unsafe")) (ELit (LString "run the default only on a miss"))) (EApp (EVar "tightSpan") (EVar "f"))) (EVar "Closed")) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DFunDef false "eagerEdit" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "eagerFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "eagerFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameEagerDefault")) (fa "message" (EIf (EApp (EVar "isWhenL") (EVar "rewritten")) (ELit (LString "the argument of 'whenL False' is evaluated although the guard is False")) (EBinOp "++" (EBinOp "++" (ELit (LString "this default is evaluated even when the value is present — rewrite as '")) (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'"))))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "ruleEagerDefault" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleEagerDefault" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EApp (EApp (EVar "eagerOf") (EVar "idx")) (EVar "facts"))) (EApp (EApp (EVar "eagerEdit") (EVar "idx")) (EVar "facts"))) (EVar "eagerFinding")))
