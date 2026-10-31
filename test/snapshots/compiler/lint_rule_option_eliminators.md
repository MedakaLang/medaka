# META
source_lines=192
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-option-eliminators: an Option/Result eliminator written as a 2-arm `match` that a prelude function names. Prefer `optionOr`, `optionOrPanic`, `isSome`, `isNone`, `resultOr`.

import frontend.ast.{
  Arm(..),
  Decl(..),
  Expr(..),
  Loc(..),
  Pat(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{isEmptyL}
import tools.printer.{exprToString}
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
  bindingOf,
  calledName,
  exprRuleEditVisitors,
  isEVarNamed,
  isNilPCon,
  matchSpan,
  movableDefault,
  oneLine,
  noExcl,
  rebinds,
  replaceFix,
  ruleNameOptionEliminators,
  unwrapLoc,
  usesPreludeName,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameOptionEliminators,
      summary =
        "2-arm `match` on an Option/Result that unwraps with a literal, constructor or local-variable default, panics with a message, or answers whether it is `Some`. The prelude names these: `optionOr`, `optionOrPanic`, `isSome`, `isNone`, `resultOr`",
      doc =
        "A two-arm `match` that returns the payload of `Some`/`Ok` and otherwise a literal, a nullary constructor or a local variable is `optionOr`/`resultOr`; one that otherwise panics with a message is `optionOrPanic`; one that only answers `True`/`False` is `isSome`/`isNone`. A default that is a call or a top-level value is left alone: the function form evaluates it eagerly. The `optionOrPanic` fix needs `--unsafe-fixes`, because a native panic through it loses the call site's location.\n\nBefore:\n  match o\n    Some x => x\n    None => 0\nAfter:\n  optionOr 0 o",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    ruleOptionEliminators
    None

-- A default the function form can take in place of the arm without changing
-- when it is evaluated or whether it is: a literal, a nullary constructor or a
-- locally bound variable (`movableDefault`).  A call is excluded, because
-- `optionOr d o` evaluates `d` even when `o` is `Some`; so is a top-level value,
-- which `run` forces on first use.
isBoolLit : Bool -> Expr -> Bool
isBoolLit b e = match unwrapLoc e
  EVar n => n == (if b then "True" else "False")
  _ => False

call1 : String -> Expr -> Expr -> Expr
call1 fn arg scrut = EApp (EApp (EVar fn) arg) scrut

-- `Some x => x` / `Ok x => x`: the success arm hands its payload back.
isIdentityArm : String -> Pat -> Expr -> Bool
isIdentityArm ctor (PCon c [PVar x _ _]) body = c == ctor && isEVarNamed x body
isIdentityArm _ _ _ = False

-- `panic m` with a movable message.
panicMessage : FileFacts -> Expr -> Option Expr
panicMessage facts body = match unwrapLoc body
  EApp hd m =>
    if isEVarNamed "panic" hd && movableDefault facts m then Some m else None
  _ => None

-- (success arm, failure arm) in this order.
elimPair : FileFacts -> Expr -> Arm -> Arm -> Option Expr
elimPair facts scrut (Arm ps gs bs) (Arm pf gf bf)
  | not (isEmptyL gs && isEmptyL gf) = None
  | isIdentityArm "Some" ps bs && isNilPCon "None" pf =
    if movableDefault facts bf then
      Some (call1 "optionOr" bf scrut)
    else
      map (m => call1 "optionOrPanic" m scrut) (panicMessage facts bf)
  | isIdentityArm "Ok" ps bs && isErrWild pf && movableDefault facts bf =
    Some (call1 "resultOr" bf scrut)
  | isSomeWild ps
    && isNilPCon "None" pf
    && isBoolLit True bs
    && isBoolLit False bf = Some (EApp (EVar "isSome") scrut)
  | isSomeWild ps
    && isNilPCon "None" pf
    && isBoolLit False bs
    && isBoolLit True bf = Some (EApp (EVar "isNone") scrut)
  | otherwise = None

isSomeWild : Pat -> Bool
isSomeWild (PCon "Some" [PWild]) = True
isSomeWild _ = False

isErrWild : Pat -> Bool
isErrWild (PCon "Err" [PWild]) = True
isErrWild _ = False

-- detector (matches the RAW `EMatch`, never its `ELoc` wrapper); either arm order.
optionElimOf : FileFacts -> Expr -> Option Expr
optionElimOf facts (EMatch scrut arms) = match arms
  [a1, a2] => orElse (elimPair facts scrut a1 a2) (elimPair facts scrut a2 a1)
  _ => None
optionElimOf _ _ = None

ruleOptionEliminators : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleOptionEliminators idx _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    (optionElimOf facts)
    (optionElimEdit idx facts)
    optionElimFinding

optionElimFinding : Option Loc -> Expr -> Option Fix -> Finding
optionElimFinding loc rewritten fix = Finding {
  rule = ruleNameOptionEliminators,
  message =
    "this match is a prelude eliminator — rewrite as '"
      ++ oneLine (exprToString rewritten)
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The `panic` the `optionOrPanic` shape reads, when the arm is one.
panicHead : Expr -> Option Expr
panicHead (EMatch _ arms) = firstJust panicArmHead arms
panicHead _ = None

panicArmHead : Arm -> Option Expr
panicArmHead (Arm _ _ body) = match unwrapLoc body
  EApp hd _ => if isEVarNamed "panic" hd then Some hd else None
  _ => None

firstJust : (a -> Option b) -> List a -> Option b
firstJust _ [] = None
firstJust f (x :: rest) = orElse (f x) (firstJust f rest)

-- The fix replaces the whole `match` with the call.  The scrutinee text moves
-- unduplicated, the arms are exactly the eliminator, and the default is movable,
-- so the shapes are `Safe` except `optionOrPanic`: the native engine reports a
-- `panic` reached through it without the call site's `file:line`, so that shape
-- is `Unsafe`.  The fix is withheld where the file binds the name the
-- rewrite writes, or binds the `panic` the match calls, since either would change
-- what the text means.
optionElimEdit : StdlibIndex -> FileFacts -> Ctx -> Expr -> Expr -> Option Fix
optionElimEdit idx facts ctx e rewritten =
  if rebinds idx facts ctx (calledName rewritten)
    || panicRebound idx facts e then
    None
  else
    replaceFix
      (if calledName rewritten == "optionOrPanic" then Unsafe else Safe)
      "use the prelude eliminator"
      (matchSpan facts ctx e)
      (bindingOf rewritten)
      ctx
      (exprToString rewritten)

panicRebound : StdlibIndex -> FileFacts -> Expr -> Bool
panicRebound idx facts e = match panicHead e
  Some hd => not (usesPreludeName idx facts hd)
  None => False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "calledName" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchSpan" false) (mem "movableDefault" false) (mem "oneLine" false) (mem "noExcl" false) (mem "rebinds" false) (mem "replaceFix" false) (mem "ruleNameOptionEliminators" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOptionEliminators")) (fa "summary" (ELit (LString "2-arm `match` on an Option/Result that unwraps with a literal, constructor or local-variable default, panics with a message, or answers whether it is `Some`. The prelude names these: `optionOr`, `optionOrPanic`, `isSome`, `isNone`, `resultOr`"))) (fa "doc" (ELit (LString "A two-arm `match` that returns the payload of `Some`/`Ok` and otherwise a literal, a nullary constructor or a local variable is `optionOr`/`resultOr`; one that otherwise panics with a message is `optionOrPanic`; one that only answers `True`/`False` is `isSome`/`isNone`. A default that is a call or a top-level value is left alone: the function form evaluates it eagerly. The `optionOrPanic` fix needs `--unsafe-fixes`, because a native panic through it loses the call site's location.\n\nBefore:\n  match o\n    Some x => x\n    None => 0\nAfter:\n  optionOr 0 o"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleOptionEliminators")) (EVar "None")))
(DTypeSig false "isBoolLit" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBoolLit" ((PVar "b") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "call1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "call1" ((PVar "fn") (PVar "arg") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "arg"))) (EVar "scrut")))
(DTypeSig false "isIdentityArm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isIdentityArm" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "x") PWild PWild))) (PVar "body")) (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "body"))))
(DFunDef false "isIdentityArm" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "panicMessage" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "panicMessage" ((PVar "facts") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "m")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "panic"))) (EVar "hd")) (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "m"))) (EApp (EVar "Some") (EVar "m")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "elimPair" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr")))))))
(DFunDef false "elimPair" ((PVar "facts") (PVar "scrut") (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs")) (PCon "Arm" (PVar "pf") (PVar "gf") (PVar "bf"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gs")) (EApp (EVar "isEmptyL") (EVar "gf")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "isIdentityArm") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EIf (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "bf")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "call1") (ELit (LString "optionOr"))) (EVar "bf")) (EVar "scrut"))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "call1") (ELit (LString "optionOrPanic"))) (EVar "m")) (EVar "scrut")))) (EApp (EApp (EVar "panicMessage") (EVar "facts")) (EVar "bf")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "isIdentityArm") (ELit (LString "Ok"))) (EVar "ps")) (EVar "bs")) (EApp (EVar "isErrWild") (EVar "pf"))) (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "call1") (ELit (LString "resultOr"))) (EVar "bf")) (EVar "scrut"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isSomeWild") (EVar "ps")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EApp (EApp (EVar "isBoolLit") (EVar "True")) (EVar "bs"))) (EApp (EApp (EVar "isBoolLit") (EVar "False")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "isSome")))) (EVar "scrut"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isSomeWild") (EVar "ps")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EApp (EApp (EVar "isBoolLit") (EVar "False")) (EVar "bs"))) (EApp (EApp (EVar "isBoolLit") (EVar "True")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "isNone")))) (EVar "scrut"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isSomeWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isSomeWild" ((PCon "PCon" (PLit (LString "Some")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "isSomeWild" (PWild) (EVar "False"))
(DTypeSig false "isErrWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isErrWild" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "isErrWild" (PWild) (EVar "False"))
(DTypeSig false "optionElimOf" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "optionElimOf" ((PVar "facts") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EVar "orElse") (EApp (EApp (EApp (EApp (EVar "elimPair") (EVar "facts")) (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EApp (EApp (EVar "elimPair") (EVar "facts")) (EVar "scrut")) (EVar "a2")) (EVar "a1")))) (arm PWild () (EVar "None"))))
(DFunDef false "optionElimOf" (PWild PWild) (EVar "None"))
(DTypeSig false "ruleOptionEliminators" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleOptionEliminators" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EApp (EVar "optionElimOf") (EVar "facts"))) (EApp (EApp (EVar "optionElimEdit") (EVar "idx")) (EVar "facts"))) (EVar "optionElimFinding")))
(DTypeSig false "optionElimFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "optionElimFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameOptionEliminators")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "this match is a prelude eliminator — rewrite as '")) (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "panicHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "panicHead" ((PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "firstJust") (EVar "panicArmHead")) (EVar "arms")))
(DFunDef false "panicHead" (PWild) (EVar "None"))
(DTypeSig false "panicArmHead" (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "panicArmHead" ((PCon "Arm" PWild PWild (PVar "body"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") PWild) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "panic"))) (EVar "hd")) (EApp (EVar "Some") (EVar "hd")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "firstJust" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "firstJust" (PWild (PList)) (EVar "None"))
(DFunDef false "firstJust" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "orElse") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EVar "firstJust") (EVar "f")) (EVar "rest"))))
(DTypeSig false "optionElimEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "optionElimEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EApp (EVar "calledName") (EVar "rewritten"))) (EApp (EApp (EApp (EVar "panicRebound") (EVar "idx")) (EVar "facts")) (EVar "e"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EIf (EBinOp "==" (EApp (EVar "calledName") (EVar "rewritten")) (ELit (LString "optionOrPanic"))) (EVar "Unsafe") (EVar "Safe"))) (ELit (LString "use the prelude eliminator"))) (EApp (EApp (EApp (EVar "matchSpan") (EVar "facts")) (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DTypeSig false "panicRebound" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "panicRebound" ((PVar "idx") (PVar "facts") (PVar "e")) (EMatch (EApp (EVar "panicHead") (EVar "e")) (arm (PCon "Some" (PVar "hd")) () (EApp (EVar "not") (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd")))) (arm (PCon "None") () (EVar "False"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "calledName" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchSpan" false) (mem "movableDefault" false) (mem "oneLine" false) (mem "noExcl" false) (mem "rebinds" false) (mem "replaceFix" false) (mem "ruleNameOptionEliminators" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOptionEliminators")) (fa "summary" (ELit (LString "2-arm `match` on an Option/Result that unwraps with a literal, constructor or local-variable default, panics with a message, or answers whether it is `Some`. The prelude names these: `optionOr`, `optionOrPanic`, `isSome`, `isNone`, `resultOr`"))) (fa "doc" (ELit (LString "A two-arm `match` that returns the payload of `Some`/`Ok` and otherwise a literal, a nullary constructor or a local variable is `optionOr`/`resultOr`; one that otherwise panics with a message is `optionOrPanic`; one that only answers `True`/`False` is `isSome`/`isNone`. A default that is a call or a top-level value is left alone: the function form evaluates it eagerly. The `optionOrPanic` fix needs `--unsafe-fixes`, because a native panic through it loses the call site's location.\n\nBefore:\n  match o\n    Some x => x\n    None => 0\nAfter:\n  optionOr 0 o"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleOptionEliminators")) (EVar "None")))
(DTypeSig false "isBoolLit" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBoolLit" ((PVar "b") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "call1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "call1" ((PVar "fn") (PVar "arg") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "arg"))) (EVar "scrut")))
(DTypeSig false "isIdentityArm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isIdentityArm" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "x") PWild PWild))) (PVar "body")) (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "body"))))
(DFunDef false "isIdentityArm" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "panicMessage" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "panicMessage" ((PVar "facts") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "m")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "panic"))) (EVar "hd")) (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "m"))) (EApp (EVar "Some") (EVar "m")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "elimPair" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr")))))))
(DFunDef false "elimPair" ((PVar "facts") (PVar "scrut") (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs")) (PCon "Arm" (PVar "pf") (PVar "gf") (PVar "bf"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gs")) (EApp (EVar "isEmptyL") (EVar "gf")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "isIdentityArm") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EIf (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "bf")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "call1") (ELit (LString "optionOr"))) (EVar "bf")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "call1") (ELit (LString "optionOrPanic"))) (EVar "m")) (EVar "scrut")))) (EApp (EApp (EVar "panicMessage") (EVar "facts")) (EVar "bf")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "isIdentityArm") (ELit (LString "Ok"))) (EVar "ps")) (EVar "bs")) (EApp (EVar "isErrWild") (EVar "pf"))) (EApp (EApp (EVar "movableDefault") (EVar "facts")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "call1") (ELit (LString "resultOr"))) (EVar "bf")) (EVar "scrut"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isSomeWild") (EVar "ps")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EApp (EApp (EVar "isBoolLit") (EVar "True")) (EVar "bs"))) (EApp (EApp (EVar "isBoolLit") (EVar "False")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "isSome")))) (EVar "scrut"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isSomeWild") (EVar "ps")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pf"))) (EApp (EApp (EVar "isBoolLit") (EVar "False")) (EVar "bs"))) (EApp (EApp (EVar "isBoolLit") (EVar "True")) (EVar "bf"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "isNone")))) (EVar "scrut"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isSomeWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isSomeWild" ((PCon "PCon" (PLit (LString "Some")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "isSomeWild" (PWild) (EVar "False"))
(DTypeSig false "isErrWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isErrWild" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "isErrWild" (PWild) (EVar "False"))
(DTypeSig false "optionElimOf" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "optionElimOf" ((PVar "facts") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EApp (EApp (EVar "elimPair") (EVar "facts")) (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EApp (EApp (EVar "elimPair") (EVar "facts")) (EVar "scrut")) (EVar "a2")) (EVar "a1")))) (arm PWild () (EVar "None"))))
(DFunDef false "optionElimOf" (PWild PWild) (EVar "None"))
(DTypeSig false "ruleOptionEliminators" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleOptionEliminators" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EApp (EVar "optionElimOf") (EVar "facts"))) (EApp (EApp (EVar "optionElimEdit") (EVar "idx")) (EVar "facts"))) (EVar "optionElimFinding")))
(DTypeSig false "optionElimFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "optionElimFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameOptionEliminators")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "this match is a prelude eliminator — rewrite as '")) (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "panicHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "panicHead" ((PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "firstJust") (EVar "panicArmHead")) (EVar "arms")))
(DFunDef false "panicHead" (PWild) (EVar "None"))
(DTypeSig false "panicArmHead" (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "panicArmHead" ((PCon "Arm" PWild PWild (PVar "body"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") PWild) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "panic"))) (EVar "hd")) (EApp (EVar "Some") (EVar "hd")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "firstJust" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "firstJust" (PWild (PList)) (EVar "None"))
(DFunDef false "firstJust" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EMethodRef "orElse") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EVar "firstJust") (EVar "f")) (EVar "rest"))))
(DTypeSig false "optionElimEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "optionElimEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EApp (EVar "calledName") (EVar "rewritten"))) (EApp (EApp (EApp (EVar "panicRebound") (EVar "idx")) (EVar "facts")) (EVar "e"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EIf (EBinOp "==" (EApp (EVar "calledName") (EVar "rewritten")) (ELit (LString "optionOrPanic"))) (EVar "Unsafe") (EVar "Safe"))) (ELit (LString "use the prelude eliminator"))) (EApp (EApp (EApp (EVar "matchSpan") (EVar "facts")) (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DTypeSig false "panicRebound" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "panicRebound" ((PVar "idx") (PVar "facts") (PVar "e")) (EMatch (EApp (EVar "panicHead") (EVar "e")) (arm (PCon "Some" (PVar "hd")) () (EApp (EVar "not") (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd")))) (arm (PCon "None") () (EVar "False"))))
