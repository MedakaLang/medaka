# META
source_lines=417
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_hints.mdk — the rewrite-hint engine: a rule that rewrites
-- one expression shape to another is a row of data, `lhs ==> rhs`, and this
-- module is the matcher that turns rows into findings with span fixes.
--
-- Row syntax.  `lhs` and `rhs` are Medaka expressions.  A metavariable is a
-- single lowercase letter, optionally followed by digits (`a`, `b`, `x1`); it
-- binds any subexpression, and a metavariable repeated in `lhs` must match
-- structurally equal subexpressions.  Any other name is literal.  A template
-- may contain names, literals, the empty list `[]`, applications and binary
-- operators; the root of `lhs` is an application or a binary operator.  Every
-- metavariable of `rhs` is bound by `lhs`.
--
-- Side conditions.  Every lowercase literal name of `lhs` is a head: each use
-- the row matches must resolve to the prelude's binding (`usesPreludeName`),
-- else the finding is reported without a fix.  A literal name matches the
-- unqualified spelling only.  `Atomic m` makes the row match only where
-- `m` is bound to a name or a literal.  `NotInDefOf names` withholds the fix
-- inside the definition of a function so named, where the rewrite would call
-- the function from its own body.  A lowercase name the right side writes is
-- introduced into the file: when the file binds it (or a wildcard import may),
-- or it is the enclosing definition, the finding is reported without a fix.
--
-- Rows are compiled once per process, on first use; a rule module holds its
-- compiled rows in a top-level value, so a run with no hint rule active never
-- parses one.  A row that does not compile panics there, and
-- `lint_hints_test.mdk` compiles every registered row.

import frontend.ast.{Expr(..), Decl(..), Loc}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..), parseResult}
import driver.diagnostics.{Severity(..)}
import string.{split, isLower, isDigit}
import support.util.{lookupAssoc}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
import tools.lint_core.{
  Applicability(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
  StdlibIndex,
  Visitor(..),
}
import tools.lint_shared.{
  oneLine,
  rebinds,
  replaceNodeFix,
  unwrapLoc,
  usesPreludeName,
}
import list.{nub}

-- Two kinds of side condition, not failure and success.
-- lint-disable-next-line rule-clone-type
public export data HintCond = Atomic String | NotInDefOf (List String)

public export data HintRow = HintRow {
  rowText : String,
  rowMessage : String,
  rowFix : String,
  rowApplicability : Applicability,
  rowConds : List HintCond,
}

-- A left side with its metavariables already told from its literal names, so
-- matching a node never inspects a spelling.
data Tmpl =
  | TMeta String
  | TName String Bool
  | TApp Tmpl Tmpl
  | TBin String Tmpl Tmpl
  | TLeaf String

public export data Hint = Hint {
  hintRow : HintRow,
  hintKind : ExprKind,
  hintLhs : Tmpl,
  hintRhs : Expr,
  hintIntro : List String,
  hintKey : String,
}

-- ── compiling a row ──────────────────────────────────────────────────────────

-- A metavariable: one lowercase letter, then digits.
isMeta : String -> Bool
isMeta n = match toList (stringToChars n)
  c :: rest => isLower c && all isDigit rest
  [] => False

-- A head: a lowercase literal name, the kind a file can rebind.
isHeadName : String -> Bool
isHeadName n = match toList (stringToChars n)
  c :: _ => isLower c || c == '_'
  [] => False

exprOfText : String -> Result String Expr
exprOfText text = match parseResult ("hint = " ++ text ++ "\n")
  Ok [DFunDef _ _ [] body _ _] => Ok body
  _ => Err ("does not parse as an expression: " ++ text)

-- The template with its locations removed, or why it is not a template.
templateOf : Expr -> Result String Expr
templateOf (ELoc _ e) = templateOf e
templateOf (e@(EVar _)) = Ok e
templateOf (e@(ELit _)) = Ok e
templateOf (e@(ENumLit _ _ _)) = Ok e
templateOf (e@(EListLit [])) = Ok e
templateOf (EApp f x) = match (templateOf f, templateOf x)
  (Ok f2, Ok x2) => Ok (EApp f2 x2)
  (Err m, _) => Err m
  (_, Err m) => Err m
templateOf (EBinOp op a b r) = match (templateOf a, templateOf b)
  (Ok a2, Ok b2) => Ok (EBinOp op a2 b2 r)
  (Err m, _) => Err m
  (_, Err m) => Err m
templateOf _ =
  Err "a template holds only names, literals, `[]`, applications and operators"

-- The lowercase literal names a right side writes: the names the rewrite
-- introduces into the file.
introducedOf : Expr -> List String
introducedOf (EVar n) = if isMeta n || not (isHeadName n) then [] else [n]
introducedOf (EApp f x) = nub (introducedOf f ++ introducedOf x)
introducedOf (EBinOp _ a b _) = nub (introducedOf a ++ introducedOf b)
introducedOf _ = []

metasOf : Expr -> List String
metasOf (EVar n) = if isMeta n then [n] else []
metasOf (EApp f x) = metasOf f ++ metasOf x
metasOf (EBinOp _ a b _) = metasOf a ++ metasOf b
metasOf _ = []

tmplOf : Expr -> Tmpl
tmplOf (EVar n) = if isMeta n then TMeta n else TName n (isHeadName n)
tmplOf (EApp f x) = TApp (tmplOf f) (tmplOf x)
tmplOf (EBinOp op a b _) = TBin op (tmplOf a) (tmplOf b)
tmplOf e = TLeaf (exprSexp e)

-- What a left side's root is called, for telling at a glance that a node cannot
-- match: the operator of a binary root, else the head name of an application
-- spine, "" when the head is a metavariable.
templateKey : Expr -> String
templateKey e =
  let k = nodeKey e
  if isMeta k then "" else k

-- The same name read off a subject node, without allocating.
nodeKey : Expr -> String
nodeKey e = match unwrapLoc e
  EApp f _ => spineHead f
  EBinOp op _ _ _ => op
  _ => ""

spineHead : Expr -> String
spineHead f = match unwrapLoc f
  EApp g _ => spineHead g
  EVar n => n
  _ => ""

rootKind : Expr -> Option ExprKind
rootKind (EApp _ _) = Some KApp
rootKind (EBinOp _ _ _ _) = Some KBinOp
rootKind _ = None

condMeta : HintCond -> Option String
condMeta (Atomic m) = Some m
condMeta _ = None

-- Compile one row, or say why it cannot be.
export
compileHint : HintRow -> Result String Hint
compileHint row = match split " ==> " row.rowText
  [lhsText, rhsText] => match (exprOfText lhsText, exprOfText rhsText)
    (Ok l, Ok r) => match (templateOf l, templateOf r)
      (Ok lhs, Ok rhs) => checkHint row lhs rhs
      (Err m, _) => Err (rowFailure row m)
      (_, Err m) => Err (rowFailure row m)
    (Err m, _) => Err (rowFailure row m)
    (_, Err m) => Err (rowFailure row m)
  _ => Err (rowFailure row "expected exactly one ` ==> `")

checkHint : HintRow -> Expr -> Expr -> Result String Hint
checkHint row lhs rhs =
  let bound = metasOf lhs
  match rootKind lhs
    None =>
      Err (rowFailure row "the left side is not an application or an operator")
    Some kind => checkBound row kind lhs rhs bound

checkBound : HintRow ->
  ExprKind ->
  Expr ->
  Expr ->
  List String ->
  Result String Hint
checkBound row kind lhs rhs bound =
  if any (m => not (elem m bound)) (metasOf rhs) then
    Err
      (rowFailure
        row
        "the right side uses a metavariable the left side does not bind")
  else if any (m => not (elem m bound)) (condMetas row.rowConds) then
    Err
      (rowFailure
        row
        "a condition names a metavariable the left side does not bind")
  else
    Ok Hint {
      hintRow = row,
      hintKind = kind,
      hintLhs = tmplOf lhs,
      hintRhs = rhs,
      hintIntro = introducedOf rhs,
      hintKey = templateKey lhs,
    }

condMetas : List HintCond -> List String
condMetas conds = flatMap (c => toList (condMeta c)) conds

rowFailure : HintRow -> String -> String
rowFailure row why = "hint row `\{row.rowText}`: \{why}"

-- The rows compiled, panicking on the first that does not.
export
compileHints : List HintRow -> List Hint
compileHints rows = map compileOrPanic rows

compileOrPanic : HintRow -> Hint
compileOrPanic row = match compileHint row
  Ok h => h
  Err m => panic m

-- ── matching ─────────────────────────────────────────────────────────────────

-- What a match bound: the metavariables, and the subject nodes that stood on
-- the template's literal head names.
public export data Found = Found {
  foundBinds : List (String, Expr),
  foundHeads : List Expr,
}

-- The subject against the template; a bound subexpression keeps its wrappers.
export
matchHint : Hint -> Expr -> Option Found
matchHint h subject = match matchT h.hintLhs subject (Found [] [])
  Some found => if condsHold h.hintRow.rowConds found then Some found else None
  None => None

condsHold : List HintCond -> Found -> Bool
condsHold conds found = all (condHolds found) conds

condHolds : Found -> HintCond -> Bool
condHolds found (Atomic m) = match lookupAssoc m found.foundBinds
  Some e => isAtomic e
  None => False
condHolds _ _ = True

isAtomic : Expr -> Bool
isAtomic e = match unwrapLoc e
  EVar _ => True
  ELit _ => True
  ENumLit _ _ _ => True
  _ => False

matchT : Tmpl -> Expr -> Found -> Option Found
matchT (TMeta n) subject found = bindMeta n subject found
matchT (TName n isHead) subject found = match unwrapLoc subject
  EVar m =>
    if m == n then
      Some (if isHead then
        Found found.foundBinds (subject :: found.foundHeads)
      else
        found)
    else
      None
  _ => None
matchT (TApp pf px) subject found = match unwrapLoc subject
  EApp sf sx => matchBoth pf sf px sx found
  _ => None
matchT (TBin op pa pb) subject found = match unwrapLoc subject
  EBinOp op2 sa sb _ => if op == op2 then matchBoth pa sa pb sb found else None
  _ => None
matchT (TLeaf sexp) subject found =
  if sexp == exprSexp (unwrapLoc subject) then Some found else None

matchBoth : Tmpl -> Expr -> Tmpl -> Expr -> Found -> Option Found
matchBoth p1 s1 p2 s2 found = match matchT p1 s1 found
  Some found2 => matchT p2 s2 found2
  None => None

bindMeta : String -> Expr -> Found -> Option Found
bindMeta n subject found = match lookupAssoc n found.foundBinds
  Some prev =>
    if exprSexp (unwrapLoc prev) == exprSexp (unwrapLoc subject) then
      Some found
    else
      None
  None => Some (Found ((n, subject) :: found.foundBinds) found.foundHeads)

-- The right side with the bound subexpressions put in.
export
instantiate : Hint -> Found -> Expr
instantiate h found = fill found.foundBinds h.hintRhs

fill : List (String, Expr) -> Expr -> Expr
fill binds (EVar n) = match lookupAssoc n binds
  Some e => e
  None => EVar n
fill binds (EApp f x) = EApp (fill binds f) (fill binds x)
fill binds (EBinOp op a b r) = EBinOp op (fill binds a) (fill binds b) r
fill _ e = e

-- ── the rule ─────────────────────────────────────────────────────────────────

-- The expression kinds the rows' left sides can root at.
hintKinds : List Hint -> List ExprKind
hintKinds hints = fold addKind [] (map (h => h.hintKind) hints)

addKind : List ExprKind -> ExprKind -> List ExprKind
addKind seen k = if elem k seen then seen else seen ++ [k]

-- The visitors a hint rule registers: one callback over the kinds its rows
-- root at, reporting the first row that matches a node.
export
hintVisitors : String ->
  Severity ->
  List Hint ->
  StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
hintVisitors name severity hints idx _ facts _ _ =
  [OnExpr (hintKinds hints) (hintsAt name severity hints idx facts)]

hintsAt : String ->
  Severity ->
  List Hint ->
  StdlibIndex ->
  FileFacts ->
  Ctx ->
  Expr ->
  List Finding
hintsAt _ _ [] _ _ _ _ = []
hintsAt name severity (h :: rest) idx facts ctx e =
  hintsKeyed (nodeKey e) name severity (h :: rest) idx facts ctx e

hintsKeyed : String ->
  String ->
  Severity ->
  List Hint ->
  StdlibIndex ->
  FileFacts ->
  Ctx ->
  Expr ->
  List Finding
hintsKeyed _ _ _ [] _ _ _ _ = []
hintsKeyed key name severity (h :: rest) idx facts ctx e =
  if h.hintKey == "" || h.hintKey == key then match matchHint h e
    Some found => [hintFinding name severity h found idx facts ctx e]
    None => hintsKeyed key name severity rest idx facts ctx e
  else
    hintsKeyed key name severity rest idx facts ctx e

hintFinding : String ->
  Severity ->
  Hint ->
  Found ->
  StdlibIndex ->
  FileFacts ->
  Ctx ->
  Expr ->
  Finding
hintFinding name severity h found idx facts ctx e =
  let rewritten = instantiate h found
  Finding {
    rule = name,
    message =
      "\{h.hintRow.rowMessage}. Rewrite as '\{oneLine (exprToString rewritten)}'",
    severity = severity,
    loc = ctx.ctxSpan,
    fix = hintFix h found idx facts ctx e rewritten,
  }

hintFix : Hint ->
  Found ->
  StdlibIndex ->
  FileFacts ->
  Ctx ->
  Expr ->
  Expr ->
  Option Fix
hintFix h found idx facts ctx e rewritten =
  if allHeadsPrelude idx facts found
    && not (any (rebinds idx facts ctx) h.hintIntro)
    && not (inOwnDefinition h ctx) then
    replaceNodeFix h.hintRow.rowApplicability h.hintRow.rowFix ctx e rewritten
  else
    None

allHeadsPrelude : StdlibIndex -> FileFacts -> Found -> Bool
allHeadsPrelude idx facts found =
  all (usesPreludeName idx facts) found.foundHeads

-- Inside the definition of a function the row names, the rewrite would call it
-- from its own body.  A test's or prop's owner name is its description.
export
inOwnDefinition : Hint -> Ctx -> Bool
inOwnDefinition h ctx =
  not ctx.ctxInTest && any (ownsName ctx) h.hintRow.rowConds

ownsName : Ctx -> HintCond -> Bool
ownsName ctx (NotInDefOf names) = elem ctx.ctxDeclName names
ownsName _ _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Decl" true) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "parseResult" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "isLower" false) (mem "isDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "StdlibIndex" false) (mem "Visitor" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "oneLine" false) (mem "rebinds" false) (mem "replaceNodeFix" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DUse false (UseGroup ("list") ((mem "nub" false))))
(DData Public "HintCond" () ((variant "Atomic" (ConPos (TyCon "String"))) (variant "NotInDefOf" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "HintRow" () ((variant "HintRow" (ConNamed (field "rowText" (TyCon "String")) (field "rowMessage" (TyCon "String")) (field "rowFix" (TyCon "String")) (field "rowApplicability" (TyCon "Applicability")) (field "rowConds" (TyApp (TyCon "List") (TyCon "HintCond")))))) ())
(DData Private "Tmpl" () ((variant "TMeta" (ConPos (TyCon "String"))) (variant "TName" (ConPos (TyCon "String") (TyCon "Bool"))) (variant "TApp" (ConPos (TyCon "Tmpl") (TyCon "Tmpl"))) (variant "TBin" (ConPos (TyCon "String") (TyCon "Tmpl") (TyCon "Tmpl"))) (variant "TLeaf" (ConPos (TyCon "String")))) ())
(DData Public "Hint" () ((variant "Hint" (ConNamed (field "hintRow" (TyCon "HintRow")) (field "hintKind" (TyCon "ExprKind")) (field "hintLhs" (TyCon "Tmpl")) (field "hintRhs" (TyCon "Expr")) (field "hintIntro" (TyApp (TyCon "List") (TyCon "String"))) (field "hintKey" (TyCon "String"))))) ())
(DTypeSig false "isMeta" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMeta" ((PVar "n")) (EMatch (EApp (EVar "toList") (EApp (EVar "stringToChars") (EVar "n"))) (arm (PCons (PVar "c") (PVar "rest")) () (EBinOp "&&" (EApp (EVar "isLower") (EVar "c")) (EApp (EApp (EVar "all") (EVar "isDigit")) (EVar "rest")))) (arm (PList) () (EVar "False"))))
(DTypeSig false "isHeadName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHeadName" ((PVar "n")) (EMatch (EApp (EVar "toList") (EApp (EVar "stringToChars") (EVar "n"))) (arm (PCons (PVar "c") PWild) () (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_"))))) (arm (PList) () (EVar "False"))))
(DTypeSig false "exprOfText" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "exprOfText" ((PVar "text")) (EMatch (EApp (EVar "parseResult") (EBinOp "++" (EBinOp "++" (ELit (LString "hint = ")) (EVar "text")) (ELit (LString "\n")))) (arm (PCon "Ok" (PList (PCon "DFunDef" PWild PWild (PList) (PVar "body") PWild PWild))) () (EApp (EVar "Ok") (EVar "body"))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "does not parse as an expression: ")) (EVar "text"))))))
(DTypeSig false "templateOf" (TyFun (TyCon "Expr") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "templateOf" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "templateOf") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "EVar" PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "ELit" PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "EListLit" (PList)))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EMatch (ETuple (EApp (EVar "templateOf") (EVar "f")) (EApp (EVar "templateOf") (EVar "x"))) (arm (PTuple (PCon "Ok" (PVar "f2")) (PCon "Ok" (PVar "x2"))) () (EApp (EVar "Ok") (EApp (EApp (EVar "EApp") (EVar "f2")) (EVar "x2")))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EVar "m"))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EVar "m")))))
(DFunDef false "templateOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EMatch (ETuple (EApp (EVar "templateOf") (EVar "a")) (EApp (EVar "templateOf") (EVar "b"))) (arm (PTuple (PCon "Ok" (PVar "a2")) (PCon "Ok" (PVar "b2"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a2")) (EVar "b2")) (EVar "r")))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EVar "m"))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EVar "m")))))
(DFunDef false "templateOf" (PWild) (EApp (EVar "Err") (ELit (LString "a template holds only names, literals, `[]`, applications and operators"))))
(DTypeSig false "introducedOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "introducedOf" ((PCon "EVar" (PVar "n"))) (EIf (EBinOp "||" (EApp (EVar "isMeta") (EVar "n")) (EApp (EVar "not") (EApp (EVar "isHeadName") (EVar "n")))) (EListLit) (EListLit (EVar "n"))))
(DFunDef false "introducedOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "nub") (EBinOp "++" (EApp (EVar "introducedOf") (EVar "f")) (EApp (EVar "introducedOf") (EVar "x")))))
(DFunDef false "introducedOf" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EVar "nub") (EBinOp "++" (EApp (EVar "introducedOf") (EVar "a")) (EApp (EVar "introducedOf") (EVar "b")))))
(DFunDef false "introducedOf" (PWild) (EListLit))
(DTypeSig false "metasOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metasOf" ((PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isMeta") (EVar "n")) (EListLit (EVar "n")) (EListLit)))
(DFunDef false "metasOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "metasOf") (EVar "f")) (EApp (EVar "metasOf") (EVar "x"))))
(DFunDef false "metasOf" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "metasOf") (EVar "a")) (EApp (EVar "metasOf") (EVar "b"))))
(DFunDef false "metasOf" (PWild) (EListLit))
(DTypeSig false "tmplOf" (TyFun (TyCon "Expr") (TyCon "Tmpl")))
(DFunDef false "tmplOf" ((PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isMeta") (EVar "n")) (EApp (EVar "TMeta") (EVar "n")) (EApp (EApp (EVar "TName") (EVar "n")) (EApp (EVar "isHeadName") (EVar "n")))))
(DFunDef false "tmplOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "TApp") (EApp (EVar "tmplOf") (EVar "f"))) (EApp (EVar "tmplOf") (EVar "x"))))
(DFunDef false "tmplOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EApp (EApp (EApp (EVar "TBin") (EVar "op")) (EApp (EVar "tmplOf") (EVar "a"))) (EApp (EVar "tmplOf") (EVar "b"))))
(DFunDef false "tmplOf" ((PVar "e")) (EApp (EVar "TLeaf") (EApp (EVar "exprSexp") (EVar "e"))))
(DTypeSig false "templateKey" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "templateKey" ((PVar "e")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "nodeKey") (EVar "e"))) (DoExpr (EIf (EApp (EVar "isMeta") (EVar "k")) (ELit (LString "")) (EVar "k")))))
(DTypeSig false "nodeKey" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeKey" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EVar "op")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "spineHead" ((PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EVar "spineHead") (EVar "g"))) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rootKind" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "ExprKind"))))
(DFunDef false "rootKind" ((PCon "EApp" PWild PWild)) (EApp (EVar "Some") (EVar "KApp")))
(DFunDef false "rootKind" ((PCon "EBinOp" PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "KBinOp")))
(DFunDef false "rootKind" (PWild) (EVar "None"))
(DTypeSig false "condMeta" (TyFun (TyCon "HintCond") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "condMeta" ((PCon "Atomic" (PVar "m"))) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "condMeta" (PWild) (EVar "None"))
(DTypeSig true "compileHint" (TyFun (TyCon "HintRow") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))
(DFunDef false "compileHint" ((PVar "row")) (EMatch (EApp (EApp (EVar "split") (ELit (LString " ==> "))) (EFieldAccess (EVar "row") "rowText")) (arm (PList (PVar "lhsText") (PVar "rhsText")) () (EMatch (ETuple (EApp (EVar "exprOfText") (EVar "lhsText")) (EApp (EVar "exprOfText") (EVar "rhsText"))) (arm (PTuple (PCon "Ok" (PVar "l")) (PCon "Ok" (PVar "r"))) () (EMatch (ETuple (EApp (EVar "templateOf") (EVar "l")) (EApp (EVar "templateOf") (EVar "r"))) (arm (PTuple (PCon "Ok" (PVar "lhs")) (PCon "Ok" (PVar "rhs"))) () (EApp (EApp (EApp (EVar "checkHint") (EVar "row")) (EVar "lhs")) (EVar "rhs"))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "expected exactly one ` ==> `")))))))
(DTypeSig false "checkHint" (TyFun (TyCon "HintRow") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))))
(DFunDef false "checkHint" ((PVar "row") (PVar "lhs") (PVar "rhs")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "metasOf") (EVar "lhs"))) (DoExpr (EMatch (EApp (EVar "rootKind") (EVar "lhs")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "the left side is not an application or an operator"))))) (arm (PCon "Some" (PVar "kind")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkBound") (EVar "row")) (EVar "kind")) (EVar "lhs")) (EVar "rhs")) (EVar "bound")))))))
(DTypeSig false "checkBound" (TyFun (TyCon "HintRow") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))))))
(DFunDef false "checkBound" ((PVar "row") (PVar "kind") (PVar "lhs") (PVar "rhs") (PVar "bound")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "m")) (EVar "bound"))))) (EApp (EVar "metasOf") (EVar "rhs"))) (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "the right side uses a metavariable the left side does not bind")))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "m")) (EVar "bound"))))) (EApp (EVar "condMetas") (EFieldAccess (EVar "row") "rowConds"))) (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "a condition names a metavariable the left side does not bind")))) (EApp (EVar "Ok") (ERecordCreate "Hint" ((fa "hintRow" (EVar "row")) (fa "hintKind" (EVar "kind")) (fa "hintLhs" (EApp (EVar "tmplOf") (EVar "lhs"))) (fa "hintRhs" (EVar "rhs")) (fa "hintIntro" (EApp (EVar "introducedOf") (EVar "rhs"))) (fa "hintKey" (EApp (EVar "templateKey") (EVar "lhs")))))))))
(DTypeSig false "condMetas" (TyFun (TyApp (TyCon "List") (TyCon "HintCond")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "condMetas" ((PVar "conds")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EVar "toList") (EApp (EVar "condMeta") (EVar "c"))))) (EVar "conds")))
(DTypeSig false "rowFailure" (TyFun (TyCon "HintRow") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rowFailure" ((PVar "row") (PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hint row `")) (EApp (EVar "display") (EFieldAccess (EVar "row") "rowText"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ""))))
(DTypeSig true "compileHints" (TyFun (TyApp (TyCon "List") (TyCon "HintRow")) (TyApp (TyCon "List") (TyCon "Hint"))))
(DFunDef false "compileHints" ((PVar "rows")) (EApp (EApp (EVar "map") (EVar "compileOrPanic")) (EVar "rows")))
(DTypeSig false "compileOrPanic" (TyFun (TyCon "HintRow") (TyCon "Hint")))
(DFunDef false "compileOrPanic" ((PVar "row")) (EMatch (EApp (EVar "compileHint") (EVar "row")) (arm (PCon "Ok" (PVar "h")) () (EVar "h")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "panic") (EVar "m")))))
(DData Public "Found" () ((variant "Found" (ConNamed (field "foundBinds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr")))) (field "foundHeads" (TyApp (TyCon "List") (TyCon "Expr")))))) ())
(DTypeSig true "matchHint" (TyFun (TyCon "Hint") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Found")))))
(DFunDef false "matchHint" ((PVar "h") (PVar "subject")) (EMatch (EApp (EApp (EApp (EVar "matchT") (EFieldAccess (EVar "h") "hintLhs")) (EVar "subject")) (EApp (EApp (EVar "Found") (EListLit)) (EListLit))) (arm (PCon "Some" (PVar "found")) () (EIf (EApp (EApp (EVar "condsHold") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowConds")) (EVar "found")) (EApp (EVar "Some") (EVar "found")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "condsHold" (TyFun (TyApp (TyCon "List") (TyCon "HintCond")) (TyFun (TyCon "Found") (TyCon "Bool"))))
(DFunDef false "condsHold" ((PVar "conds") (PVar "found")) (EApp (EApp (EVar "all") (EApp (EVar "condHolds") (EVar "found"))) (EVar "conds")))
(DTypeSig false "condHolds" (TyFun (TyCon "Found") (TyFun (TyCon "HintCond") (TyCon "Bool"))))
(DFunDef false "condHolds" ((PVar "found") (PCon "Atomic" (PVar "m"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "m")) (EFieldAccess (EVar "found") "foundBinds")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "isAtomic") (EVar "e"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "condHolds" (PWild PWild) (EVar "True"))
(DTypeSig false "isAtomic" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAtomic" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "matchT" (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))
(DFunDef false "matchT" ((PCon "TMeta" (PVar "n")) (PVar "subject") (PVar "found")) (EApp (EApp (EApp (EVar "bindMeta") (EVar "n")) (EVar "subject")) (EVar "found")))
(DFunDef false "matchT" ((PCon "TName" (PVar "n") (PVar "isHead")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EVar" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EIf (EVar "isHead") (EApp (EApp (EVar "Found") (EFieldAccess (EVar "found") "foundBinds")) (EBinOp "::" (EVar "subject") (EFieldAccess (EVar "found") "foundHeads"))) (EVar "found"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TApp" (PVar "pf") (PVar "px")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EApp" (PVar "sf") (PVar "sx")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchBoth") (EVar "pf")) (EVar "sf")) (EVar "px")) (EVar "sx")) (EVar "found"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TBin" (PVar "op") (PVar "pa") (PVar "pb")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EBinOp" (PVar "op2") (PVar "sa") (PVar "sb") PWild) () (EIf (EBinOp "==" (EVar "op") (EVar "op2")) (EApp (EApp (EApp (EApp (EApp (EVar "matchBoth") (EVar "pa")) (EVar "sa")) (EVar "pb")) (EVar "sb")) (EVar "found")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TLeaf" (PVar "sexp")) (PVar "subject") (PVar "found")) (EIf (EBinOp "==" (EVar "sexp") (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "subject")))) (EApp (EVar "Some") (EVar "found")) (EVar "None")))
(DTypeSig false "matchBoth" (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))))
(DFunDef false "matchBoth" ((PVar "p1") (PVar "s1") (PVar "p2") (PVar "s2") (PVar "found")) (EMatch (EApp (EApp (EApp (EVar "matchT") (EVar "p1")) (EVar "s1")) (EVar "found")) (arm (PCon "Some" (PVar "found2")) () (EApp (EApp (EApp (EVar "matchT") (EVar "p2")) (EVar "s2")) (EVar "found2"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "bindMeta" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))
(DFunDef false "bindMeta" ((PVar "n") (PVar "subject") (PVar "found")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "found") "foundBinds")) (arm (PCon "Some" (PVar "prev")) () (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "prev"))) (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "subject")))) (EApp (EVar "Some") (EVar "found")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "Found") (EBinOp "::" (ETuple (EVar "n") (EVar "subject")) (EFieldAccess (EVar "found") "foundBinds"))) (EFieldAccess (EVar "found") "foundHeads"))))))
(DTypeSig true "instantiate" (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyCon "Expr"))))
(DFunDef false "instantiate" ((PVar "h") (PVar "found")) (EApp (EApp (EVar "fill") (EFieldAccess (EVar "found") "foundBinds")) (EFieldAccess (EVar "h") "hintRhs")))
(DTypeSig false "fill" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "fill" ((PVar "binds") (PCon "EVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "binds")) (arm (PCon "Some" (PVar "e")) () (EVar "e")) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))))
(DFunDef false "fill" ((PVar "binds") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "f"))) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "x"))))
(DFunDef false "fill" ((PVar "binds") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "a"))) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "b"))) (EVar "r")))
(DFunDef false "fill" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "hintKinds" (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyApp (TyCon "List") (TyCon "ExprKind"))))
(DFunDef false "hintKinds" ((PVar "hints")) (EApp (EApp (EApp (EVar "fold") (EVar "addKind")) (EListLit)) (EApp (EApp (EVar "map") (ELam ((PVar "h")) (EFieldAccess (EVar "h") "hintKind"))) (EVar "hints"))))
(DTypeSig false "addKind" (TyFun (TyApp (TyCon "List") (TyCon "ExprKind")) (TyFun (TyCon "ExprKind") (TyApp (TyCon "List") (TyCon "ExprKind")))))
(DFunDef false "addKind" ((PVar "seen") (PVar "k")) (EIf (EApp (EApp (EVar "elem") (EVar "k")) (EVar "seen")) (EVar "seen") (EBinOp "++" (EVar "seen") (EListLit (EVar "k")))))
(DTypeSig true "hintVisitors" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor")))))))))))
(DFunDef false "hintVisitors" ((PVar "name") (PVar "severity") (PVar "hints") (PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EApp (EVar "hintKinds") (EVar "hints"))) (EApp (EApp (EApp (EApp (EApp (EVar "hintsAt") (EVar "name")) (EVar "severity")) (EVar "hints")) (EVar "idx")) (EVar "facts")))))
(DTypeSig false "hintsAt" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "hintsAt" (PWild PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "hintsAt" ((PVar "name") (PVar "severity") (PCons (PVar "h") (PVar "rest")) (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EApp (EVar "nodeKey") (EVar "e"))) (EVar "name")) (EVar "severity")) (EBinOp "::" (EVar "h") (EVar "rest"))) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))
(DTypeSig false "hintsKeyed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "hintsKeyed" (PWild PWild PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "hintsKeyed" ((PVar "key") (PVar "name") (PVar "severity") (PCons (PVar "h") (PVar "rest")) (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EIf (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "h") "hintKey") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "h") "hintKey") (EVar "key"))) (EMatch (EApp (EApp (EVar "matchHint") (EVar "h")) (EVar "e")) (arm (PCon "Some" (PVar "found")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintFinding") (EVar "name")) (EVar "severity")) (EVar "h")) (EVar "found")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EVar "key")) (EVar "name")) (EVar "severity")) (EVar "rest")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EVar "key")) (EVar "name")) (EVar "severity")) (EVar "rest")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e"))))
(DTypeSig false "hintFinding" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyCon "Finding"))))))))))
(DFunDef false "hintFinding" ((PVar "name") (PVar "severity") (PVar "h") (PVar "found") (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EBlock (DoLet false false (PVar "rewritten") (EApp (EApp (EVar "instantiate") (EVar "h")) (EVar "found"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "name")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowMessage"))) (ELit (LString ". Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten"))))) (ELit (LString "'")))) (fa "severity" (EVar "severity")) (fa "loc" (EFieldAccess (EVar "ctx") "ctxSpan")) (fa "fix" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintFix") (EVar "h")) (EVar "found")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))))))
(DTypeSig false "hintFix" (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))))
(DFunDef false "hintFix" ((PVar "h") (PVar "found") (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "allHeadsPrelude") (EVar "idx")) (EVar "facts")) (EVar "found")) (EApp (EVar "not") (EApp (EApp (EVar "any") (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx"))) (EFieldAccess (EVar "h") "hintIntro")))) (EApp (EVar "not") (EApp (EApp (EVar "inOwnDefinition") (EVar "h")) (EVar "ctx")))) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowApplicability")) (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowFix")) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "allHeadsPrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Found") (TyCon "Bool")))))
(DFunDef false "allHeadsPrelude" ((PVar "idx") (PVar "facts") (PVar "found")) (EApp (EApp (EVar "all") (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts"))) (EFieldAccess (EVar "found") "foundHeads")))
(DTypeSig true "inOwnDefinition" (TyFun (TyCon "Hint") (TyFun (TyCon "Ctx") (TyCon "Bool"))))
(DFunDef false "inOwnDefinition" ((PVar "h") (PVar "ctx")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "ctx") "ctxInTest")) (EApp (EApp (EVar "any") (EApp (EVar "ownsName") (EVar "ctx"))) (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowConds"))))
(DTypeSig false "ownsName" (TyFun (TyCon "Ctx") (TyFun (TyCon "HintCond") (TyCon "Bool"))))
(DFunDef false "ownsName" ((PVar "ctx") (PCon "NotInDefOf" (PVar "names"))) (EApp (EApp (EVar "elem") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "names")))
(DFunDef false "ownsName" (PWild PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Decl" true) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "parseResult" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "isLower" false) (mem "isDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "StdlibIndex" false) (mem "Visitor" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "oneLine" false) (mem "rebinds" false) (mem "replaceNodeFix" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DUse false (UseGroup ("list") ((mem "nub" false))))
(DData Public "HintCond" () ((variant "Atomic" (ConPos (TyCon "String"))) (variant "NotInDefOf" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "HintRow" () ((variant "HintRow" (ConNamed (field "rowText" (TyCon "String")) (field "rowMessage" (TyCon "String")) (field "rowFix" (TyCon "String")) (field "rowApplicability" (TyCon "Applicability")) (field "rowConds" (TyApp (TyCon "List") (TyCon "HintCond")))))) ())
(DData Private "Tmpl" () ((variant "TMeta" (ConPos (TyCon "String"))) (variant "TName" (ConPos (TyCon "String") (TyCon "Bool"))) (variant "TApp" (ConPos (TyCon "Tmpl") (TyCon "Tmpl"))) (variant "TBin" (ConPos (TyCon "String") (TyCon "Tmpl") (TyCon "Tmpl"))) (variant "TLeaf" (ConPos (TyCon "String")))) ())
(DData Public "Hint" () ((variant "Hint" (ConNamed (field "hintRow" (TyCon "HintRow")) (field "hintKind" (TyCon "ExprKind")) (field "hintLhs" (TyCon "Tmpl")) (field "hintRhs" (TyCon "Expr")) (field "hintIntro" (TyApp (TyCon "List") (TyCon "String"))) (field "hintKey" (TyCon "String"))))) ())
(DTypeSig false "isMeta" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMeta" ((PVar "n")) (EMatch (EApp (EMethodRef "toList") (EApp (EVar "stringToChars") (EVar "n"))) (arm (PCons (PVar "c") (PVar "rest")) () (EBinOp "&&" (EApp (EVar "isLower") (EVar "c")) (EApp (EApp (EDictApp "all") (EVar "isDigit")) (EVar "rest")))) (arm (PList) () (EVar "False"))))
(DTypeSig false "isHeadName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHeadName" ((PVar "n")) (EMatch (EApp (EMethodRef "toList") (EApp (EVar "stringToChars") (EVar "n"))) (arm (PCons (PVar "c") PWild) () (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_"))))) (arm (PList) () (EVar "False"))))
(DTypeSig false "exprOfText" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "exprOfText" ((PVar "text")) (EMatch (EApp (EVar "parseResult") (EBinOp "++" (EBinOp "++" (ELit (LString "hint = ")) (EVar "text")) (ELit (LString "\n")))) (arm (PCon "Ok" (PList (PCon "DFunDef" PWild PWild (PList) (PVar "body") PWild PWild))) () (EApp (EVar "Ok") (EVar "body"))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "does not parse as an expression: ")) (EVar "text"))))))
(DTypeSig false "templateOf" (TyFun (TyCon "Expr") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "templateOf" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "templateOf") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "EVar" PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "ELit" PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PAs "e" (PCon "EListLit" (PList)))) (EApp (EVar "Ok") (EVar "e")))
(DFunDef false "templateOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EMatch (ETuple (EApp (EVar "templateOf") (EVar "f")) (EApp (EVar "templateOf") (EVar "x"))) (arm (PTuple (PCon "Ok" (PVar "f2")) (PCon "Ok" (PVar "x2"))) () (EApp (EVar "Ok") (EApp (EApp (EVar "EApp") (EVar "f2")) (EVar "x2")))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EVar "m"))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EVar "m")))))
(DFunDef false "templateOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EMatch (ETuple (EApp (EVar "templateOf") (EVar "a")) (EApp (EVar "templateOf") (EVar "b"))) (arm (PTuple (PCon "Ok" (PVar "a2")) (PCon "Ok" (PVar "b2"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a2")) (EVar "b2")) (EVar "r")))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EVar "m"))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EVar "m")))))
(DFunDef false "templateOf" (PWild) (EApp (EVar "Err") (ELit (LString "a template holds only names, literals, `[]`, applications and operators"))))
(DTypeSig false "introducedOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "introducedOf" ((PCon "EVar" (PVar "n"))) (EIf (EBinOp "||" (EApp (EVar "isMeta") (EVar "n")) (EApp (EVar "not") (EApp (EVar "isHeadName") (EVar "n")))) (EListLit) (EListLit (EVar "n"))))
(DFunDef false "introducedOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "nub") (EBinOp "++" (EApp (EVar "introducedOf") (EVar "f")) (EApp (EVar "introducedOf") (EVar "x")))))
(DFunDef false "introducedOf" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EVar "nub") (EBinOp "++" (EApp (EVar "introducedOf") (EVar "a")) (EApp (EVar "introducedOf") (EVar "b")))))
(DFunDef false "introducedOf" (PWild) (EListLit))
(DTypeSig false "metasOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metasOf" ((PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isMeta") (EVar "n")) (EListLit (EVar "n")) (EListLit)))
(DFunDef false "metasOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "metasOf") (EVar "f")) (EApp (EVar "metasOf") (EVar "x"))))
(DFunDef false "metasOf" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "metasOf") (EVar "a")) (EApp (EVar "metasOf") (EVar "b"))))
(DFunDef false "metasOf" (PWild) (EListLit))
(DTypeSig false "tmplOf" (TyFun (TyCon "Expr") (TyCon "Tmpl")))
(DFunDef false "tmplOf" ((PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isMeta") (EVar "n")) (EApp (EVar "TMeta") (EVar "n")) (EApp (EApp (EVar "TName") (EVar "n")) (EApp (EVar "isHeadName") (EVar "n")))))
(DFunDef false "tmplOf" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "TApp") (EApp (EVar "tmplOf") (EVar "f"))) (EApp (EVar "tmplOf") (EVar "x"))))
(DFunDef false "tmplOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EApp (EApp (EApp (EVar "TBin") (EVar "op")) (EApp (EVar "tmplOf") (EVar "a"))) (EApp (EVar "tmplOf") (EVar "b"))))
(DFunDef false "tmplOf" ((PVar "e")) (EApp (EVar "TLeaf") (EApp (EVar "exprSexp") (EVar "e"))))
(DTypeSig false "templateKey" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "templateKey" ((PVar "e")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "nodeKey") (EVar "e"))) (DoExpr (EIf (EApp (EVar "isMeta") (EVar "k")) (ELit (LString "")) (EVar "k")))))
(DTypeSig false "nodeKey" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeKey" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "spineHead") (EVar "f"))) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EVar "op")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "spineHead" ((PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EVar "spineHead") (EVar "g"))) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rootKind" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "ExprKind"))))
(DFunDef false "rootKind" ((PCon "EApp" PWild PWild)) (EApp (EVar "Some") (EVar "KApp")))
(DFunDef false "rootKind" ((PCon "EBinOp" PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "KBinOp")))
(DFunDef false "rootKind" (PWild) (EVar "None"))
(DTypeSig false "condMeta" (TyFun (TyCon "HintCond") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "condMeta" ((PCon "Atomic" (PVar "m"))) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "condMeta" (PWild) (EVar "None"))
(DTypeSig true "compileHint" (TyFun (TyCon "HintRow") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))
(DFunDef false "compileHint" ((PVar "row")) (EMatch (EApp (EApp (EVar "split") (ELit (LString " ==> "))) (EFieldAccess (EVar "row") "rowText")) (arm (PList (PVar "lhsText") (PVar "rhsText")) () (EMatch (ETuple (EApp (EVar "exprOfText") (EVar "lhsText")) (EApp (EVar "exprOfText") (EVar "rhsText"))) (arm (PTuple (PCon "Ok" (PVar "l")) (PCon "Ok" (PVar "r"))) () (EMatch (ETuple (EApp (EVar "templateOf") (EVar "l")) (EApp (EVar "templateOf") (EVar "r"))) (arm (PTuple (PCon "Ok" (PVar "lhs")) (PCon "Ok" (PVar "rhs"))) () (EApp (EApp (EApp (EVar "checkHint") (EVar "row")) (EVar "lhs")) (EVar "rhs"))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))))) (arm (PTuple (PCon "Err" (PVar "m")) PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))) (arm (PTuple PWild (PCon "Err" (PVar "m"))) () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (EVar "m")))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "expected exactly one ` ==> `")))))))
(DTypeSig false "checkHint" (TyFun (TyCon "HintRow") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))))
(DFunDef false "checkHint" ((PVar "row") (PVar "lhs") (PVar "rhs")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "metasOf") (EVar "lhs"))) (DoExpr (EMatch (EApp (EVar "rootKind") (EVar "lhs")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "the left side is not an application or an operator"))))) (arm (PCon "Some" (PVar "kind")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkBound") (EVar "row")) (EVar "kind")) (EVar "lhs")) (EVar "rhs")) (EVar "bound")))))))
(DTypeSig false "checkBound" (TyFun (TyCon "HintRow") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Hint"))))))))
(DFunDef false "checkBound" ((PVar "row") (PVar "kind") (PVar "lhs") (PVar "rhs") (PVar "bound")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "m")) (EVar "bound"))))) (EApp (EVar "metasOf") (EVar "rhs"))) (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "the right side uses a metavariable the left side does not bind")))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "m")) (EVar "bound"))))) (EApp (EVar "condMetas") (EFieldAccess (EVar "row") "rowConds"))) (EApp (EVar "Err") (EApp (EApp (EVar "rowFailure") (EVar "row")) (ELit (LString "a condition names a metavariable the left side does not bind")))) (EApp (EVar "Ok") (ERecordCreate "Hint" ((fa "hintRow" (EVar "row")) (fa "hintKind" (EVar "kind")) (fa "hintLhs" (EApp (EVar "tmplOf") (EVar "lhs"))) (fa "hintRhs" (EVar "rhs")) (fa "hintIntro" (EApp (EVar "introducedOf") (EVar "rhs"))) (fa "hintKey" (EApp (EVar "templateKey") (EVar "lhs")))))))))
(DTypeSig false "condMetas" (TyFun (TyApp (TyCon "List") (TyCon "HintCond")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "condMetas" ((PVar "conds")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EMethodRef "toList") (EApp (EVar "condMeta") (EVar "c"))))) (EVar "conds")))
(DTypeSig false "rowFailure" (TyFun (TyCon "HintRow") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rowFailure" ((PVar "row") (PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hint row `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "row") "rowText"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ""))))
(DTypeSig true "compileHints" (TyFun (TyApp (TyCon "List") (TyCon "HintRow")) (TyApp (TyCon "List") (TyCon "Hint"))))
(DFunDef false "compileHints" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (EVar "compileOrPanic")) (EVar "rows")))
(DTypeSig false "compileOrPanic" (TyFun (TyCon "HintRow") (TyCon "Hint")))
(DFunDef false "compileOrPanic" ((PVar "row")) (EMatch (EApp (EVar "compileHint") (EVar "row")) (arm (PCon "Ok" (PVar "h")) () (EVar "h")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "panic") (EVar "m")))))
(DData Public "Found" () ((variant "Found" (ConNamed (field "foundBinds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr")))) (field "foundHeads" (TyApp (TyCon "List") (TyCon "Expr")))))) ())
(DTypeSig true "matchHint" (TyFun (TyCon "Hint") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Found")))))
(DFunDef false "matchHint" ((PVar "h") (PVar "subject")) (EMatch (EApp (EApp (EApp (EVar "matchT") (EFieldAccess (EVar "h") "hintLhs")) (EVar "subject")) (EApp (EApp (EVar "Found") (EListLit)) (EListLit))) (arm (PCon "Some" (PVar "found")) () (EIf (EApp (EApp (EVar "condsHold") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowConds")) (EVar "found")) (EApp (EVar "Some") (EVar "found")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "condsHold" (TyFun (TyApp (TyCon "List") (TyCon "HintCond")) (TyFun (TyCon "Found") (TyCon "Bool"))))
(DFunDef false "condsHold" ((PVar "conds") (PVar "found")) (EApp (EApp (EDictApp "all") (EApp (EVar "condHolds") (EVar "found"))) (EVar "conds")))
(DTypeSig false "condHolds" (TyFun (TyCon "Found") (TyFun (TyCon "HintCond") (TyCon "Bool"))))
(DFunDef false "condHolds" ((PVar "found") (PCon "Atomic" (PVar "m"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "m")) (EFieldAccess (EVar "found") "foundBinds")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "isAtomic") (EVar "e"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "condHolds" (PWild PWild) (EVar "True"))
(DTypeSig false "isAtomic" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAtomic" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "matchT" (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))
(DFunDef false "matchT" ((PCon "TMeta" (PVar "n")) (PVar "subject") (PVar "found")) (EApp (EApp (EApp (EVar "bindMeta") (EVar "n")) (EVar "subject")) (EVar "found")))
(DFunDef false "matchT" ((PCon "TName" (PVar "n") (PVar "isHead")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EVar" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EIf (EVar "isHead") (EApp (EApp (EVar "Found") (EFieldAccess (EVar "found") "foundBinds")) (EBinOp "::" (EVar "subject") (EFieldAccess (EVar "found") "foundHeads"))) (EVar "found"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TApp" (PVar "pf") (PVar "px")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EApp" (PVar "sf") (PVar "sx")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchBoth") (EVar "pf")) (EVar "sf")) (EVar "px")) (EVar "sx")) (EVar "found"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TBin" (PVar "op") (PVar "pa") (PVar "pb")) (PVar "subject") (PVar "found")) (EMatch (EApp (EVar "unwrapLoc") (EVar "subject")) (arm (PCon "EBinOp" (PVar "op2") (PVar "sa") (PVar "sb") PWild) () (EIf (EBinOp "==" (EVar "op") (EVar "op2")) (EApp (EApp (EApp (EApp (EApp (EVar "matchBoth") (EVar "pa")) (EVar "sa")) (EVar "pb")) (EVar "sb")) (EVar "found")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchT" ((PCon "TLeaf" (PVar "sexp")) (PVar "subject") (PVar "found")) (EIf (EBinOp "==" (EVar "sexp") (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "subject")))) (EApp (EVar "Some") (EVar "found")) (EVar "None")))
(DTypeSig false "matchBoth" (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Tmpl") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))))
(DFunDef false "matchBoth" ((PVar "p1") (PVar "s1") (PVar "p2") (PVar "s2") (PVar "found")) (EMatch (EApp (EApp (EApp (EVar "matchT") (EVar "p1")) (EVar "s1")) (EVar "found")) (arm (PCon "Some" (PVar "found2")) () (EApp (EApp (EApp (EVar "matchT") (EVar "p2")) (EVar "s2")) (EVar "found2"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "bindMeta" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Found") (TyApp (TyCon "Option") (TyCon "Found"))))))
(DFunDef false "bindMeta" ((PVar "n") (PVar "subject") (PVar "found")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "found") "foundBinds")) (arm (PCon "Some" (PVar "prev")) () (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "prev"))) (EApp (EVar "exprSexp") (EApp (EVar "unwrapLoc") (EVar "subject")))) (EApp (EVar "Some") (EVar "found")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "Found") (EBinOp "::" (ETuple (EVar "n") (EVar "subject")) (EFieldAccess (EVar "found") "foundBinds"))) (EFieldAccess (EVar "found") "foundHeads"))))))
(DTypeSig true "instantiate" (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyCon "Expr"))))
(DFunDef false "instantiate" ((PVar "h") (PVar "found")) (EApp (EApp (EVar "fill") (EFieldAccess (EVar "found") "foundBinds")) (EFieldAccess (EVar "h") "hintRhs")))
(DTypeSig false "fill" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "fill" ((PVar "binds") (PCon "EVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "binds")) (arm (PCon "Some" (PVar "e")) () (EVar "e")) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))))
(DFunDef false "fill" ((PVar "binds") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "f"))) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "x"))))
(DFunDef false "fill" ((PVar "binds") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "a"))) (EApp (EApp (EVar "fill") (EVar "binds")) (EVar "b"))) (EVar "r")))
(DFunDef false "fill" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "hintKinds" (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyApp (TyCon "List") (TyCon "ExprKind"))))
(DFunDef false "hintKinds" ((PVar "hints")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "addKind")) (EListLit)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "h")) (EFieldAccess (EVar "h") "hintKind"))) (EVar "hints"))))
(DTypeSig false "addKind" (TyFun (TyApp (TyCon "List") (TyCon "ExprKind")) (TyFun (TyCon "ExprKind") (TyApp (TyCon "List") (TyCon "ExprKind")))))
(DFunDef false "addKind" ((PVar "seen") (PVar "k")) (EIf (EApp (EApp (EDictApp "elem") (EVar "k")) (EVar "seen")) (EVar "seen") (EBinOp "++" (EVar "seen") (EListLit (EVar "k")))))
(DTypeSig true "hintVisitors" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor")))))))))))
(DFunDef false "hintVisitors" ((PVar "name") (PVar "severity") (PVar "hints") (PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EApp (EVar "hintKinds") (EVar "hints"))) (EApp (EApp (EApp (EApp (EApp (EVar "hintsAt") (EVar "name")) (EVar "severity")) (EVar "hints")) (EVar "idx")) (EVar "facts")))))
(DTypeSig false "hintsAt" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "hintsAt" (PWild PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "hintsAt" ((PVar "name") (PVar "severity") (PCons (PVar "h") (PVar "rest")) (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EApp (EVar "nodeKey") (EVar "e"))) (EVar "name")) (EVar "severity")) (EBinOp "::" (EVar "h") (EVar "rest"))) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))
(DTypeSig false "hintsKeyed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyApp (TyCon "List") (TyCon "Hint")) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "hintsKeyed" (PWild PWild PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "hintsKeyed" ((PVar "key") (PVar "name") (PVar "severity") (PCons (PVar "h") (PVar "rest")) (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EIf (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "h") "hintKey") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "h") "hintKey") (EVar "key"))) (EMatch (EApp (EApp (EVar "matchHint") (EVar "h")) (EVar "e")) (arm (PCon "Some" (PVar "found")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintFinding") (EVar "name")) (EVar "severity")) (EVar "h")) (EVar "found")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EVar "key")) (EVar "name")) (EVar "severity")) (EVar "rest")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintsKeyed") (EVar "key")) (EVar "name")) (EVar "severity")) (EVar "rest")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e"))))
(DTypeSig false "hintFinding" (TyFun (TyCon "String") (TyFun (TyCon "Severity") (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyCon "Finding"))))))))))
(DFunDef false "hintFinding" ((PVar "name") (PVar "severity") (PVar "h") (PVar "found") (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EBlock (DoLet false false (PVar "rewritten") (EApp (EApp (EVar "instantiate") (EVar "h")) (EVar "found"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "name")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowMessage"))) (ELit (LString ". Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "oneLine") (EApp (EVar "exprToString") (EVar "rewritten"))))) (ELit (LString "'")))) (fa "severity" (EVar "severity")) (fa "loc" (EFieldAccess (EVar "ctx") "ctxSpan")) (fa "fix" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintFix") (EVar "h")) (EVar "found")) (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))))))
(DTypeSig false "hintFix" (TyFun (TyCon "Hint") (TyFun (TyCon "Found") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))))
(DFunDef false "hintFix" ((PVar "h") (PVar "found") (PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EVar "allHeadsPrelude") (EVar "idx")) (EVar "facts")) (EVar "found")) (EApp (EVar "not") (EApp (EApp (EDictApp "any") (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx"))) (EFieldAccess (EVar "h") "hintIntro")))) (EApp (EVar "not") (EApp (EApp (EVar "inOwnDefinition") (EVar "h")) (EVar "ctx")))) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowApplicability")) (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowFix")) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "allHeadsPrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Found") (TyCon "Bool")))))
(DFunDef false "allHeadsPrelude" ((PVar "idx") (PVar "facts") (PVar "found")) (EApp (EApp (EDictApp "all") (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts"))) (EFieldAccess (EVar "found") "foundHeads")))
(DTypeSig true "inOwnDefinition" (TyFun (TyCon "Hint") (TyFun (TyCon "Ctx") (TyCon "Bool"))))
(DFunDef false "inOwnDefinition" ((PVar "h") (PVar "ctx")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "ctx") "ctxInTest")) (EApp (EApp (EDictApp "any") (EApp (EVar "ownsName") (EVar "ctx"))) (EFieldAccess (EFieldAccess (EVar "h") "hintRow") "rowConds"))))
(DTypeSig false "ownsName" (TyFun (TyCon "Ctx") (TyFun (TyCon "HintCond") (TyCon "Bool"))))
(DFunDef false "ownsName" ((PVar "ctx") (PCon "NotInDefOf" (PVar "names"))) (EApp (EApp (EDictApp "elem") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "names")))
(DFunDef false "ownsName" (PWild PWild) (EVar "False"))
