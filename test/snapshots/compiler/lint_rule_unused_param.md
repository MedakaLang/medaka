# META
source_lines=267
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-unused-param: a function, method or `prop` parameter that no use in its clause resolves to. Rename it `_name` to say it is unused.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Decl(..),
  Expr(..),
  FunClause(..),
  LetBind(..),
  Loc(..),
  Pat(..),
  PropParam(..),
  RecPatField(..),
}
import frontend.ast_walk.{BodyOwner(..), DeclBody(..), childExprs, declBodies}
import frontend.parser.{
  DeclPos,
  Positions(..),
  declPosEndLine,
  declPosLine,
  positionsDecls,
}
import string.{length as strLength, sliceClamped}
import array.{get as arrayGet}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  FileFacts(..),
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factLines,
  factScopes,
  mkRule,
}
import tools.lint_scope.{
  Binder(..),
  BinderKind(..),
  FileScopes,
  binderOf,
  bindersNamedIn,
  unusedBinders,
  usesNamedIn,
}
import tools.lint_shared.{ruleNameUnusedParam}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameUnusedParam,
      summary =
        "a function, method or `prop` parameter that nothing in its clause uses",
      doc =
        "A parameter that no use in its clause resolves to is dead weight, and a reader cannot tell it from one that matters. Renaming it `_name` says it is intentionally unused, and a name starting with `_` is not reported. Function, impl-method, interface-default, `prop`, `where` and top-level `let rec` clause parameters are checked; the parameters of a `let rec` written inside a block, and lambda, `let`, match-arm and `do`-bind binders, are not. The fix renames every place the binder is written (each alternative of an or-pattern names it). An unused as-binder `x@p` is not renamed: the fix drops `x@` and keeps the pattern. The rename is only suggested, not applied, when `_name` is already used in the declaration, and for a record pun, where renaming the binder would rename the field: the suggestion then reads `field = _name`.\n\nBefore:\n  area w h = w * 2\nAfter:\n  area w _h = w * 2",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes],
    }
    ruleUnusedParam
    None

ruleUnusedParam : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleUnusedParam _ _ facts pos prog =
  let fs = factScopes facts
  let unused = filter (b => b.binderKind == BParam) (unusedBinders fs)
  if isEmpty unused then
    []
  else
    let sites = flatMap declParamSites prog
    flatMap (paramFinding facts pos sites) unused

-- How a parameter name token is written: plainly, as a record pun (a field `{x}`
-- that binds `x`, so renaming the binder renames the field), or as the binder of
-- an as-pattern `x@p`.
data SiteKind = SitePlain | SitePun | SiteAs deriving (Eq)

-- One parameter name token: its name, its span and how it is written.
data ParamSite = ParamSite String Loc SiteKind

-- The parameter sites of one declaration: those of each body's owner, then
-- those of every `where` or `let rec` clause nested in a body.
declParamSites : Decl -> List ParamSite
declParamSites d = flatMap bodyParamSites (declBodies d)

bodyParamSites : DeclBody -> List ParamSite
bodyParamSites (DeclBody owner body) =
  ownerParamSites owner ++ exprParamSites body

ownerParamSites : BodyOwner -> List ParamSite
ownerParamSites (OwnerClause _ ps) = flatMap patParamSites ps
ownerParamSites (OwnerImplMethod _ _ ps) = flatMap patParamSites ps
ownerParamSites (OwnerIfaceDefault _ _ ps) = flatMap patParamSites ps
ownerParamSites (OwnerLetGroup _ ps) = flatMap patParamSites ps
ownerParamSites (OwnerProp _ params) = map propParamSite params
ownerParamSites (OwnerTest _) = []

propParamSite : PropParam -> ParamSite
propParamSite (PropParam n l _) = ParamSite n l SitePlain

exprParamSites : Expr -> List ParamSite
exprParamSites e = groupParamSites e ++ flatMap exprParamSites (childExprs e)

groupParamSites : Expr -> List ParamSite
groupParamSites (ELetGroup binds _) = flatMap bindParamSites binds
groupParamSites _ = []

bindParamSites : LetBind -> List ParamSite
bindParamSites (LetBind _ clauses _ _) = flatMap clauseParamSites clauses

clauseParamSites : FunClause -> List ParamSite
clauseParamSites (FunClause ps _) = flatMap patParamSites ps

-- Every name a pattern binds, with its token.  Each alternative of an or-pattern
-- is listed, since each one names the binder.
patParamSites : Pat -> List ParamSite
patParamSites (PVar x l _) = [ParamSite x l SitePlain]
patParamSites PWild = []
patParamSites (PLit _) = []
patParamSites (PCon _ ps) = flatMap patParamSites ps
patParamSites (PCons a b) = patParamSites a ++ patParamSites b
patParamSites (PTuple ps) = flatMap patParamSites ps
patParamSites (PList ps) = flatMap patParamSites ps
patParamSites (PAs x l _ p) = ParamSite x l SiteAs :: patParamSites p
patParamSites (POr ps) = flatMap patParamSites ps
patParamSites (PRng _ _ _) = []
patParamSites (PRec _ fields _) = flatMap fieldParamSites fields

fieldParamSites : RecPatField -> List ParamSite
fieldParamSites (RecPatField n l _ None) = [ParamSite n l SitePun]
fieldParamSites (RecPatField _ _ _ (Some p)) = patParamSites p

-- One finding per unused parameter, at its binder token.
paramFinding : FileFacts ->
  Positions ->
  List ParamSite ->
  Binder ->
  List Finding
paramFinding facts pos sites b =
  let fs = factScopes facts
  let mine = filter (binderIs fs b) sites
  [
    Finding {
      rule = ruleNameUnusedParam,
      message =
        "parameter '\{b.binderName}' is never used. Rename it to '_\{b.binderName}' to mark it intentionally unused",
      severity = SevWarning,
      loc = Some b.binderSpan,
      fix = paramFix facts (declLines pos b) b mine,
    },
  ]

-- A site belongs to the binder when the scope model resolves its position to it.
binderIs : FileScopes -> Binder -> ParamSite -> Bool
binderIs fs b (ParamSite _ l _) = match binderOf fs l
  Some c => c.binderId == b.binderId
  None => False

-- The first and last line of the top-level declaration that holds the binder.
declLines : Positions -> Binder -> (Int, Int)
declLines pos b =
  let line = locLine b.binderSpan
  optionOr
    (1, maxLine)
    (find
      (r => fst r <= line && line <= snd r)
      (map declPosRange (positionsDecls pos)))

-- Past any line a source can have, so a binder no declaration holds is checked
-- against the whole file.
maxLine : Int
maxLine = 1073741824

declPosRange : DeclPos -> (Int, Int)
declPosRange d = (declPosLine d, declPosEndLine d)

locLine : Loc -> Int
locLine (Loc _ l _ _ _) = l

-- The fix of every site of the binder.  An unused as-binder that is only ever
-- written as one drops its `x@`.  Otherwise the sites are renamed.  No fix when
-- the walk did not place the binder's own token, or a site is not exactly its
-- name's width: the edit would then land on the wrong text.  A suggestion
-- instead of a fix when a pun is among the sites, or `_name` is already used in
-- the declaration.
paramFix : FileFacts -> (Int, Int) -> Binder -> List ParamSite -> Option Fix
paramFix facts range b mine =
  let name = b.binderName
  let hasPun = any (s => siteKind s == SitePun) mine
  if not (any (s => siteLoc s == b.binderSpan) mine)
    || not (all (exactName name) mine) then
    None
  else if all (s => siteKind s == SiteAs) mine then
    dropAsFix (factLines facts) mine
  else if hasPun || collides (factScopes facts) range name then
    Some (renameFix Suggest name mine)
  else
    Some (renameFix Safe name mine)

renameFix : Applicability -> String -> List ParamSite -> Fix
renameFix applicability name mine = Fix {
  fixApplicability = applicability,
  fixEdits = map (s => FixEdit (siteLoc s) (renamedText name s)) mine,
  fixMessage = "rename the unused parameter",
}

renamedText : String -> ParamSite -> String
renamedText name (ParamSite _ _ kind) =
  if kind == SitePun then "\{name} = _\{name}" else "_\{name}"

-- Deleting `x@` from each site.  No fix unless an `@` stands right after every
-- name token, since the parser keeps only the name's span.
dropAsFix : Array String -> List ParamSite -> Option Fix
dropAsFix lines mine =
  if all (atFollows lines) mine then
    Some Fix {
      fixApplicability = Safe,
      fixEdits = map dropAsEdit mine,
      fixMessage = "drop the unused as-binder and keep its pattern",
    }
  else
    None

dropAsEdit : ParamSite -> FixEdit
dropAsEdit (ParamSite _ (Loc f sl sc el ec) _) =
  FixEdit (Loc f sl sc el (ec + 1)) ""

atFollows : Array String -> ParamSite -> Bool
atFollows lines (ParamSite _ (Loc _ _ _ el ec) _) =
  match arrayGet (el - 1) lines
    Some text => sliceClamped ec (ec + 1) text == "@"
    None => False

-- `_name` already names a binder or a use on a line of the declaration, so the
-- rename could clash with it or capture it.
collides : FileScopes -> (Int, Int) -> String -> Bool
collides fs (lo, hi) name =
  let renamed = "_" ++ name
  not (isEmpty (bindersNamedIn fs lo hi renamed))
    || not (isEmpty (usesNamedIn fs lo hi renamed))

-- The site spans its name token: one line, as many columns as the name has
-- characters.
exactName : String -> ParamSite -> Bool
exactName name (ParamSite _ (Loc _ sl sc el ec) _) =
  sl == el && ec - sc == strLength name

siteLoc : ParamSite -> Loc
siteLoc (ParamSite _ l _) = l

siteKind : ParamSite -> SiteKind
siteKind (ParamSite _ _ kind) = kind
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "DeclPos" false) (mem "Positions" true) (mem "declPosEndLine" false) (mem "declPosLine" false) (mem "positionsDecls" false))))
(DUse false (UseGroup ("string") ((mem "length" false "strLength") (mem "sliceClamped" false))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factLines" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false) (mem "bindersNamedIn" false) (mem "unusedBinders" false) (mem "usesNamedIn" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedParam" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedParam")) (fa "summary" (ELit (LString "a function, method or `prop` parameter that nothing in its clause uses"))) (fa "doc" (ELit (LString "A parameter that no use in its clause resolves to is dead weight, and a reader cannot tell it from one that matters. Renaming it `_name` says it is intentionally unused, and a name starting with `_` is not reported. Function, impl-method, interface-default, `prop`, `where` and top-level `let rec` clause parameters are checked; the parameters of a `let rec` written inside a block, and lambda, `let`, match-arm and `do`-bind binders, are not. The fix renames every place the binder is written (each alternative of an or-pattern names it). An unused as-binder `x@p` is not renamed: the fix drops `x@` and keeps the pattern. The rename is only suggested, not applied, when `_name` is already used in the declaration, and for a record pun, where renaming the binder would rename the field: the suggestion then reads `field = _name`.\n\nBefore:\n  area w h = w * 2\nAfter:\n  area w _h = w * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedParam")) (EVar "None")))
(DTypeSig false "ruleUnusedParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedParam" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "unused") (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BParam")))) (EApp (EVar "unusedBinders") (EVar "fs")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "unused")) (EListLit) (EBlock (DoLet false false (PVar "sites") (EApp (EApp (EVar "flatMap") (EVar "declParamSites")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "paramFinding") (EVar "facts")) (EVar "pos")) (EVar "sites"))) (EVar "unused"))))))))
(DData Private "SiteKind" () ((variant "SitePlain" (ConPos)) (variant "SitePun" (ConPos)) (variant "SiteAs" (ConPos))) ())
(DImpl true "Eq" ((TyCon "SiteKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SitePlain") (PCon "SitePlain")) () (EVar "True")) (arm (PTuple (PCon "SitePun") (PCon "SitePun")) () (EVar "True")) (arm (PTuple (PCon "SiteAs") (PCon "SiteAs")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Private "ParamSite" () ((variant "ParamSite" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "SiteKind")))) ())
(DTypeSig false "declParamSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "declParamSites" ((PVar "d")) (EApp (EApp (EVar "flatMap") (EVar "bodyParamSites")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyParamSites" (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "bodyParamSites" ((PCon "DeclBody" (PVar "owner") (PVar "body"))) (EBinOp "++" (EApp (EVar "ownerParamSites") (EVar "owner")) (EApp (EVar "exprParamSites") (EVar "body"))))
(DTypeSig false "ownerParamSites" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "ownerParamSites" ((PCon "OwnerClause" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerImplMethod" PWild PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerIfaceDefault" PWild PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerLetGroup" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerProp" PWild (PVar "params"))) (EApp (EApp (EVar "map") (EVar "propParamSite")) (EVar "params")))
(DFunDef false "ownerParamSites" ((PCon "OwnerTest" PWild)) (EListLit))
(DTypeSig false "propParamSite" (TyFun (TyCon "PropParam") (TyCon "ParamSite")))
(DFunDef false "propParamSite" ((PCon "PropParam" (PVar "n") (PVar "l") PWild)) (EApp (EApp (EApp (EVar "ParamSite") (EVar "n")) (EVar "l")) (EVar "SitePlain")))
(DTypeSig false "exprParamSites" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "exprParamSites" ((PVar "e")) (EBinOp "++" (EApp (EVar "groupParamSites") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "exprParamSites")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "groupParamSites" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "groupParamSites" ((PCon "ELetGroup" (PVar "binds") PWild)) (EApp (EApp (EVar "flatMap") (EVar "bindParamSites")) (EVar "binds")))
(DFunDef false "groupParamSites" (PWild) (EListLit))
(DTypeSig false "bindParamSites" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "bindParamSites" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "clauseParamSites")) (EVar "clauses")))
(DTypeSig false "clauseParamSites" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "clauseParamSites" ((PCon "FunClause" (PVar "ps") PWild)) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DTypeSig false "patParamSites" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "patParamSites" ((PCon "PVar" (PVar "x") (PVar "l") PWild)) (EListLit (EApp (EApp (EApp (EVar "ParamSite") (EVar "x")) (EVar "l")) (EVar "SitePlain"))))
(DFunDef false "patParamSites" ((PCon "PWild")) (EListLit))
(DFunDef false "patParamSites" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patParamSites" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patParamSites") (EVar "a")) (EApp (EVar "patParamSites") (EVar "b"))))
(DFunDef false "patParamSites" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PAs" (PVar "x") (PVar "l") PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "ParamSite") (EVar "x")) (EVar "l")) (EVar "SiteAs")) (EApp (EVar "patParamSites") (EVar "p"))))
(DFunDef false "patParamSites" ((PCon "POr" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patParamSites" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "fieldParamSites")) (EVar "fields")))
(DTypeSig false "fieldParamSites" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "fieldParamSites" ((PCon "RecPatField" (PVar "n") (PVar "l") PWild (PCon "None"))) (EListLit (EApp (EApp (EApp (EVar "ParamSite") (EVar "n")) (EVar "l")) (EVar "SitePun"))))
(DFunDef false "fieldParamSites" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patParamSites") (EVar "p")))
(DTypeSig false "paramFinding" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyFun (TyCon "Binder") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "paramFinding" ((PVar "facts") (PVar "pos") (PVar "sites") (PVar "b")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "mine") (EApp (EApp (EVar "filter") (EApp (EApp (EVar "binderIs") (EVar "fs")) (EVar "b"))) (EVar "sites"))) (DoExpr (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "parameter '")) (EApp (EVar "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is never used. Rename it to '_"))) (EApp (EVar "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' to mark it intentionally unused")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EFieldAccess (EVar "b") "binderSpan"))) (fa "fix" (EApp (EApp (EApp (EApp (EVar "paramFix") (EVar "facts")) (EApp (EApp (EVar "declLines") (EVar "pos")) (EVar "b"))) (EVar "b")) (EVar "mine")))))))))
(DTypeSig false "binderIs" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Binder") (TyFun (TyCon "ParamSite") (TyCon "Bool")))))
(DFunDef false "binderIs" ((PVar "fs") (PVar "b") (PCon "ParamSite" PWild (PVar "l") PWild)) (EMatch (EApp (EApp (EVar "binderOf") (EVar "fs")) (EVar "l")) (arm (PCon "Some" (PVar "c")) () (EBinOp "==" (EFieldAccess (EVar "c") "binderId") (EFieldAccess (EVar "b") "binderId"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "declLines" (TyFun (TyCon "Positions") (TyFun (TyCon "Binder") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "declLines" ((PVar "pos") (PVar "b")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "locLine") (EFieldAccess (EVar "b") "binderSpan"))) (DoExpr (EApp (EApp (EVar "optionOr") (ETuple (ELit (LInt 1)) (EVar "maxLine"))) (EApp (EApp (EVar "find") (ELam ((PVar "r")) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "fst") (EVar "r")) (EVar "line")) (EBinOp "<=" (EVar "line") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EVar "map") (EVar "declPosRange")) (EApp (EVar "positionsDecls") (EVar "pos"))))))))
(DTypeSig false "maxLine" (TyCon "Int"))
(DFunDef false "maxLine" () (ELit (LInt 1073741824)))
(DTypeSig false "declPosRange" (TyFun (TyCon "DeclPos") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declPosRange" ((PVar "d")) (ETuple (EApp (EVar "declPosLine") (EVar "d")) (EApp (EVar "declPosEndLine") (EVar "d"))))
(DTypeSig false "locLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "locLine" ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "paramFix" (TyFun (TyCon "FileFacts") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Binder") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "paramFix" ((PVar "facts") (PVar "range") (PVar "b") (PVar "mine")) (EBlock (DoLet false false (PVar "name") (EFieldAccess (EVar "b") "binderName")) (DoLet false false (PVar "hasPun") (EApp (EApp (EVar "any") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteKind") (EVar "s")) (EVar "SitePun")))) (EVar "mine"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "any") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteLoc") (EVar "s")) (EFieldAccess (EVar "b") "binderSpan")))) (EVar "mine"))) (EApp (EVar "not") (EApp (EApp (EVar "all") (EApp (EVar "exactName") (EVar "name"))) (EVar "mine")))) (EVar "None") (EIf (EApp (EApp (EVar "all") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteKind") (EVar "s")) (EVar "SiteAs")))) (EVar "mine")) (EApp (EApp (EVar "dropAsFix") (EApp (EVar "factLines") (EVar "facts"))) (EVar "mine")) (EIf (EBinOp "||" (EVar "hasPun") (EApp (EApp (EApp (EVar "collides") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "range")) (EVar "name"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "renameFix") (EVar "Suggest")) (EVar "name")) (EVar "mine"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "renameFix") (EVar "Safe")) (EVar "name")) (EVar "mine")))))))))
(DTypeSig false "renameFix" (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyCon "Fix")))))
(DFunDef false "renameFix" ((PVar "applicability") (PVar "name") (PVar "mine")) (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "applicability")) (fa "fixEdits" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EApp (EVar "FixEdit") (EApp (EVar "siteLoc") (EVar "s"))) (EApp (EApp (EVar "renamedText") (EVar "name")) (EVar "s"))))) (EVar "mine"))) (fa "fixMessage" (ELit (LString "rename the unused parameter"))))))
(DTypeSig false "renamedText" (TyFun (TyCon "String") (TyFun (TyCon "ParamSite") (TyCon "String"))))
(DFunDef false "renamedText" ((PVar "name") (PCon "ParamSite" PWild PWild (PVar "kind"))) (EIf (EBinOp "==" (EVar "kind") (EVar "SitePun")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = _"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "_")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "dropAsFix" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "dropAsFix" ((PVar "lines") (PVar "mine")) (EIf (EApp (EApp (EVar "all") (EApp (EVar "atFollows") (EVar "lines"))) (EVar "mine")) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EApp (EApp (EVar "map") (EVar "dropAsEdit")) (EVar "mine"))) (fa "fixMessage" (ELit (LString "drop the unused as-binder and keep its pattern")))))) (EVar "None")))
(DTypeSig false "dropAsEdit" (TyFun (TyCon "ParamSite") (TyCon "FixEdit")))
(DFunDef false "dropAsEdit" ((PCon "ParamSite" PWild (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) PWild)) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EBinOp "+" (EVar "ec") (ELit (LInt 1))))) (ELit (LString ""))))
(DTypeSig false "atFollows" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "ParamSite") (TyCon "Bool"))))
(DFunDef false "atFollows" ((PVar "lines") (PCon "ParamSite" PWild (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EMatch (EApp (EApp (EVar "arrayGet") (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "lines")) (arm (PCon "Some" (PVar "text")) () (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "ec")) (EBinOp "+" (EVar "ec") (ELit (LInt 1)))) (EVar "text")) (ELit (LString "@")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collides" (TyFun (TyCon "FileScopes") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "collides" ((PVar "fs") (PTuple (PVar "lo") (PVar "hi")) (PVar "name")) (EBlock (DoLet false false (PVar "renamed") (EBinOp "++" (ELit (LString "_")) (EVar "name"))) (DoExpr (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isEmpty") (EApp (EApp (EApp (EApp (EVar "bindersNamedIn") (EVar "fs")) (EVar "lo")) (EVar "hi")) (EVar "renamed")))) (EApp (EVar "not") (EApp (EVar "isEmpty") (EApp (EApp (EApp (EApp (EVar "usesNamedIn") (EVar "fs")) (EVar "lo")) (EVar "hi")) (EVar "renamed"))))))))
(DTypeSig false "exactName" (TyFun (TyCon "String") (TyFun (TyCon "ParamSite") (TyCon "Bool"))))
(DFunDef false "exactName" ((PVar "name") (PCon "ParamSite" PWild (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) PWild)) (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "==" (EBinOp "-" (EVar "ec") (EVar "sc")) (EApp (EVar "strLength") (EVar "name")))))
(DTypeSig false "siteLoc" (TyFun (TyCon "ParamSite") (TyCon "Loc")))
(DFunDef false "siteLoc" ((PCon "ParamSite" PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "siteKind" (TyFun (TyCon "ParamSite") (TyCon "SiteKind")))
(DFunDef false "siteKind" ((PCon "ParamSite" PWild PWild (PVar "kind"))) (EVar "kind"))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "DeclPos" false) (mem "Positions" true) (mem "declPosEndLine" false) (mem "declPosLine" false) (mem "positionsDecls" false))))
(DUse false (UseGroup ("string") ((mem "length" false "strLength") (mem "sliceClamped" false))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factLines" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false) (mem "bindersNamedIn" false) (mem "unusedBinders" false) (mem "usesNamedIn" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedParam" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedParam")) (fa "summary" (ELit (LString "a function, method or `prop` parameter that nothing in its clause uses"))) (fa "doc" (ELit (LString "A parameter that no use in its clause resolves to is dead weight, and a reader cannot tell it from one that matters. Renaming it `_name` says it is intentionally unused, and a name starting with `_` is not reported. Function, impl-method, interface-default, `prop`, `where` and top-level `let rec` clause parameters are checked; the parameters of a `let rec` written inside a block, and lambda, `let`, match-arm and `do`-bind binders, are not. The fix renames every place the binder is written (each alternative of an or-pattern names it). An unused as-binder `x@p` is not renamed: the fix drops `x@` and keeps the pattern. The rename is only suggested, not applied, when `_name` is already used in the declaration, and for a record pun, where renaming the binder would rename the field: the suggestion then reads `field = _name`.\n\nBefore:\n  area w h = w * 2\nAfter:\n  area w _h = w * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedParam")) (EVar "None")))
(DTypeSig false "ruleUnusedParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedParam" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "unused") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BParam")))) (EApp (EVar "unusedBinders") (EVar "fs")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "unused")) (EListLit) (EBlock (DoLet false false (PVar "sites") (EApp (EApp (EDictApp "flatMap") (EVar "declParamSites")) (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "paramFinding") (EVar "facts")) (EVar "pos")) (EVar "sites"))) (EVar "unused"))))))))
(DData Private "SiteKind" () ((variant "SitePlain" (ConPos)) (variant "SitePun" (ConPos)) (variant "SiteAs" (ConPos))) ())
(DImpl true "Eq" ((TyCon "SiteKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SitePlain") (PCon "SitePlain")) () (EVar "True")) (arm (PTuple (PCon "SitePun") (PCon "SitePun")) () (EVar "True")) (arm (PTuple (PCon "SiteAs") (PCon "SiteAs")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Private "ParamSite" () ((variant "ParamSite" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "SiteKind")))) ())
(DTypeSig false "declParamSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "declParamSites" ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "bodyParamSites")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyParamSites" (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "bodyParamSites" ((PCon "DeclBody" (PVar "owner") (PVar "body"))) (EBinOp "++" (EApp (EVar "ownerParamSites") (EVar "owner")) (EApp (EVar "exprParamSites") (EVar "body"))))
(DTypeSig false "ownerParamSites" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "ownerParamSites" ((PCon "OwnerClause" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerImplMethod" PWild PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerIfaceDefault" PWild PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerLetGroup" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "ownerParamSites" ((PCon "OwnerProp" PWild (PVar "params"))) (EApp (EApp (EMethodRef "map") (EVar "propParamSite")) (EVar "params")))
(DFunDef false "ownerParamSites" ((PCon "OwnerTest" PWild)) (EListLit))
(DTypeSig false "propParamSite" (TyFun (TyCon "PropParam") (TyCon "ParamSite")))
(DFunDef false "propParamSite" ((PCon "PropParam" (PVar "n") (PVar "l") PWild)) (EApp (EApp (EApp (EVar "ParamSite") (EVar "n")) (EVar "l")) (EVar "SitePlain")))
(DTypeSig false "exprParamSites" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "exprParamSites" ((PVar "e")) (EBinOp "++" (EApp (EVar "groupParamSites") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "exprParamSites")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "groupParamSites" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "groupParamSites" ((PCon "ELetGroup" (PVar "binds") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "bindParamSites")) (EVar "binds")))
(DFunDef false "groupParamSites" (PWild) (EListLit))
(DTypeSig false "bindParamSites" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "bindParamSites" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "clauseParamSites")) (EVar "clauses")))
(DTypeSig false "clauseParamSites" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "clauseParamSites" ((PCon "FunClause" (PVar "ps") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DTypeSig false "patParamSites" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "patParamSites" ((PCon "PVar" (PVar "x") (PVar "l") PWild)) (EListLit (EApp (EApp (EApp (EVar "ParamSite") (EVar "x")) (EVar "l")) (EVar "SitePlain"))))
(DFunDef false "patParamSites" ((PCon "PWild")) (EListLit))
(DFunDef false "patParamSites" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patParamSites" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patParamSites") (EVar "a")) (EApp (EVar "patParamSites") (EVar "b"))))
(DFunDef false "patParamSites" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PAs" (PVar "x") (PVar "l") PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "ParamSite") (EVar "x")) (EVar "l")) (EVar "SiteAs")) (EApp (EVar "patParamSites") (EVar "p"))))
(DFunDef false "patParamSites" ((PCon "POr" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patParamSites")) (EVar "ps")))
(DFunDef false "patParamSites" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patParamSites" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "fieldParamSites")) (EVar "fields")))
(DTypeSig false "fieldParamSites" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ParamSite"))))
(DFunDef false "fieldParamSites" ((PCon "RecPatField" (PVar "n") (PVar "l") PWild (PCon "None"))) (EListLit (EApp (EApp (EApp (EVar "ParamSite") (EVar "n")) (EVar "l")) (EVar "SitePun"))))
(DFunDef false "fieldParamSites" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patParamSites") (EVar "p")))
(DTypeSig false "paramFinding" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyFun (TyCon "Binder") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "paramFinding" ((PVar "facts") (PVar "pos") (PVar "sites") (PVar "b")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "mine") (EApp (EApp (EMethodRef "filter") (EApp (EApp (EVar "binderIs") (EVar "fs")) (EVar "b"))) (EVar "sites"))) (DoExpr (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "parameter '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is never used. Rename it to '_"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' to mark it intentionally unused")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EFieldAccess (EVar "b") "binderSpan"))) (fa "fix" (EApp (EApp (EApp (EApp (EVar "paramFix") (EVar "facts")) (EApp (EApp (EVar "declLines") (EVar "pos")) (EVar "b"))) (EVar "b")) (EVar "mine")))))))))
(DTypeSig false "binderIs" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Binder") (TyFun (TyCon "ParamSite") (TyCon "Bool")))))
(DFunDef false "binderIs" ((PVar "fs") (PVar "b") (PCon "ParamSite" PWild (PVar "l") PWild)) (EMatch (EApp (EApp (EVar "binderOf") (EVar "fs")) (EVar "l")) (arm (PCon "Some" (PVar "c")) () (EBinOp "==" (EFieldAccess (EVar "c") "binderId") (EFieldAccess (EVar "b") "binderId"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "declLines" (TyFun (TyCon "Positions") (TyFun (TyCon "Binder") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "declLines" ((PVar "pos") (PVar "b")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "locLine") (EFieldAccess (EVar "b") "binderSpan"))) (DoExpr (EApp (EApp (EVar "optionOr") (ETuple (ELit (LInt 1)) (EVar "maxLine"))) (EApp (EApp (EDictApp "find") (ELam ((PVar "r")) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "fst") (EVar "r")) (EVar "line")) (EBinOp "<=" (EVar "line") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EMethodRef "map") (EVar "declPosRange")) (EApp (EVar "positionsDecls") (EVar "pos"))))))))
(DTypeSig false "maxLine" (TyCon "Int"))
(DFunDef false "maxLine" () (ELit (LInt 1073741824)))
(DTypeSig false "declPosRange" (TyFun (TyCon "DeclPos") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declPosRange" ((PVar "d")) (ETuple (EApp (EVar "declPosLine") (EVar "d")) (EApp (EVar "declPosEndLine") (EVar "d"))))
(DTypeSig false "locLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "locLine" ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "paramFix" (TyFun (TyCon "FileFacts") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Binder") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "paramFix" ((PVar "facts") (PVar "range") (PVar "b") (PVar "mine")) (EBlock (DoLet false false (PVar "name") (EFieldAccess (EVar "b") "binderName")) (DoLet false false (PVar "hasPun") (EApp (EApp (EDictApp "any") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteKind") (EVar "s")) (EVar "SitePun")))) (EVar "mine"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EDictApp "any") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteLoc") (EVar "s")) (EFieldAccess (EVar "b") "binderSpan")))) (EVar "mine"))) (EApp (EVar "not") (EApp (EApp (EDictApp "all") (EApp (EVar "exactName") (EVar "name"))) (EVar "mine")))) (EVar "None") (EIf (EApp (EApp (EDictApp "all") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "siteKind") (EVar "s")) (EVar "SiteAs")))) (EVar "mine")) (EApp (EApp (EVar "dropAsFix") (EApp (EVar "factLines") (EVar "facts"))) (EVar "mine")) (EIf (EBinOp "||" (EVar "hasPun") (EApp (EApp (EApp (EVar "collides") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "range")) (EVar "name"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "renameFix") (EVar "Suggest")) (EVar "name")) (EVar "mine"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "renameFix") (EVar "Safe")) (EVar "name")) (EVar "mine")))))))))
(DTypeSig false "renameFix" (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyCon "Fix")))))
(DFunDef false "renameFix" ((PVar "applicability") (PVar "name") (PVar "mine")) (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "applicability")) (fa "fixEdits" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EApp (EVar "FixEdit") (EApp (EVar "siteLoc") (EVar "s"))) (EApp (EApp (EVar "renamedText") (EVar "name")) (EVar "s"))))) (EVar "mine"))) (fa "fixMessage" (ELit (LString "rename the unused parameter"))))))
(DTypeSig false "renamedText" (TyFun (TyCon "String") (TyFun (TyCon "ParamSite") (TyCon "String"))))
(DFunDef false "renamedText" ((PVar "name") (PCon "ParamSite" PWild PWild (PVar "kind"))) (EIf (EBinOp "==" (EVar "kind") (EVar "SitePun")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = _"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "_")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "dropAsFix" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ParamSite")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "dropAsFix" ((PVar "lines") (PVar "mine")) (EIf (EApp (EApp (EDictApp "all") (EApp (EVar "atFollows") (EVar "lines"))) (EVar "mine")) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EApp (EApp (EMethodRef "map") (EVar "dropAsEdit")) (EVar "mine"))) (fa "fixMessage" (ELit (LString "drop the unused as-binder and keep its pattern")))))) (EVar "None")))
(DTypeSig false "dropAsEdit" (TyFun (TyCon "ParamSite") (TyCon "FixEdit")))
(DFunDef false "dropAsEdit" ((PCon "ParamSite" PWild (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) PWild)) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EBinOp "+" (EVar "ec") (ELit (LInt 1))))) (ELit (LString ""))))
(DTypeSig false "atFollows" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "ParamSite") (TyCon "Bool"))))
(DFunDef false "atFollows" ((PVar "lines") (PCon "ParamSite" PWild (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EMatch (EApp (EApp (EVar "arrayGet") (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "lines")) (arm (PCon "Some" (PVar "text")) () (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "ec")) (EBinOp "+" (EVar "ec") (ELit (LInt 1)))) (EVar "text")) (ELit (LString "@")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collides" (TyFun (TyCon "FileScopes") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "collides" ((PVar "fs") (PTuple (PVar "lo") (PVar "hi")) (PVar "name")) (EBlock (DoLet false false (PVar "renamed") (EBinOp "++" (ELit (LString "_")) (EVar "name"))) (DoExpr (EBinOp "||" (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EApp (EApp (EApp (EApp (EVar "bindersNamedIn") (EVar "fs")) (EVar "lo")) (EVar "hi")) (EVar "renamed")))) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EApp (EApp (EApp (EApp (EVar "usesNamedIn") (EVar "fs")) (EVar "lo")) (EVar "hi")) (EVar "renamed"))))))))
(DTypeSig false "exactName" (TyFun (TyCon "String") (TyFun (TyCon "ParamSite") (TyCon "Bool"))))
(DFunDef false "exactName" ((PVar "name") (PCon "ParamSite" PWild (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) PWild)) (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "==" (EBinOp "-" (EVar "ec") (EVar "sc")) (EApp (EVar "strLength") (EVar "name")))))
(DTypeSig false "siteLoc" (TyFun (TyCon "ParamSite") (TyCon "Loc")))
(DFunDef false "siteLoc" ((PCon "ParamSite" PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "siteKind" (TyFun (TyCon "ParamSite") (TyCon "SiteKind")))
(DFunDef false "siteKind" ((PCon "ParamSite" PWild PWild (PVar "kind"))) (EVar "kind"))
