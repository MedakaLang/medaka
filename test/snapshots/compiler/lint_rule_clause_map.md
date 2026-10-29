# META
source_lines=212
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-clause-map: a two-clause `[]`/`(x :: xs)` recursion that is a hand-written `map` (suggest-only).

import frontend.ast.{
  Loc(..),
  Pat(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen}
import tools.printer.{exprToString}
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
  andThenEtaFn,
  appSpineOf,
  clausesOf,
  dedupeNamesLoc,
  declLocList,
  isEVarNamed,
  mentionsVar,
  paramNameOf,
  ruleNameClauseMap,
  topDefNameL,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameClauseMap,
      summary =
        "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)",
      doc =
        "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleClauseMap
    None

-- A function written as TWO list clauses whose cons clause is exactly a
-- per-element transform consed onto the recursive call — a hand-written `map`:
--   f []        = []
--   f (x :: xs) = g x :: f xs        →  map g
-- `rule-match-to-map` cannot see this shape: it recognizes a single-expression
-- `match` body, never clause-form recursion, so the two rules are disjoint.
--
-- The whole rule is its precision.  A lint has no types (raw pre-desugar AST),
-- so every condition below is a LITERAL identity check on the clause's own
-- bound variables; anything that merely looks similar is rejected rather than
-- coerced into a match:
--   (1) EXACTLY two clauses of equal arity, and EXACTLY one parameter position
--       where one clause has the literal `[]` pattern and the other has
--       `(x :: xs)` with BOTH sides plain variables.  A nested cons
--       (`(a :: b :: rest)`), an as-pattern, or a wildcard nil (`f _ = []`)
--       fails here — the last would also change which inputs the clause covers.
--   (2) every OTHER parameter of the cons clause is a plain variable, and the
--       recursive call passes those variables back VERBATIM, in order, with the
--       tail variable in the list position.  This is what excludes an
--       accumulator fold: an accumulator changes per clause, so its argument is
--       not the bare parameter variable.
--   (3) the nil clause's body is literally `[]` (`EListLit []`), so the base
--       case contributes nothing.
--   (4) the cons body is a top-level `::` whose tail is the recursive call and
--       whose head is `g x` — `x` as the SOLE FINAL argument of an application
--       spine, with `x` mentioned nowhere else in it (`andThenEtaFn`, shared
--       with the andthen-pure-map rewrite).  A field read (`x.name :: f xs`), a
--       recomputation (`g x x :: f xs`) and a bare passthrough (`x :: f xs`,
--       which is a copy, not a map) all fail this.  So does a combinator over
--       adjacent elements (`a < b && strictlyAscending (b :: rest)`) — it has no
--       cons in the result at all, and fails (1) besides.
--   (5) neither the function's own name nor the tail variable may appear in the
--       transform: a second recursive use is a tree/zip recursion, not a map.
-- A body carrying guards, a `where`, or a `let` is not an `EBinOp "::"` node at
-- all, so it never reaches (4).
--
-- A definition literally named `map` is skipped: "rewrite as `map g`" is not
-- advice one can act on inside `map`'s own definition.

-- `(x :: xs)` with both sides plain binders.  Anything deeper is rejected.
consPatVars : Pat -> Option (String, String)
consPatVars (PCons (PVar h _ _) (PVar t _ _)) = Some (h, t)
consPatVars _ = None

-- the literal `[]` pattern (NOT a wildcard, NOT a bare variable)
isNilPat : Pat -> Bool
isNilPat (PList []) = True
isNilPat _ = False

-- the literal `[]` expression
isNilBody : Expr -> Bool
isNilBody e = match unwrapLoc e
  EListLit [] => True
  _ => False

-- every pattern is a plain binder; the names, in order
plainVarNames : List Pat -> Option (List String)
plainVarNames [] = Some []
plainVarNames (p :: ps) = match paramNameOf p
  None => None
  Some n => map (n :: _) (plainVarNames ps)

-- Line the nil clause's parameters up against the cons clause's and find the ONE
-- list position: nil side literally `[]`, cons side `(x :: xs)`.  Returns the
-- head binder, the tail binder, and the argument names the recursive call must
-- carry (each non-list parameter verbatim, the tail binder in the list slot).
-- Every parameter before the split must already be a plain binder, and
-- `plainVarNames` rejects a SECOND cons position after it, so "exactly one" is
-- enforced without a separate scan.
consSplit : List Pat -> List Pat -> Option (String, String, List String)
consSplit [] [] = None
consSplit (np :: nps) (cp :: cps) = match consPatVars cp
  Some (h, t) =>
    if isNilPat np then
      map (rest => (h, t, t :: rest)) (plainVarNames cps)
    else
      None
  None => match paramNameOf cp
    None => None
    Some v => map ((h, t, rest) => (h, t, v :: rest)) (consSplit nps cps)
consSplit _ _ = None

-- the recursive call's arguments are exactly these variable references, in order
argsAreVars : List String -> List Expr -> Bool
argsAreVars [] [] = True
argsAreVars (n :: ns) (a :: rest) = isEVarNamed n a && argsAreVars ns rest
argsAreVars _ _ = False

recursiveCallOn : String -> List String -> Expr -> Bool
recursiveCallOn name expected e =
  let (hd, args) = appSpineOf e
  isEVarNamed name hd && argsAreVars expected args

-- cons clause body `g x :: f xs …` → `Some g` (conditions 4 and 5).
clauseMapTransform : String ->
  String ->
  String ->
  List String ->
  Expr ->
  Option Expr
clauseMapTransform name headV tailV expected body = match unwrapLoc body
  EBinOp op lhs rhs _ if op == "::"
    && recursiveCallOn name expected rhs => match andThenEtaFn headV lhs
    None => None
    Some g => if mentionsVar name g || mentionsVar tailV g then None else Some g
  _ => None

-- one ORDERED attempt: `nil` is the candidate base clause, `cons` the step.
clauseMapPair : String -> (List Pat, Expr) -> (List Pat, Expr) -> Option Expr
clauseMapPair name (nilPs, nilBody) (consPs, consBody) =
  if not (isNilBody nilBody) || listLen nilPs /= listLen consPs then
    None
  else match consSplit nilPs consPs
    None => None
    Some (headV, tailV, expected) =>
      clauseMapTransform name headV tailV expected consBody

-- the transform this definition maps with, if it is a clause-form map.
-- Clause order is either way round.
clauseMapFnOf : String -> List Decl -> Option Expr
clauseMapFnOf "map" _ = None
clauseMapFnOf name prog = match clausesOf name prog
  [a, b] => match clauseMapPair name a b
    Some g => Some g
    None => clauseMapPair name b a
  _ => None

ruleClauseMap : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleClauseMap _ _ _ pos prog =
  -- dedupe by name so a two-clause function is inspected once, not once per
  -- clause, keeping the FIRST clause's location (same shape as
  -- `rule-stdlib-reimpl`).
  flatMap
    (clauseMapHit prog)
    (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog)))

clauseMapHit : List Decl -> (String, Option Loc) -> List Finding
clauseMapHit prog (name, loc) = match clauseMapFnOf name prog
  None => []
  Some g => [clauseMapFinding name g loc]

clauseMapFinding : String -> Expr -> Option Loc -> Finding
clauseMapFinding name g loc = Finding {
  rule = ruleNameClauseMap,
  message =
    "'\{name}' is a hand-written list map ('[]'/'(x :: xs)' clauses consing a per-element transform onto the recursive call). Rewrite as '\{exprToString (EApp (EVar "map") g)}' (suggest-only)",
  severity = SevWarning,
  loc = loc,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "appSpineOf" false) (mem "clausesOf" false) (mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "paramNameOf" false) (mem "ruleNameClauseMap" false) (mem "topDefNameL" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameClauseMap")) (fa "summary" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "doc" (ELit (LString "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleClauseMap")) (EVar "None")))
(DTypeSig false "consPatVars" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "consPatVars" ((PCon "PCons" (PCon "PVar" (PVar "h") PWild PWild) (PCon "PVar" (PVar "t") PWild PWild))) (EApp (EVar "Some") (ETuple (EVar "h") (EVar "t"))))
(DFunDef false "consPatVars" (PWild) (EVar "None"))
(DTypeSig false "isNilPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isNilPat" ((PCon "PList" (PList))) (EVar "True"))
(DFunDef false "isNilPat" (PWild) (EVar "False"))
(DTypeSig false "isNilBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isNilBody" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EListLit" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "plainVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "plainVarNames" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "plainVarNames" ((PCons (PVar "p") (PVar "ps"))) (EMatch (EApp (EVar "paramNameOf") (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "n") (EVar "_s")))) (EApp (EVar "plainVarNames") (EVar "ps"))))))
(DTypeSig false "consSplit" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "consSplit" ((PList) (PList)) (EVar "None"))
(DFunDef false "consSplit" ((PCons (PVar "np") (PVar "nps")) (PCons (PVar "cp") (PVar "cps"))) (EMatch (EApp (EVar "consPatVars") (EVar "cp")) (arm (PCon "Some" (PTuple (PVar "h") (PVar "t"))) () (EIf (EApp (EVar "isNilPat") (EVar "np")) (EApp (EApp (EVar "map") (ELam ((PVar "rest")) (ETuple (EVar "h") (EVar "t") (EBinOp "::" (EVar "t") (EVar "rest"))))) (EApp (EVar "plainVarNames") (EVar "cps"))) (EVar "None"))) (arm (PCon "None") () (EMatch (EApp (EVar "paramNameOf") (EVar "cp")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "h") (PVar "t") (PVar "rest"))) (ETuple (EVar "h") (EVar "t") (EBinOp "::" (EVar "v") (EVar "rest"))))) (EApp (EApp (EVar "consSplit") (EVar "nps")) (EVar "cps"))))))))
(DFunDef false "consSplit" (PWild PWild) (EVar "None"))
(DTypeSig false "argsAreVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "argsAreVars" ((PList) (PList)) (EVar "True"))
(DFunDef false "argsAreVars" ((PCons (PVar "n") (PVar "ns")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "n")) (EVar "a")) (EApp (EApp (EVar "argsAreVars") (EVar "ns")) (EVar "rest"))))
(DFunDef false "argsAreVars" (PWild PWild) (EVar "False"))
(DTypeSig false "recursiveCallOn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "recursiveCallOn" ((PVar "name") (PVar "expected") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EVar "appSpineOf") (EVar "e"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "name")) (EVar "hd")) (EApp (EApp (EVar "argsAreVars") (EVar "expected")) (EVar "args"))))))
(DTypeSig false "clauseMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))))
(DFunDef false "clauseMapTransform" ((PVar "name") (PVar "headV") (PVar "tailV") (PVar "expected") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EApp (EApp (EApp (EVar "recursiveCallOn") (EVar "name")) (EVar "expected")) (EVar "rhs"))))) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "headV")) (EVar "lhs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "g")) () (EIf (EBinOp "||" (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "g")) (EApp (EApp (EVar "mentionsVar") (EVar "tailV")) (EVar "g"))) (EVar "None") (EApp (EVar "Some") (EVar "g")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "clauseMapPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "clauseMapPair" ((PVar "name") (PTuple (PVar "nilPs") (PVar "nilBody")) (PTuple (PVar "consPs") (PVar "consBody"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isNilBody") (EVar "nilBody"))) (EBinOp "/=" (EApp (EVar "listLen") (EVar "nilPs")) (EApp (EVar "listLen") (EVar "consPs")))) (EVar "None") (EMatch (EApp (EApp (EVar "consSplit") (EVar "nilPs")) (EVar "consPs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "headV") (PVar "tailV") (PVar "expected"))) () (EApp (EApp (EApp (EApp (EApp (EVar "clauseMapTransform") (EVar "name")) (EVar "headV")) (EVar "tailV")) (EVar "expected")) (EVar "consBody"))))))
(DTypeSig false "clauseMapFnOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "clauseMapFnOf" ((PLit (LString "map")) PWild) (EVar "None"))
(DFunDef false "clauseMapFnOf" ((PVar "name") (PVar "prog")) (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "prog")) (arm (PList (PVar "a") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "clauseMapPair") (EVar "name")) (EVar "a")) (EVar "b")) (arm (PCon "Some" (PVar "g")) () (EApp (EVar "Some") (EVar "g"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "clauseMapPair") (EVar "name")) (EVar "b")) (EVar "a"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleClauseMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleClauseMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "clauseMapHit") (EVar "prog"))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "clauseMapHit" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "clauseMapHit" ((PVar "prog") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "clauseMapFnOf") (EVar "name")) (EVar "prog")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "g")) () (EListLit (EApp (EApp (EApp (EVar "clauseMapFinding") (EVar "name")) (EVar "g")) (EVar "loc"))))))
(DTypeSig false "clauseMapFinding" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding")))))
(DFunDef false "clauseMapFinding" ((PVar "name") (PVar "g") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameClauseMap")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is a hand-written list map ('[]'/'(x :: xs)' clauses consing a per-element transform onto the recursive call). Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "g"))))) (ELit (LString "' (suggest-only)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "appSpineOf" false) (mem "clausesOf" false) (mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "paramNameOf" false) (mem "ruleNameClauseMap" false) (mem "topDefNameL" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameClauseMap")) (fa "summary" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "doc" (ELit (LString "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleClauseMap")) (EVar "None")))
(DTypeSig false "consPatVars" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "consPatVars" ((PCon "PCons" (PCon "PVar" (PVar "h") PWild PWild) (PCon "PVar" (PVar "t") PWild PWild))) (EApp (EVar "Some") (ETuple (EVar "h") (EVar "t"))))
(DFunDef false "consPatVars" (PWild) (EVar "None"))
(DTypeSig false "isNilPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isNilPat" ((PCon "PList" (PList))) (EVar "True"))
(DFunDef false "isNilPat" (PWild) (EVar "False"))
(DTypeSig false "isNilBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isNilBody" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EListLit" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "plainVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "plainVarNames" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "plainVarNames" ((PCons (PVar "p") (PVar "ps"))) (EMatch (EApp (EVar "paramNameOf") (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "n") (EVar "_s")))) (EApp (EVar "plainVarNames") (EVar "ps"))))))
(DTypeSig false "consSplit" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "consSplit" ((PList) (PList)) (EVar "None"))
(DFunDef false "consSplit" ((PCons (PVar "np") (PVar "nps")) (PCons (PVar "cp") (PVar "cps"))) (EMatch (EApp (EVar "consPatVars") (EVar "cp")) (arm (PCon "Some" (PTuple (PVar "h") (PVar "t"))) () (EIf (EApp (EVar "isNilPat") (EVar "np")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "rest")) (ETuple (EVar "h") (EVar "t") (EBinOp "::" (EVar "t") (EVar "rest"))))) (EApp (EVar "plainVarNames") (EVar "cps"))) (EVar "None"))) (arm (PCon "None") () (EMatch (EApp (EVar "paramNameOf") (EVar "cp")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "h") (PVar "t") (PVar "rest"))) (ETuple (EVar "h") (EVar "t") (EBinOp "::" (EVar "v") (EVar "rest"))))) (EApp (EApp (EVar "consSplit") (EVar "nps")) (EVar "cps"))))))))
(DFunDef false "consSplit" (PWild PWild) (EVar "None"))
(DTypeSig false "argsAreVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "argsAreVars" ((PList) (PList)) (EVar "True"))
(DFunDef false "argsAreVars" ((PCons (PVar "n") (PVar "ns")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "n")) (EVar "a")) (EApp (EApp (EVar "argsAreVars") (EVar "ns")) (EVar "rest"))))
(DFunDef false "argsAreVars" (PWild PWild) (EVar "False"))
(DTypeSig false "recursiveCallOn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "recursiveCallOn" ((PVar "name") (PVar "expected") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EVar "appSpineOf") (EVar "e"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "name")) (EVar "hd")) (EApp (EApp (EVar "argsAreVars") (EVar "expected")) (EVar "args"))))))
(DTypeSig false "clauseMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))))
(DFunDef false "clauseMapTransform" ((PVar "name") (PVar "headV") (PVar "tailV") (PVar "expected") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EApp (EApp (EApp (EVar "recursiveCallOn") (EVar "name")) (EVar "expected")) (EVar "rhs"))))) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "headV")) (EVar "lhs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "g")) () (EIf (EBinOp "||" (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "g")) (EApp (EApp (EVar "mentionsVar") (EVar "tailV")) (EVar "g"))) (EVar "None") (EApp (EVar "Some") (EVar "g")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "clauseMapPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "clauseMapPair" ((PVar "name") (PTuple (PVar "nilPs") (PVar "nilBody")) (PTuple (PVar "consPs") (PVar "consBody"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isNilBody") (EVar "nilBody"))) (EBinOp "/=" (EApp (EVar "listLen") (EVar "nilPs")) (EApp (EVar "listLen") (EVar "consPs")))) (EVar "None") (EMatch (EApp (EApp (EVar "consSplit") (EVar "nilPs")) (EVar "consPs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "headV") (PVar "tailV") (PVar "expected"))) () (EApp (EApp (EApp (EApp (EApp (EVar "clauseMapTransform") (EVar "name")) (EVar "headV")) (EVar "tailV")) (EVar "expected")) (EVar "consBody"))))))
(DTypeSig false "clauseMapFnOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "clauseMapFnOf" ((PLit (LString "map")) PWild) (EVar "None"))
(DFunDef false "clauseMapFnOf" ((PVar "name") (PVar "prog")) (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "prog")) (arm (PList (PVar "a") (PVar "b")) () (EMatch (EApp (EApp (EApp (EVar "clauseMapPair") (EVar "name")) (EVar "a")) (EVar "b")) (arm (PCon "Some" (PVar "g")) () (EApp (EVar "Some") (EVar "g"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "clauseMapPair") (EVar "name")) (EVar "b")) (EVar "a"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleClauseMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleClauseMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "clauseMapHit") (EVar "prog"))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "clauseMapHit" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "clauseMapHit" ((PVar "prog") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "clauseMapFnOf") (EVar "name")) (EVar "prog")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "g")) () (EListLit (EApp (EApp (EApp (EVar "clauseMapFinding") (EVar "name")) (EVar "g")) (EVar "loc"))))))
(DTypeSig false "clauseMapFinding" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding")))))
(DFunDef false "clauseMapFinding" ((PVar "name") (PVar "g") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameClauseMap")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is a hand-written list map ('[]'/'(x :: xs)' clauses consing a per-element transform onto the recursive call). Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "g"))))) (ELit (LString "' (suggest-only)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
