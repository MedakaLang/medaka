# META
source_lines=214
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_fix.mdk — turns the fixes findings carry into validated
-- source edits and iterates to a fixed point.  It imports no rule module, no
-- registry and nothing from `types/`: the caller passes the linter in as a
-- function, so the driver sees only findings.

import list.{sortBy}
import frontend.ast.{Loc(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.lex_scan.{scanRawChars}
import frontend.lex_token.{RawTok(..)}
import frontend.syntax_source.{SourceSpan(..)}
import tools.lint_core.{Applicability(..), Finding(..), Fix(..), FixEdit(..)}
import tools.source_edits.{
  EditError, SourceEdit(..), applySourceEdits, validateSourceEdits
}
import tools.source_snapshot.{SourceSnapshot(..), makeSnapshot, snapshotId}
import support.source_index.{sourcePositionToOffset}

-- Why a fix run produced nothing.  The input that does not parse is the
-- caller's; an output that does not parse is a fixer's bug, and is never
-- returned.
public export data FixError =
  | SourceDoesNotParse String
  | FixedOutputDoesNotParse Int String
  | EditsRejected EditError

export
fixErrorText : FixError -> String
fixErrorText (SourceDoesNotParse msg) = msg
fixErrorText (FixedOutputDoesNotParse pass msg) =
  "the fixed source of pass \{intToString pass} does not parse: \{msg}"
fixErrorText (EditsRejected _) = "the chosen edits were rejected"

-- Most passes one run makes.  Each pass applies a non-overlapping subset of the
-- file's fixes, so a chain of nested rewrites settles one layer per pass; eight
-- layers is deeper than any rewrite in the tree nests, and the bound is what
-- keeps two fixes that undo each other from looping.
maxPasses : Int
maxPasses = 8

-- A fix whose locations are resolved to offsets: its edits against the pass's
-- snapshot, and the offsets spanning all of them.
data Resolved = Resolved {
  rsApplicability : Applicability,
  rsEdits : List SourceEdit,
  rsLo : Int,
  rsHi : Int,
}

rank : Applicability -> Int
rank Safe = 0
rank Unsafe = 1
rank Suggest = 2

-- `Suggest` is shown and never applied; `Unsafe` needs the limit to allow it.
applicable : Applicability -> Applicability -> Bool
applicable limit a = a /= Suggest && rank a <= rank limit

-- The fixes the findings carry, in finding order.
fixesOf : List Finding -> List Fix
fixesOf findings = flatMap findingFix findings

findingFix : Finding -> List Fix
findingFix f = toList f.fix

resolveEdits : SourceSnapshot -> List FixEdit -> Option (List SourceEdit)
resolveEdits _ [] = Some []
resolveEdits (snap@(SourceSnapshot _ _ _ text index)) ((FixEdit (Loc _ sl sc el ec) repl) :: rest) =
  match (sourcePositionToOffset index sl sc, sourcePositionToOffset index el ec)
    (Some lo, Some hi) =>
      let edit =
        SourceEdit
          (snapshotId snap)
          (SourceSpan lo hi)
          (stringSlice lo hi text)
          repl
      if lo <= hi then map (edit :: _) (resolveEdits snap rest) else None
    _ => None

editLo : SourceEdit -> Int
editLo (SourceEdit _ (SourceSpan lo _) _ _) = lo

editHi : SourceEdit -> Int
editHi (SourceEdit _ (SourceSpan _ hi) _ _) = hi

-- `None` for a fix with an unplaceable edit or overlapping edits of its own.
resolveFix : SourceSnapshot -> Fix -> Option Resolved
resolveFix snap fx = match resolveEdits snap fx.fixEdits
  Some (edits@(_ :: _)) => match validateSourceEdits snap edits
    Ok _ => Some Resolved {
      rsApplicability = fx.fixApplicability,
      rsEdits = edits,
      rsLo = fold min 1000000000 (map editLo edits),
      rsHi = fold max 0 (map editHi edits),
    }
    Err _ => None
  _ => None

-- The `(start, end)` offsets of every comment in `src`.
commentSpans : String -> List (Int, Int)
commentSpans src = flatMap commentSpan (scanRawChars (stringToChars src))

commentSpan : RawTok -> List (Int, Int)
commentSpan (RComment s e) = [(s, e)]
commentSpan _ = []

-- A comment overlapping an edit's span would be deleted by the replacement.
-- One that ends where the span starts, or starts where it ends, is untouched.
editTouchesComment : List (Int, Int) -> SourceEdit -> Bool
editTouchesComment comments e =
  any (c => fst c < editHi e && editLo e < snd c) comments

-- A fix that would drop a comment is only suggested.
demote : List (Int, Int) -> Resolved -> Resolved
demote comments r =
  if any (editTouchesComment comments) r.rsEdits then
    Resolved {
      rsApplicability = Suggest,
      rsEdits = r.rsEdits,
      rsLo = r.rsLo,
      rsHi = r.rsHi,
    }
  else
    r

compareResolved : Resolved -> Resolved -> Ordering
compareResolved a b =
  if a.rsLo == b.rsLo then compare a.rsHi b.rsHi else compare a.rsLo b.rsLo

-- Greedy by start offset: a fix is taken when it begins at or after the end of
-- the last one taken (never at a point already holding an insertion), and
-- the rest wait for the next pass.
pick : Int -> List Resolved -> List Resolved
pick _ [] = []
pick edge (r :: rest)
  | r.rsLo > edge || r.rsLo == edge && r.rsHi > edge = r :: pick r.rsHi rest
  | otherwise = pick edge rest

chooseFixes : Applicability -> SourceSnapshot -> List Fix -> List Resolved
chooseFixes limit (snap@(SourceSnapshot _ _ _ text _)) fixes =
  let resolved = flatMap (f => toList (resolveFix snap f)) fixes
  if isEmpty resolved then
    []
  else
    let comments = commentSpans text
    let ready =
      filter
        (r => applicable limit r.rsApplicability)
        (map (demote comments) resolved)
    pick (0 - 1) (sortBy compareResolved ready)

-- Fix `src` (read from `path`, which names the snapshot) until no fix at the
-- `limit` remains.  `lint` is the caller's linter: it returns the findings of a
-- source, or the reason it does not parse.  Returns the fixed source and the
-- number of fixes applied.  Every pass re-parses its input, so an output that
-- does not parse is reported and never returned.
export
applyFixes : (String -> String -> Result String (List Finding)) ->
  Applicability ->
  String ->
  String ->
  Result FixError (String, Int)
applyFixes lint limit path src = fixPass lint limit path 0 0 src

fixPass : (String -> String -> Result String (List Finding)) ->
  Applicability ->
  String ->
  Int ->
  Int ->
  String ->
  Result FixError (String, Int)
fixPass lint limit path n total src = match lint path src
  Err msg =>
    if n == 0 then
      Err (SourceDoesNotParse msg)
    else
      Err (FixedOutputDoesNotParse n msg)
  Ok findings =>
    let snap = makeSnapshot path None n src
    let chosen =
      if n >= maxPasses then [] else chooseFixes limit snap (fixesOf findings)
    if isEmpty chosen then
      Ok (src, total)
    else match applySourceEdits snap (flatMap (r => r.rsEdits) chosen)
      Err e => Err (EditsRejected e)
      Ok out => fixPass lint limit path (n + 1) (total + length chosen) out

-- How tightly a replacement's text binds.  `Closed` text (a literal, a name,
-- a call, anything already bracketed) reads the same in any position; `Open`
-- text (an operator expression, a lambda, `if`, `match`) may need brackets.
public export data Binding = Closed | Open

-- `text` placed where its `Ctx` says an expression of kind `parent` sits:
-- bracketed when it is `Open` and the parent would regroup it.  A body's root
-- (`None`) and the parents that separate their children by punctuation take it
-- bare.
export
parenIfNeeded : Binding -> Option ExprKind -> String -> String
parenIfNeeded Closed _ text = text
parenIfNeeded Open None text = text
parenIfNeeded Open (Some parent) text =
  if separatesChildren parent then text else "(" ++ text ++ ")"

separatesChildren : ExprKind -> Bool
separatesChildren KTuple = True
separatesChildren KListLit = True
separatesChildren KArrayLit = True
separatesChildren KStringInterp = True
separatesChildren KBlock = True
separatesChildren KDo = True
separatesChildren KRecordCreate = True
separatesChildren KMapLit = True
separatesChildren KSetLit = True
separatesChildren _ = False
# DESUGAR
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true))))
(DUse false (UseGroup ("tools" "source_edits") ((mem "EditError" false) (mem "SourceEdit" true) (mem "applySourceEdits" false) (mem "validateSourceEdits" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "makeSnapshot" false) (mem "snapshotId" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "sourcePositionToOffset" false))))
(DData Public "FixError" () ((variant "SourceDoesNotParse" (ConPos (TyCon "String"))) (variant "FixedOutputDoesNotParse" (ConPos (TyCon "Int") (TyCon "String"))) (variant "EditsRejected" (ConPos (TyCon "EditError")))) ())
(DTypeSig true "fixErrorText" (TyFun (TyCon "FixError") (TyCon "String")))
(DFunDef false "fixErrorText" ((PCon "SourceDoesNotParse" (PVar "msg"))) (EVar "msg"))
(DFunDef false "fixErrorText" ((PCon "FixedOutputDoesNotParse" (PVar "pass") (PVar "msg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the fixed source of pass ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "pass")))) (ELit (LString " does not parse: "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "fixErrorText" ((PCon "EditsRejected" PWild)) (ELit (LString "the chosen edits were rejected")))
(DTypeSig false "maxPasses" (TyCon "Int"))
(DFunDef false "maxPasses" () (ELit (LInt 8)))
(DData Private "Resolved" () ((variant "Resolved" (ConNamed (field "rsApplicability" (TyCon "Applicability")) (field "rsEdits" (TyApp (TyCon "List") (TyCon "SourceEdit"))) (field "rsLo" (TyCon "Int")) (field "rsHi" (TyCon "Int"))))) ())
(DTypeSig false "rank" (TyFun (TyCon "Applicability") (TyCon "Int")))
(DFunDef false "rank" ((PCon "Safe")) (ELit (LInt 0)))
(DFunDef false "rank" ((PCon "Unsafe")) (ELit (LInt 1)))
(DFunDef false "rank" ((PCon "Suggest")) (ELit (LInt 2)))
(DTypeSig false "applicable" (TyFun (TyCon "Applicability") (TyFun (TyCon "Applicability") (TyCon "Bool"))))
(DFunDef false "applicable" ((PVar "limit") (PVar "a")) (EBinOp "&&" (EBinOp "/=" (EVar "a") (EVar "Suggest")) (EBinOp "<=" (EApp (EVar "rank") (EVar "a")) (EApp (EVar "rank") (EVar "limit")))))
(DTypeSig false "fixesOf" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Fix"))))
(DFunDef false "fixesOf" ((PVar "findings")) (EApp (EApp (EVar "flatMap") (EVar "findingFix")) (EVar "findings")))
(DTypeSig false "findingFix" (TyFun (TyCon "Finding") (TyApp (TyCon "List") (TyCon "Fix"))))
(DFunDef false "findingFix" ((PVar "f")) (EApp (EVar "toList") (EFieldAccess (EVar "f") "fix")))
(DTypeSig false "resolveEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "FixEdit")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "SourceEdit"))))))
(DFunDef false "resolveEdits" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "resolveEdits" ((PAs "snap" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") (PVar "index"))) (PCons (PCon "FixEdit" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "repl")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "sl")) (EVar "sc")) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec"))) (arm (PTuple (PCon "Some" (PVar "lo")) (PCon "Some" (PVar "hi"))) () (EBlock (DoLet false false (PVar "edit") (EApp (EApp (EApp (EApp (EVar "SourceEdit") (EApp (EVar "snapshotId") (EVar "snap"))) (EApp (EApp (EVar "SourceSpan") (EVar "lo")) (EVar "hi"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "text"))) (EVar "repl"))) (DoExpr (EIf (EBinOp "<=" (EVar "lo") (EVar "hi")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "edit") (EVar "_s")))) (EApp (EApp (EVar "resolveEdits") (EVar "snap")) (EVar "rest"))) (EVar "None"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "editLo" (TyFun (TyCon "SourceEdit") (TyCon "Int")))
(DFunDef false "editLo" ((PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "lo") PWild) PWild PWild)) (EVar "lo"))
(DTypeSig false "editHi" (TyFun (TyCon "SourceEdit") (TyCon "Int")))
(DFunDef false "editHi" ((PCon "SourceEdit" PWild (PCon "SourceSpan" PWild (PVar "hi")) PWild PWild)) (EVar "hi"))
(DTypeSig false "resolveFix" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "Fix") (TyApp (TyCon "Option") (TyCon "Resolved")))))
(DFunDef false "resolveFix" ((PVar "snap") (PVar "fx")) (EMatch (EApp (EApp (EVar "resolveEdits") (EVar "snap")) (EFieldAccess (EVar "fx") "fixEdits")) (arm (PCon "Some" (PAs "edits" (PCons PWild PWild))) () (EMatch (EApp (EApp (EVar "validateSourceEdits") (EVar "snap")) (EVar "edits")) (arm (PCon "Ok" PWild) () (EApp (EVar "Some") (ERecordCreate "Resolved" ((fa "rsApplicability" (EFieldAccess (EVar "fx") "fixApplicability")) (fa "rsEdits" (EVar "edits")) (fa "rsLo" (EApp (EApp (EApp (EVar "fold") (EVar "min")) (ELit (LInt 1000000000))) (EApp (EApp (EVar "map") (EVar "editLo")) (EVar "edits")))) (fa "rsHi" (EApp (EApp (EApp (EVar "fold") (EVar "max")) (ELit (LInt 0))) (EApp (EApp (EVar "map") (EVar "editHi")) (EVar "edits")))))))) (arm (PCon "Err" PWild) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "commentSpans" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commentSpans" ((PVar "src")) (EApp (EApp (EVar "flatMap") (EVar "commentSpan")) (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "src")))))
(DTypeSig false "commentSpan" (TyFun (TyCon "RawTok") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commentSpan" ((PCon "RComment" (PVar "s") (PVar "e"))) (EListLit (ETuple (EVar "s") (EVar "e"))))
(DFunDef false "commentSpan" (PWild) (EListLit))
(DTypeSig false "editTouchesComment" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SourceEdit") (TyCon "Bool"))))
(DFunDef false "editTouchesComment" ((PVar "comments") (PVar "e")) (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp "<" (EApp (EVar "fst") (EVar "c")) (EApp (EVar "editHi") (EVar "e"))) (EBinOp "<" (EApp (EVar "editLo") (EVar "e")) (EApp (EVar "snd") (EVar "c")))))) (EVar "comments")))
(DTypeSig false "demote" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Resolved") (TyCon "Resolved"))))
(DFunDef false "demote" ((PVar "comments") (PVar "r")) (EIf (EApp (EApp (EVar "any") (EApp (EVar "editTouchesComment") (EVar "comments"))) (EFieldAccess (EVar "r") "rsEdits")) (ERecordCreate "Resolved" ((fa "rsApplicability" (EVar "Suggest")) (fa "rsEdits" (EFieldAccess (EVar "r") "rsEdits")) (fa "rsLo" (EFieldAccess (EVar "r") "rsLo")) (fa "rsHi" (EFieldAccess (EVar "r") "rsHi")))) (EVar "r")))
(DTypeSig false "compareResolved" (TyFun (TyCon "Resolved") (TyFun (TyCon "Resolved") (TyCon "Ordering"))))
(DFunDef false "compareResolved" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EFieldAccess (EVar "a") "rsLo") (EFieldAccess (EVar "b") "rsLo")) (EApp (EApp (EVar "compare") (EFieldAccess (EVar "a") "rsHi")) (EFieldAccess (EVar "b") "rsHi")) (EApp (EApp (EVar "compare") (EFieldAccess (EVar "a") "rsLo")) (EFieldAccess (EVar "b") "rsLo"))))
(DTypeSig false "pick" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Resolved")) (TyApp (TyCon "List") (TyCon "Resolved")))))
(DFunDef false "pick" (PWild (PList)) (EListLit))
(DFunDef false "pick" ((PVar "edge") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "||" (EBinOp ">" (EFieldAccess (EVar "r") "rsLo") (EVar "edge")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "rsLo") (EVar "edge")) (EBinOp ">" (EFieldAccess (EVar "r") "rsHi") (EVar "edge")))) (EBinOp "::" (EVar "r") (EApp (EApp (EVar "pick") (EFieldAccess (EVar "r") "rsHi")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "pick") (EVar "edge")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chooseFixes" (TyFun (TyCon "Applicability") (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "Fix")) (TyApp (TyCon "List") (TyCon "Resolved"))))))
(DFunDef false "chooseFixes" ((PVar "limit") (PAs "snap" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "fixes")) (EBlock (DoLet false false (PVar "resolved") (EApp (EApp (EVar "flatMap") (ELam ((PVar "f")) (EApp (EVar "toList") (EApp (EApp (EVar "resolveFix") (EVar "snap")) (EVar "f"))))) (EVar "fixes"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "resolved")) (EListLit) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "commentSpans") (EVar "text"))) (DoLet false false (PVar "ready") (EApp (EApp (EVar "filter") (ELam ((PVar "r")) (EApp (EApp (EVar "applicable") (EVar "limit")) (EFieldAccess (EVar "r") "rsApplicability")))) (EApp (EApp (EVar "map") (EApp (EVar "demote") (EVar "comments"))) (EVar "resolved")))) (DoExpr (EApp (EApp (EVar "pick") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "sortBy") (EVar "compareResolved")) (EVar "ready")))))))))
(DTypeSig true "applyFixes" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))) (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FixError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "lint") (PVar "limit") (PVar "path") (PVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixPass") (EVar "lint")) (EVar "limit")) (EVar "path")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "src")))
(DTypeSig false "fixPass" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))) (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FixError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "fixPass" ((PVar "lint") (PVar "limit") (PVar "path") (PVar "n") (PVar "total") (PVar "src")) (EMatch (EApp (EApp (EVar "lint") (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "msg")) () (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EVar "SourceDoesNotParse") (EVar "msg"))) (EApp (EVar "Err") (EApp (EApp (EVar "FixedOutputDoesNotParse") (EVar "n")) (EVar "msg"))))) (arm (PCon "Ok" (PVar "findings")) () (EBlock (DoLet false false (PVar "snap") (EApp (EApp (EApp (EApp (EVar "makeSnapshot") (EVar "path")) (EVar "None")) (EVar "n")) (EVar "src"))) (DoLet false false (PVar "chosen") (EIf (EBinOp ">=" (EVar "n") (EVar "maxPasses")) (EListLit) (EApp (EApp (EApp (EVar "chooseFixes") (EVar "limit")) (EVar "snap")) (EApp (EVar "fixesOf") (EVar "findings"))))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "chosen")) (EApp (EVar "Ok") (ETuple (EVar "src") (EVar "total"))) (EMatch (EApp (EApp (EVar "applySourceEdits") (EVar "snap")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "r")) (EFieldAccess (EVar "r") "rsEdits"))) (EVar "chosen"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "EditsRejected") (EVar "e")))) (arm (PCon "Ok" (PVar "out")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixPass") (EVar "lint")) (EVar "limit")) (EVar "path")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "total") (EApp (EVar "length") (EVar "chosen")))) (EVar "out"))))))))))
(DData Public "Binding" () ((variant "Closed" (ConPos)) (variant "Open" (ConPos))) ())
(DTypeSig true "parenIfNeeded" (TyFun (TyCon "Binding") (TyFun (TyApp (TyCon "Option") (TyCon "ExprKind")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "parenIfNeeded" ((PCon "Closed") PWild (PVar "text")) (EVar "text"))
(DFunDef false "parenIfNeeded" ((PCon "Open") (PCon "None") (PVar "text")) (EVar "text"))
(DFunDef false "parenIfNeeded" ((PCon "Open") (PCon "Some" (PVar "parent")) (PVar "text")) (EIf (EApp (EVar "separatesChildren") (EVar "parent")) (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")")))))
(DTypeSig false "separatesChildren" (TyFun (TyCon "ExprKind") (TyCon "Bool")))
(DFunDef false "separatesChildren" ((PCon "KTuple")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KListLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KArrayLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KStringInterp")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KBlock")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KDo")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KRecordCreate")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KMapLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KSetLit")) (EVar "True"))
(DFunDef false "separatesChildren" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true))))
(DUse false (UseGroup ("tools" "source_edits") ((mem "EditError" false) (mem "SourceEdit" true) (mem "applySourceEdits" false) (mem "validateSourceEdits" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "makeSnapshot" false) (mem "snapshotId" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "sourcePositionToOffset" false))))
(DData Public "FixError" () ((variant "SourceDoesNotParse" (ConPos (TyCon "String"))) (variant "FixedOutputDoesNotParse" (ConPos (TyCon "Int") (TyCon "String"))) (variant "EditsRejected" (ConPos (TyCon "EditError")))) ())
(DTypeSig true "fixErrorText" (TyFun (TyCon "FixError") (TyCon "String")))
(DFunDef false "fixErrorText" ((PCon "SourceDoesNotParse" (PVar "msg"))) (EVar "msg"))
(DFunDef false "fixErrorText" ((PCon "FixedOutputDoesNotParse" (PVar "pass") (PVar "msg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the fixed source of pass ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "pass")))) (ELit (LString " does not parse: "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "fixErrorText" ((PCon "EditsRejected" PWild)) (ELit (LString "the chosen edits were rejected")))
(DTypeSig false "maxPasses" (TyCon "Int"))
(DFunDef false "maxPasses" () (ELit (LInt 8)))
(DData Private "Resolved" () ((variant "Resolved" (ConNamed (field "rsApplicability" (TyCon "Applicability")) (field "rsEdits" (TyApp (TyCon "List") (TyCon "SourceEdit"))) (field "rsLo" (TyCon "Int")) (field "rsHi" (TyCon "Int"))))) ())
(DTypeSig false "rank" (TyFun (TyCon "Applicability") (TyCon "Int")))
(DFunDef false "rank" ((PCon "Safe")) (ELit (LInt 0)))
(DFunDef false "rank" ((PCon "Unsafe")) (ELit (LInt 1)))
(DFunDef false "rank" ((PCon "Suggest")) (ELit (LInt 2)))
(DTypeSig false "applicable" (TyFun (TyCon "Applicability") (TyFun (TyCon "Applicability") (TyCon "Bool"))))
(DFunDef false "applicable" ((PVar "limit") (PVar "a")) (EBinOp "&&" (EBinOp "/=" (EVar "a") (EVar "Suggest")) (EBinOp "<=" (EApp (EVar "rank") (EVar "a")) (EApp (EVar "rank") (EVar "limit")))))
(DTypeSig false "fixesOf" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Fix"))))
(DFunDef false "fixesOf" ((PVar "findings")) (EApp (EApp (EDictApp "flatMap") (EVar "findingFix")) (EVar "findings")))
(DTypeSig false "findingFix" (TyFun (TyCon "Finding") (TyApp (TyCon "List") (TyCon "Fix"))))
(DFunDef false "findingFix" ((PVar "f")) (EApp (EMethodRef "toList") (EFieldAccess (EVar "f") "fix")))
(DTypeSig false "resolveEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "FixEdit")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "SourceEdit"))))))
(DFunDef false "resolveEdits" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "resolveEdits" ((PAs "snap" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") (PVar "index"))) (PCons (PCon "FixEdit" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "repl")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "sl")) (EVar "sc")) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec"))) (arm (PTuple (PCon "Some" (PVar "lo")) (PCon "Some" (PVar "hi"))) () (EBlock (DoLet false false (PVar "edit") (EApp (EApp (EApp (EApp (EVar "SourceEdit") (EApp (EVar "snapshotId") (EVar "snap"))) (EApp (EApp (EVar "SourceSpan") (EVar "lo")) (EVar "hi"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "text"))) (EVar "repl"))) (DoExpr (EIf (EBinOp "<=" (EVar "lo") (EVar "hi")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "edit") (EVar "_s")))) (EApp (EApp (EVar "resolveEdits") (EVar "snap")) (EVar "rest"))) (EVar "None"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "editLo" (TyFun (TyCon "SourceEdit") (TyCon "Int")))
(DFunDef false "editLo" ((PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "lo") PWild) PWild PWild)) (EVar "lo"))
(DTypeSig false "editHi" (TyFun (TyCon "SourceEdit") (TyCon "Int")))
(DFunDef false "editHi" ((PCon "SourceEdit" PWild (PCon "SourceSpan" PWild (PVar "hi")) PWild PWild)) (EVar "hi"))
(DTypeSig false "resolveFix" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "Fix") (TyApp (TyCon "Option") (TyCon "Resolved")))))
(DFunDef false "resolveFix" ((PVar "snap") (PVar "fx")) (EMatch (EApp (EApp (EVar "resolveEdits") (EVar "snap")) (EFieldAccess (EVar "fx") "fixEdits")) (arm (PCon "Some" (PAs "edits" (PCons PWild PWild))) () (EMatch (EApp (EApp (EVar "validateSourceEdits") (EVar "snap")) (EVar "edits")) (arm (PCon "Ok" PWild) () (EApp (EVar "Some") (ERecordCreate "Resolved" ((fa "rsApplicability" (EFieldAccess (EVar "fx") "fixApplicability")) (fa "rsEdits" (EVar "edits")) (fa "rsLo" (EApp (EApp (EApp (EMethodRef "fold") (EMethodRef "min")) (ELit (LInt 1000000000))) (EApp (EApp (EMethodRef "map") (EVar "editLo")) (EVar "edits")))) (fa "rsHi" (EApp (EApp (EApp (EMethodRef "fold") (EMethodRef "max")) (ELit (LInt 0))) (EApp (EApp (EMethodRef "map") (EVar "editHi")) (EVar "edits")))))))) (arm (PCon "Err" PWild) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "commentSpans" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commentSpans" ((PVar "src")) (EApp (EApp (EDictApp "flatMap") (EVar "commentSpan")) (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "src")))))
(DTypeSig false "commentSpan" (TyFun (TyCon "RawTok") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commentSpan" ((PCon "RComment" (PVar "s") (PVar "e"))) (EListLit (ETuple (EVar "s") (EVar "e"))))
(DFunDef false "commentSpan" (PWild) (EListLit))
(DTypeSig false "editTouchesComment" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SourceEdit") (TyCon "Bool"))))
(DFunDef false "editTouchesComment" ((PVar "comments") (PVar "e")) (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp "<" (EApp (EVar "fst") (EVar "c")) (EApp (EVar "editHi") (EVar "e"))) (EBinOp "<" (EApp (EVar "editLo") (EVar "e")) (EApp (EVar "snd") (EVar "c")))))) (EVar "comments")))
(DTypeSig false "demote" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Resolved") (TyCon "Resolved"))))
(DFunDef false "demote" ((PVar "comments") (PVar "r")) (EIf (EApp (EApp (EDictApp "any") (EApp (EVar "editTouchesComment") (EVar "comments"))) (EFieldAccess (EVar "r") "rsEdits")) (ERecordCreate "Resolved" ((fa "rsApplicability" (EVar "Suggest")) (fa "rsEdits" (EFieldAccess (EVar "r") "rsEdits")) (fa "rsLo" (EFieldAccess (EVar "r") "rsLo")) (fa "rsHi" (EFieldAccess (EVar "r") "rsHi")))) (EVar "r")))
(DTypeSig false "compareResolved" (TyFun (TyCon "Resolved") (TyFun (TyCon "Resolved") (TyCon "Ordering"))))
(DFunDef false "compareResolved" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EFieldAccess (EVar "a") "rsLo") (EFieldAccess (EVar "b") "rsLo")) (EApp (EApp (EMethodRef "compare") (EFieldAccess (EVar "a") "rsHi")) (EFieldAccess (EVar "b") "rsHi")) (EApp (EApp (EMethodRef "compare") (EFieldAccess (EVar "a") "rsLo")) (EFieldAccess (EVar "b") "rsLo"))))
(DTypeSig false "pick" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Resolved")) (TyApp (TyCon "List") (TyCon "Resolved")))))
(DFunDef false "pick" (PWild (PList)) (EListLit))
(DFunDef false "pick" ((PVar "edge") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "||" (EBinOp ">" (EFieldAccess (EVar "r") "rsLo") (EVar "edge")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "rsLo") (EVar "edge")) (EBinOp ">" (EFieldAccess (EVar "r") "rsHi") (EVar "edge")))) (EBinOp "::" (EVar "r") (EApp (EApp (EVar "pick") (EFieldAccess (EVar "r") "rsHi")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "pick") (EVar "edge")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chooseFixes" (TyFun (TyCon "Applicability") (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "Fix")) (TyApp (TyCon "List") (TyCon "Resolved"))))))
(DFunDef false "chooseFixes" ((PVar "limit") (PAs "snap" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "fixes")) (EBlock (DoLet false false (PVar "resolved") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "f")) (EApp (EMethodRef "toList") (EApp (EApp (EVar "resolveFix") (EVar "snap")) (EVar "f"))))) (EVar "fixes"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "resolved")) (EListLit) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "commentSpans") (EVar "text"))) (DoLet false false (PVar "ready") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "r")) (EApp (EApp (EVar "applicable") (EVar "limit")) (EFieldAccess (EVar "r") "rsApplicability")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "demote") (EVar "comments"))) (EVar "resolved")))) (DoExpr (EApp (EApp (EVar "pick") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "sortBy") (EVar "compareResolved")) (EVar "ready")))))))))
(DTypeSig true "applyFixes" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))) (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FixError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "lint") (PVar "limit") (PVar "path") (PVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixPass") (EVar "lint")) (EVar "limit")) (EVar "path")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "src")))
(DTypeSig false "fixPass" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))) (TyFun (TyCon "Applicability") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FixError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "fixPass" ((PVar "lint") (PVar "limit") (PVar "path") (PVar "n") (PVar "total") (PVar "src")) (EMatch (EApp (EApp (EVar "lint") (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "msg")) () (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EVar "SourceDoesNotParse") (EVar "msg"))) (EApp (EVar "Err") (EApp (EApp (EVar "FixedOutputDoesNotParse") (EVar "n")) (EVar "msg"))))) (arm (PCon "Ok" (PVar "findings")) () (EBlock (DoLet false false (PVar "snap") (EApp (EApp (EApp (EApp (EVar "makeSnapshot") (EVar "path")) (EVar "None")) (EVar "n")) (EVar "src"))) (DoLet false false (PVar "chosen") (EIf (EBinOp ">=" (EVar "n") (EVar "maxPasses")) (EListLit) (EApp (EApp (EApp (EVar "chooseFixes") (EVar "limit")) (EVar "snap")) (EApp (EVar "fixesOf") (EVar "findings"))))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "chosen")) (EApp (EVar "Ok") (ETuple (EVar "src") (EVar "total"))) (EMatch (EApp (EApp (EVar "applySourceEdits") (EVar "snap")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "r")) (EFieldAccess (EVar "r") "rsEdits"))) (EVar "chosen"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "EditsRejected") (EVar "e")))) (arm (PCon "Ok" (PVar "out")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixPass") (EVar "lint")) (EVar "limit")) (EVar "path")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "total") (EApp (EMethodRef "length") (EVar "chosen")))) (EVar "out"))))))))))
(DData Public "Binding" () ((variant "Closed" (ConPos)) (variant "Open" (ConPos))) ())
(DTypeSig true "parenIfNeeded" (TyFun (TyCon "Binding") (TyFun (TyApp (TyCon "Option") (TyCon "ExprKind")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "parenIfNeeded" ((PCon "Closed") PWild (PVar "text")) (EVar "text"))
(DFunDef false "parenIfNeeded" ((PCon "Open") (PCon "None") (PVar "text")) (EVar "text"))
(DFunDef false "parenIfNeeded" ((PCon "Open") (PCon "Some" (PVar "parent")) (PVar "text")) (EIf (EApp (EVar "separatesChildren") (EVar "parent")) (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")")))))
(DTypeSig false "separatesChildren" (TyFun (TyCon "ExprKind") (TyCon "Bool")))
(DFunDef false "separatesChildren" ((PCon "KTuple")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KListLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KArrayLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KStringInterp")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KBlock")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KDo")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KRecordCreate")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KMapLit")) (EVar "True"))
(DFunDef false "separatesChildren" ((PCon "KSetLit")) (EVar "True"))
(DFunDef false "separatesChildren" (PWild) (EVar "False"))
