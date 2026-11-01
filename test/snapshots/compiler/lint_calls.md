# META
source_lines=208
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_calls.mdk — the shared reader of a discarded call: given a
-- `let _ = e` statement of a block, the declared result type of the call `e`
-- makes, or the reason the linter cannot vouch for one.
--
-- The head of `e` must be a saturated application of a name.  The name resolves
-- through the file's scope model first (a local binder or parameter shadows a
-- top-level name), then through the declaration index, signed rows only: the
-- verdict reads the DECLARED result, never an inferred one, so an unsigned
-- callee, a method, a constructor, a partial application and a head that is not
-- a plain name all abstain.  No `types.*` import: the index holds signatures as
-- written.

import frontend.ast.{DoStmt(..), Expr(..), Loc, Pat(..), Ty(..)}
import frontend.ast_walk.{ExprKind(..)}
import list.{last}
import string.{split}
import support.util.{joinWith}
import tools.printer.{ppTy}
import tools.lint_core.{Ctx(..)}
import tools.lint_index.{
  IndexRow(..),
  Ns(..),
  ProjectIndex,
  RowKind(..),
  rowHasSig,
  rowSig,
  rowsIn,
  rowsNamed,
}
import tools.lint_scope.{Binder(..), BinderKind(..), FileScopes, binderOf}
import tools.lint_shared.{unwrapLoc}

-- Whether a block is a bare statement block or a `do` block.
public export data BlockKind = PlainBlock | DoBlock deriving (Eq, Debug)

-- Why no verdict.  `NotADiscard` is a statement that is not `let _ = e`;
-- `NotACall` an `e` with no argument; `HeadNotAName` an `e` whose head is a
-- lambda, section, operator, record field or other non-name; `NoSite` a head
-- name the scope model has no position for; `LocalBinder` a head bound by
-- something other than a top-level function or an import; `NoRows` a name the
-- index does not declare; `NotAPlainFunction` a head that is a method or a
-- constructor; `NoSignature` a candidate declared without a signature;
-- `Ambiguous` candidates whose declared results differ; `PartialApplication`
-- fewer arguments than the signature takes; `OverApplied` more.
public export data AbstainReason =
  | NotADiscard
  | NotACall
  | HeadNotAName
  | NoSite
  | LocalBinder
  | NoRows
  | NotAPlainFunction
  | NoSignature
  | Ambiguous
  | PartialApplication
  | OverApplied
  deriving (Eq, Debug)

-- `Discard t`: the call is saturated and its declared result is `t`.
public export data Verdict = Discard Ty | Abstain AbstainReason

-- `Ty` has no `Eq`, so `deriving` is unavailable: two results are equal when
-- they print the same.
-- lint-disable-next-line rule-hand-rolled-derivable
impl Eq Verdict where
  eq (Discard a) (Discard b) = ppTy a == ppTy b
  eq (Abstain a) (Abstain b) = a == b
  eq _ _ = False

-- `Ty` has no `Debug` either; the rendering is the printed type.
-- lint-disable-next-line rule-hand-rolled-derivable
impl Debug Verdict where
  debug (Discard t) = "Discard (\{ppTy t})"
  debug (Abstain r) = "Abstain \{debug r}"

-- The head type constructor of a declared result, for the drains that sort
-- discards: `Unit`, `Result _ _`, `Option _`, anything else.
public export data DiscardClass =
  | ClassUnit
  | ClassResult
  | ClassOption
  | ClassOther
  deriving (Eq, Debug)

export
discardClass : Ty -> DiscardClass
discardClass t = match headName t
  "Unit" => ClassUnit
  "Result" => ClassResult
  "Option" => ClassOption
  _ => ClassOther

headName : Ty -> String
headName (TyCon { tyConName = n }) = lastSegment n
headName (TyApp f _) = headName f
headName (TyTuple []) = "Unit"
headName _ = ""

lastSegment : String -> String
lastSegment n = optionOr n (last (split "." n))

-- The kind of block a node is, with its statements; `None` for any other node.
export
blockOf : Expr -> Option (BlockKind, List DoStmt)
blockOf e = match unwrapLoc e
  EBlock stmts => Some (PlainBlock, stmts)
  EDo _ stmts => Some (DoBlock, stmts)
  _ => None

-- Whether the node a visitor stands on is a direct child of a bare block.  The
-- walk records the nearest enclosing expression kind once per node
-- (`ctxParent`), so this is a field read.
export
inPlainBlock : Ctx -> Bool
inPlainBlock ctx = ctx.ctxParent == Some KBlock

-- The verdict for one statement of a block.  `modId` is the module id of the
-- file the block is in, so a top-level head reads that file's own rows and not
-- those of another file that declares the same name.
export
discardVerdict : ProjectIndex -> FileScopes -> String -> DoStmt -> Verdict
discardVerdict ix scopes modId (DoLet _ _ PWild rhs _) =
  callVerdict ix scopes modId rhs
discardVerdict _ _ _ _ = Abstain NotADiscard

callVerdict : ProjectIndex -> FileScopes -> String -> Expr -> Verdict
callVerdict ix scopes modId e = match spine e 0
  (hd, 0) => Abstain NotACall
  (hd, n) => match unwrapLoc hd
    EVar name => nameVerdict ix scopes modId name (siteOf hd) n
    _ => Abstain HeadNotAName

-- The head of an application chain and its argument count.
spine : Expr -> Int -> (Expr, Int)
spine e n = match unwrapLoc e
  EApp f _ => spine f (n + 1)
  _ => (e, n)

-- The span of the identifier a head stands on: the innermost `ELoc` over it.
siteOf : Expr -> Option Loc
siteOf (ELoc l inner) = match siteOf inner
  Some inner2 => Some inner2
  None => match inner
    EVar _ => Some l
    _ => None
siteOf _ = None

nameVerdict : ProjectIndex ->
  FileScopes ->
  String ->
  String ->
  Option Loc ->
  Int ->
  Verdict
nameVerdict _ _ _ _ None _ = Abstain NoSite
nameVerdict ix scopes modId name (Some l) n = match binderOf scopes l
  None => rowsVerdict n (rowsNamed ix NsValue name)
  Some b => match b.binderKind
    BTopLevel => rowsVerdict n (rowsIn ix modId NsValue name)
    BImport =>
      rowsVerdict
        n
        (rowsIn ix (joinWith "." b.binderFrom) NsValue b.binderOrigin)
    _ => Abstain LocalBinder

-- Every candidate must be a signed plain function and all must declare the same
-- result after `n` arguments.
rowsVerdict : Int -> List IndexRow -> Verdict
rowsVerdict _ [] = Abstain NoRows
rowsVerdict n rows
  | any (r => r.ixrKind /= RkValue) rows = Abstain NotAPlainFunction
  | not (all rowHasSig rows) = Abstain NoSignature
  | otherwise = agree (map (resultOf n) rows)

resultOf : Int -> IndexRow -> Result AbstainReason Ty
resultOf n r = match rowSig r
  None => Err NoSignature
  Some t => resultAfter n t

agree : List (Result AbstainReason Ty) -> Verdict
agree [] = Abstain NoRows
agree ((Err why) :: _) = Abstain why
agree ((Ok t) :: rest) = match firstDifferent t rest
  Some why => Abstain why
  None => Discard t

-- The first reason among `rest` to abstain, or `Ambiguous` for a result that
-- prints differently from `t`.
firstDifferent : Ty -> List (Result AbstainReason Ty) -> Option AbstainReason
firstDifferent _ [] = None
firstDifferent _ ((Err why) :: _) = Some why
firstDifferent t ((Ok u) :: rest)
  | ppTy t == ppTy u = firstDifferent t rest
  | otherwise = Some Ambiguous

-- The declared result once `n` arguments are applied.  Constraints, effect
-- rows and qualifiers wrap a type without being an argument.
resultAfter : Int -> Ty -> Result AbstainReason Ty
resultAfter n (TyConstrained _ t) = resultAfter n t
resultAfter n (TyQual t _ _) = resultAfter n t
resultAfter n (TyNamed _ t _) = resultAfter n t
resultAfter n (TyEffect _ _ t) = resultAfter n t
resultAfter n (TyFun _ r)
  | n == 0 = Err PartialApplication
  | otherwise = resultAfter (n - 1) r
resultAfter n t
  | n == 0 = Ok t
  | otherwise = Err OverApplied
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("string") ((mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Ctx" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" true) (mem "Ns" true) (mem "ProjectIndex" false) (mem "RowKind" true) (mem "rowHasSig" false) (mem "rowSig" false) (mem "rowsIn" false) (mem "rowsNamed" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "unwrapLoc" false))))
(DData Public "BlockKind" () ((variant "PlainBlock" (ConPos)) (variant "DoBlock" (ConPos))) ())
(DImpl true "Eq" ((TyCon "BlockKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PlainBlock") (PCon "PlainBlock")) () (EVar "True")) (arm (PTuple (PCon "DoBlock") (PCon "DoBlock")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "BlockKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PlainBlock") () (ELit (LString "PlainBlock"))) (arm (PCon "DoBlock") () (ELit (LString "DoBlock")))))))
(DData Public "AbstainReason" () ((variant "NotADiscard" (ConPos)) (variant "NotACall" (ConPos)) (variant "HeadNotAName" (ConPos)) (variant "NoSite" (ConPos)) (variant "LocalBinder" (ConPos)) (variant "NoRows" (ConPos)) (variant "NotAPlainFunction" (ConPos)) (variant "NoSignature" (ConPos)) (variant "Ambiguous" (ConPos)) (variant "PartialApplication" (ConPos)) (variant "OverApplied" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbstainReason")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NotADiscard") (PCon "NotADiscard")) () (EVar "True")) (arm (PTuple (PCon "NotACall") (PCon "NotACall")) () (EVar "True")) (arm (PTuple (PCon "HeadNotAName") (PCon "HeadNotAName")) () (EVar "True")) (arm (PTuple (PCon "NoSite") (PCon "NoSite")) () (EVar "True")) (arm (PTuple (PCon "LocalBinder") (PCon "LocalBinder")) () (EVar "True")) (arm (PTuple (PCon "NoRows") (PCon "NoRows")) () (EVar "True")) (arm (PTuple (PCon "NotAPlainFunction") (PCon "NotAPlainFunction")) () (EVar "True")) (arm (PTuple (PCon "NoSignature") (PCon "NoSignature")) () (EVar "True")) (arm (PTuple (PCon "Ambiguous") (PCon "Ambiguous")) () (EVar "True")) (arm (PTuple (PCon "PartialApplication") (PCon "PartialApplication")) () (EVar "True")) (arm (PTuple (PCon "OverApplied") (PCon "OverApplied")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbstainReason")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NotADiscard") () (ELit (LString "NotADiscard"))) (arm (PCon "NotACall") () (ELit (LString "NotACall"))) (arm (PCon "HeadNotAName") () (ELit (LString "HeadNotAName"))) (arm (PCon "NoSite") () (ELit (LString "NoSite"))) (arm (PCon "LocalBinder") () (ELit (LString "LocalBinder"))) (arm (PCon "NoRows") () (ELit (LString "NoRows"))) (arm (PCon "NotAPlainFunction") () (ELit (LString "NotAPlainFunction"))) (arm (PCon "NoSignature") () (ELit (LString "NoSignature"))) (arm (PCon "Ambiguous") () (ELit (LString "Ambiguous"))) (arm (PCon "PartialApplication") () (ELit (LString "PartialApplication"))) (arm (PCon "OverApplied") () (ELit (LString "OverApplied")))))))
(DData Public "Verdict" () ((variant "Discard" (ConPos (TyCon "Ty"))) (variant "Abstain" (ConPos (TyCon "AbstainReason")))) ())
(DImpl false "Eq" ((TyCon "Verdict")) () ((im "eq" ((PCon "Discard" (PVar "a")) (PCon "Discard" (PVar "b"))) (EBinOp "==" (EApp (EVar "ppTy") (EVar "a")) (EApp (EVar "ppTy") (EVar "b")))) (im "eq" ((PCon "Abstain" (PVar "a")) (PCon "Abstain" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyCon "Verdict")) () ((im "debug" ((PCon "Discard" (PVar "t"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Discard (")) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ")")))) (im "debug" ((PCon "Abstain" (PVar "r"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Abstain ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "r")))) (ELit (LString ""))))))
(DData Public "DiscardClass" () ((variant "ClassUnit" (ConPos)) (variant "ClassResult" (ConPos)) (variant "ClassOption" (ConPos)) (variant "ClassOther" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiscardClass")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ClassUnit") (PCon "ClassUnit")) () (EVar "True")) (arm (PTuple (PCon "ClassResult") (PCon "ClassResult")) () (EVar "True")) (arm (PTuple (PCon "ClassOption") (PCon "ClassOption")) () (EVar "True")) (arm (PTuple (PCon "ClassOther") (PCon "ClassOther")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiscardClass")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ClassUnit") () (ELit (LString "ClassUnit"))) (arm (PCon "ClassResult") () (ELit (LString "ClassResult"))) (arm (PCon "ClassOption") () (ELit (LString "ClassOption"))) (arm (PCon "ClassOther") () (ELit (LString "ClassOther")))))))
(DTypeSig true "discardClass" (TyFun (TyCon "Ty") (TyCon "DiscardClass")))
(DFunDef false "discardClass" ((PVar "t")) (EMatch (EApp (EVar "headName") (EVar "t")) (arm (PLit (LString "Unit")) () (EVar "ClassUnit")) (arm (PLit (LString "Result")) () (EVar "ClassResult")) (arm (PLit (LString "Option")) () (EVar "ClassOption")) (arm PWild () (EVar "ClassOther"))))
(DTypeSig false "headName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "headName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "lastSegment") (EVar "n")))
(DFunDef false "headName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headName") (EVar "f")))
(DFunDef false "headName" ((PCon "TyTuple" (PList))) (ELit (LString "Unit")))
(DFunDef false "headName" (PWild) (ELit (LString "")))
(DTypeSig false "lastSegment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lastSegment" ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "n")))))
(DTypeSig true "blockOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "BlockKind") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "blockOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EVar "Some") (ETuple (EVar "PlainBlock") (EVar "stmts")))) (arm (PCon "EDo" PWild (PVar "stmts")) () (EApp (EVar "Some") (ETuple (EVar "DoBlock") (EVar "stmts")))) (arm PWild () (EVar "None"))))
(DTypeSig true "inPlainBlock" (TyFun (TyCon "Ctx") (TyCon "Bool")))
(DFunDef false "inPlainBlock" ((PVar "ctx")) (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KBlock"))))
(DTypeSig true "discardVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyCon "Verdict"))))))
(DFunDef false "discardVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "callVerdict") (EVar "ix")) (EVar "scopes")) (EVar "modId")) (EVar "rhs")))
(DFunDef false "discardVerdict" (PWild PWild PWild PWild) (EApp (EVar "Abstain") (EVar "NotADiscard")))
(DTypeSig false "callVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Verdict"))))))
(DFunDef false "callVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PVar "e")) (EMatch (EApp (EApp (EVar "spine") (EVar "e")) (ELit (LInt 0))) (arm (PTuple (PVar "hd") (PLit (LInt 0))) () (EApp (EVar "Abstain") (EVar "NotACall"))) (arm (PTuple (PVar "hd") (PVar "n")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "name")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nameVerdict") (EVar "ix")) (EVar "scopes")) (EVar "modId")) (EVar "name")) (EApp (EVar "siteOf") (EVar "hd"))) (EVar "n"))) (arm PWild () (EApp (EVar "Abstain") (EVar "HeadNotAName")))))))
(DTypeSig false "spine" (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyTuple (TyCon "Expr") (TyCon "Int")))))
(DFunDef false "spine" ((PVar "e") (PVar "n")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "spine") (EVar "f")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (arm PWild () (ETuple (EVar "e") (EVar "n")))))
(DTypeSig false "siteOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "siteOf" ((PCon "ELoc" (PVar "l") (PVar "inner"))) (EMatch (EApp (EVar "siteOf") (EVar "inner")) (arm (PCon "Some" (PVar "inner2")) () (EApp (EVar "Some") (EVar "inner2"))) (arm (PCon "None") () (EMatch (EVar "inner") (arm (PCon "EVar" PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))))
(DFunDef false "siteOf" (PWild) (EVar "None"))
(DTypeSig false "nameVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "Verdict"))))))))
(DFunDef false "nameVerdict" (PWild PWild PWild PWild (PCon "None") PWild) (EApp (EVar "Abstain") (EVar "NoSite")))
(DFunDef false "nameVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PVar "name") (PCon "Some" (PVar "l")) (PVar "n")) (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "l")) (arm (PCon "None") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "name")))) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "binderKind") (arm (PCon "BTopLevel") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rowsIn") (EVar "ix")) (EVar "modId")) (EVar "NsValue")) (EVar "name")))) (arm (PCon "BImport") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rowsIn") (EVar "ix")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EFieldAccess (EVar "b") "binderFrom"))) (EVar "NsValue")) (EFieldAccess (EVar "b") "binderOrigin")))) (arm PWild () (EApp (EVar "Abstain") (EVar "LocalBinder")))))))
(DTypeSig false "rowsVerdict" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "Verdict"))))
(DFunDef false "rowsVerdict" (PWild (PList)) (EApp (EVar "Abstain") (EVar "NoRows")))
(DFunDef false "rowsVerdict" ((PVar "n") (PVar "rows")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "r")) (EBinOp "/=" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkValue")))) (EVar "rows")) (EApp (EVar "Abstain") (EVar "NotAPlainFunction")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "all") (EVar "rowHasSig")) (EVar "rows"))) (EApp (EVar "Abstain") (EVar "NoSignature")) (EIf (EVar "otherwise") (EApp (EVar "agree") (EApp (EApp (EVar "map") (EApp (EVar "resultOf") (EVar "n"))) (EVar "rows"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resultOf" (TyFun (TyCon "Int") (TyFun (TyCon "IndexRow") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty")))))
(DFunDef false "resultOf" ((PVar "n") (PVar "r")) (EMatch (EApp (EVar "rowSig") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Err") (EVar "NoSignature"))) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))))
(DTypeSig false "agree" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty"))) (TyCon "Verdict")))
(DFunDef false "agree" ((PList)) (EApp (EVar "Abstain") (EVar "NoRows")))
(DFunDef false "agree" ((PCons (PCon "Err" (PVar "why")) PWild)) (EApp (EVar "Abstain") (EVar "why")))
(DFunDef false "agree" ((PCons (PCon "Ok" (PVar "t")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "firstDifferent") (EVar "t")) (EVar "rest")) (arm (PCon "Some" (PVar "why")) () (EApp (EVar "Abstain") (EVar "why"))) (arm (PCon "None") () (EApp (EVar "Discard") (EVar "t")))))
(DTypeSig false "firstDifferent" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty"))) (TyApp (TyCon "Option") (TyCon "AbstainReason")))))
(DFunDef false "firstDifferent" (PWild (PList)) (EVar "None"))
(DFunDef false "firstDifferent" (PWild (PCons (PCon "Err" (PVar "why")) PWild)) (EApp (EVar "Some") (EVar "why")))
(DFunDef false "firstDifferent" ((PVar "t") (PCons (PCon "Ok" (PVar "u")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppTy") (EVar "t")) (EApp (EVar "ppTy") (EVar "u"))) (EApp (EApp (EVar "firstDifferent") (EVar "t")) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "Ambiguous")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resultAfter" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty")))))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyFun" PWild (PVar "r"))) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EVar "PartialApplication")) (EIf (EVar "otherwise") (EApp (EApp (EVar "resultAfter") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "resultAfter" ((PVar "n") (PVar "t")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "t")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EVar "OverApplied")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("string") ((mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Ctx" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" true) (mem "Ns" true) (mem "ProjectIndex" false) (mem "RowKind" true) (mem "rowHasSig" false) (mem "rowSig" false) (mem "rowsIn" false) (mem "rowsNamed" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "unwrapLoc" false))))
(DData Public "BlockKind" () ((variant "PlainBlock" (ConPos)) (variant "DoBlock" (ConPos))) ())
(DImpl true "Eq" ((TyCon "BlockKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PlainBlock") (PCon "PlainBlock")) () (EVar "True")) (arm (PTuple (PCon "DoBlock") (PCon "DoBlock")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "BlockKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PlainBlock") () (ELit (LString "PlainBlock"))) (arm (PCon "DoBlock") () (ELit (LString "DoBlock")))))))
(DData Public "AbstainReason" () ((variant "NotADiscard" (ConPos)) (variant "NotACall" (ConPos)) (variant "HeadNotAName" (ConPos)) (variant "NoSite" (ConPos)) (variant "LocalBinder" (ConPos)) (variant "NoRows" (ConPos)) (variant "NotAPlainFunction" (ConPos)) (variant "NoSignature" (ConPos)) (variant "Ambiguous" (ConPos)) (variant "PartialApplication" (ConPos)) (variant "OverApplied" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbstainReason")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NotADiscard") (PCon "NotADiscard")) () (EVar "True")) (arm (PTuple (PCon "NotACall") (PCon "NotACall")) () (EVar "True")) (arm (PTuple (PCon "HeadNotAName") (PCon "HeadNotAName")) () (EVar "True")) (arm (PTuple (PCon "NoSite") (PCon "NoSite")) () (EVar "True")) (arm (PTuple (PCon "LocalBinder") (PCon "LocalBinder")) () (EVar "True")) (arm (PTuple (PCon "NoRows") (PCon "NoRows")) () (EVar "True")) (arm (PTuple (PCon "NotAPlainFunction") (PCon "NotAPlainFunction")) () (EVar "True")) (arm (PTuple (PCon "NoSignature") (PCon "NoSignature")) () (EVar "True")) (arm (PTuple (PCon "Ambiguous") (PCon "Ambiguous")) () (EVar "True")) (arm (PTuple (PCon "PartialApplication") (PCon "PartialApplication")) () (EVar "True")) (arm (PTuple (PCon "OverApplied") (PCon "OverApplied")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbstainReason")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NotADiscard") () (ELit (LString "NotADiscard"))) (arm (PCon "NotACall") () (ELit (LString "NotACall"))) (arm (PCon "HeadNotAName") () (ELit (LString "HeadNotAName"))) (arm (PCon "NoSite") () (ELit (LString "NoSite"))) (arm (PCon "LocalBinder") () (ELit (LString "LocalBinder"))) (arm (PCon "NoRows") () (ELit (LString "NoRows"))) (arm (PCon "NotAPlainFunction") () (ELit (LString "NotAPlainFunction"))) (arm (PCon "NoSignature") () (ELit (LString "NoSignature"))) (arm (PCon "Ambiguous") () (ELit (LString "Ambiguous"))) (arm (PCon "PartialApplication") () (ELit (LString "PartialApplication"))) (arm (PCon "OverApplied") () (ELit (LString "OverApplied")))))))
(DData Public "Verdict" () ((variant "Discard" (ConPos (TyCon "Ty"))) (variant "Abstain" (ConPos (TyCon "AbstainReason")))) ())
(DImpl false "Eq" ((TyCon "Verdict")) () ((im "eq" ((PCon "Discard" (PVar "a")) (PCon "Discard" (PVar "b"))) (EBinOp "==" (EApp (EVar "ppTy") (EVar "a")) (EApp (EVar "ppTy") (EVar "b")))) (im "eq" ((PCon "Abstain" (PVar "a")) (PCon "Abstain" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyCon "Verdict")) () ((im "debug" ((PCon "Discard" (PVar "t"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Discard (")) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ")")))) (im "debug" ((PCon "Abstain" (PVar "r"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Abstain ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "r")))) (ELit (LString ""))))))
(DData Public "DiscardClass" () ((variant "ClassUnit" (ConPos)) (variant "ClassResult" (ConPos)) (variant "ClassOption" (ConPos)) (variant "ClassOther" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiscardClass")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ClassUnit") (PCon "ClassUnit")) () (EVar "True")) (arm (PTuple (PCon "ClassResult") (PCon "ClassResult")) () (EVar "True")) (arm (PTuple (PCon "ClassOption") (PCon "ClassOption")) () (EVar "True")) (arm (PTuple (PCon "ClassOther") (PCon "ClassOther")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiscardClass")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ClassUnit") () (ELit (LString "ClassUnit"))) (arm (PCon "ClassResult") () (ELit (LString "ClassResult"))) (arm (PCon "ClassOption") () (ELit (LString "ClassOption"))) (arm (PCon "ClassOther") () (ELit (LString "ClassOther")))))))
(DTypeSig true "discardClass" (TyFun (TyCon "Ty") (TyCon "DiscardClass")))
(DFunDef false "discardClass" ((PVar "t")) (EMatch (EApp (EVar "headName") (EVar "t")) (arm (PLit (LString "Unit")) () (EVar "ClassUnit")) (arm (PLit (LString "Result")) () (EVar "ClassResult")) (arm (PLit (LString "Option")) () (EVar "ClassOption")) (arm PWild () (EVar "ClassOther"))))
(DTypeSig false "headName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "headName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "lastSegment") (EVar "n")))
(DFunDef false "headName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headName") (EVar "f")))
(DFunDef false "headName" ((PCon "TyTuple" (PList))) (ELit (LString "Unit")))
(DFunDef false "headName" (PWild) (ELit (LString "")))
(DTypeSig false "lastSegment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lastSegment" ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "n")))))
(DTypeSig true "blockOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "BlockKind") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "blockOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EVar "Some") (ETuple (EVar "PlainBlock") (EVar "stmts")))) (arm (PCon "EDo" PWild (PVar "stmts")) () (EApp (EVar "Some") (ETuple (EVar "DoBlock") (EVar "stmts")))) (arm PWild () (EVar "None"))))
(DTypeSig true "inPlainBlock" (TyFun (TyCon "Ctx") (TyCon "Bool")))
(DFunDef false "inPlainBlock" ((PVar "ctx")) (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KBlock"))))
(DTypeSig true "discardVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyCon "Verdict"))))))
(DFunDef false "discardVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "callVerdict") (EVar "ix")) (EVar "scopes")) (EVar "modId")) (EVar "rhs")))
(DFunDef false "discardVerdict" (PWild PWild PWild PWild) (EApp (EVar "Abstain") (EVar "NotADiscard")))
(DTypeSig false "callVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Verdict"))))))
(DFunDef false "callVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PVar "e")) (EMatch (EApp (EApp (EVar "spine") (EVar "e")) (ELit (LInt 0))) (arm (PTuple (PVar "hd") (PLit (LInt 0))) () (EApp (EVar "Abstain") (EVar "NotACall"))) (arm (PTuple (PVar "hd") (PVar "n")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "name")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nameVerdict") (EVar "ix")) (EVar "scopes")) (EVar "modId")) (EVar "name")) (EApp (EVar "siteOf") (EVar "hd"))) (EVar "n"))) (arm PWild () (EApp (EVar "Abstain") (EVar "HeadNotAName")))))))
(DTypeSig false "spine" (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyTuple (TyCon "Expr") (TyCon "Int")))))
(DFunDef false "spine" ((PVar "e") (PVar "n")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "spine") (EVar "f")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (arm PWild () (ETuple (EVar "e") (EVar "n")))))
(DTypeSig false "siteOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "siteOf" ((PCon "ELoc" (PVar "l") (PVar "inner"))) (EMatch (EApp (EVar "siteOf") (EVar "inner")) (arm (PCon "Some" (PVar "inner2")) () (EApp (EVar "Some") (EVar "inner2"))) (arm (PCon "None") () (EMatch (EVar "inner") (arm (PCon "EVar" PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))))
(DFunDef false "siteOf" (PWild) (EVar "None"))
(DTypeSig false "nameVerdict" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "Verdict"))))))))
(DFunDef false "nameVerdict" (PWild PWild PWild PWild (PCon "None") PWild) (EApp (EVar "Abstain") (EVar "NoSite")))
(DFunDef false "nameVerdict" ((PVar "ix") (PVar "scopes") (PVar "modId") (PVar "name") (PCon "Some" (PVar "l")) (PVar "n")) (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "l")) (arm (PCon "None") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "name")))) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "binderKind") (arm (PCon "BTopLevel") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rowsIn") (EVar "ix")) (EVar "modId")) (EVar "NsValue")) (EVar "name")))) (arm (PCon "BImport") () (EApp (EApp (EVar "rowsVerdict") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rowsIn") (EVar "ix")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EFieldAccess (EVar "b") "binderFrom"))) (EVar "NsValue")) (EFieldAccess (EVar "b") "binderOrigin")))) (arm PWild () (EApp (EVar "Abstain") (EVar "LocalBinder")))))))
(DTypeSig false "rowsVerdict" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "Verdict"))))
(DFunDef false "rowsVerdict" (PWild (PList)) (EApp (EVar "Abstain") (EVar "NoRows")))
(DFunDef false "rowsVerdict" ((PVar "n") (PVar "rows")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "r")) (EBinOp "/=" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkValue")))) (EVar "rows")) (EApp (EVar "Abstain") (EVar "NotAPlainFunction")) (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "all") (EVar "rowHasSig")) (EVar "rows"))) (EApp (EVar "Abstain") (EVar "NoSignature")) (EIf (EVar "otherwise") (EApp (EVar "agree") (EApp (EApp (EMethodRef "map") (EApp (EVar "resultOf") (EVar "n"))) (EVar "rows"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resultOf" (TyFun (TyCon "Int") (TyFun (TyCon "IndexRow") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty")))))
(DFunDef false "resultOf" ((PVar "n") (PVar "r")) (EMatch (EApp (EVar "rowSig") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Err") (EVar "NoSignature"))) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))))
(DTypeSig false "agree" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty"))) (TyCon "Verdict")))
(DFunDef false "agree" ((PList)) (EApp (EVar "Abstain") (EVar "NoRows")))
(DFunDef false "agree" ((PCons (PCon "Err" (PVar "why")) PWild)) (EApp (EVar "Abstain") (EVar "why")))
(DFunDef false "agree" ((PCons (PCon "Ok" (PVar "t")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "firstDifferent") (EVar "t")) (EVar "rest")) (arm (PCon "Some" (PVar "why")) () (EApp (EVar "Abstain") (EVar "why"))) (arm (PCon "None") () (EApp (EVar "Discard") (EVar "t")))))
(DTypeSig false "firstDifferent" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty"))) (TyApp (TyCon "Option") (TyCon "AbstainReason")))))
(DFunDef false "firstDifferent" (PWild (PList)) (EVar "None"))
(DFunDef false "firstDifferent" (PWild (PCons (PCon "Err" (PVar "why")) PWild)) (EApp (EVar "Some") (EVar "why")))
(DFunDef false "firstDifferent" ((PVar "t") (PCons (PCon "Ok" (PVar "u")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppTy") (EVar "t")) (EApp (EVar "ppTy") (EVar "u"))) (EApp (EApp (EVar "firstDifferent") (EVar "t")) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "Ambiguous")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resultAfter" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "AbstainReason")) (TyCon "Ty")))))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "resultAfter") (EVar "n")) (EVar "t")))
(DFunDef false "resultAfter" ((PVar "n") (PCon "TyFun" PWild (PVar "r"))) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EVar "PartialApplication")) (EIf (EVar "otherwise") (EApp (EApp (EVar "resultAfter") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "resultAfter" ((PVar "n") (PVar "t")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "t")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EVar "OverApplied")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
