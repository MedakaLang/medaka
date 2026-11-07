# META
source_lines=309
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-reslice-in-loop: a loop parameter re-sliced from its start on every step (`stringSlice`, `charAtStr`, `slice`, `drop`). Walk a `StrCursor`, or convert with `toChars` once.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Decl(..), Expr(..), Loc, Pat(..), Ty(..), orElseLoc, patBoundNames
}
import frontend.ast_walk.{
  BodyOwner(..),
  DeclBody(..),
  ExprKind(..),
  childExprs,
  declBodies,
}
import frontend.parser.{Positions(..)}
import list.{findMap, get, nubBy}
import string.{contains}
import tools.lint_calls.{lastSegment}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  factScopes,
  mkVisitorRule,
  noFix,
}
import tools.lint_recursion.{
  ArgRole(..),
  Owner(..),
  SelfCall(..),
  letOwners,
  selfCalls,
  spineOf,
}
import tools.lint_shared.{
  firstLoc, mentionsVar, ruleNameResliceInLoop, unwrapLoc
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameResliceInLoop,
      summary =
        "a loop parameter re-sliced from its start on every step: quadratic on some engines and access patterns. Walk a `StrCursor`, or convert with `toChars` once",
      doc =
        "A self-recursive loop that passes a `String`, `Array` or `Bytes` parameter on unchanged while another argument advances, and slices that parameter by the advancing index, starts from the front of the parameter on every step. The rule reports the String externs `stringSlice` and `charAtStr` on such a parameter, and `slice`, `sliceClamped`, `drop` and `a.[lo..hi]` on a parameter whose declared type, in the enclosing top-level signature, is `String`, `Array` or `Bytes`. A `List` parameter is skipped (`drop` on a list is the loop itself), and so is a slice whose bounds mention no advancing name. A partial application and a call to a different function (mutual recursion) are not self-calls. `stringSliceBytes` is not reported: it copies only the piece and does not walk the string.\n\nFor a `String`, `stringSlice` and `charAtStr` locate their offset from the front of the string. On the native runtime a forward scan of one string is linear, because the runtime keeps a cursor cache for one string; the loop is quadratic when it alternates between two strings, goes backward or slices the tail, and on the WasmGC engine, which has no cache, even a forward scan is quadratic. Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert once with `toChars` and index the `Array`. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-reslice-in-loop` with the bound as its reason.\n\nBefore:\n  go s i = if i < stringLength s then stringSlice i (i + 1) s :: go s (i + 1) else []\nAfter:\n  go cs i = if i < length cs then cs.[i] :: go cs (i + 1) else []  -- with `cs = toChars s`",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes],
    }
    ruleReslice
    None

-- A file that mentions none of the sliced forms has nothing to report, so its
-- bodies are not walked.
ruleReslice : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleReslice _ _ facts _ decls
  | any (w => contains w facts.ffSrc) mentions = [
    OnDecl (declFindings facts decls),
    OnExpr [KLetGroup] (localFindings facts),
  ]
  | otherwise = []

mentions : List String
mentions = ["stringSlice", "charAtStr", "slice", "drop", ".["]

-- The top-level owners of one declaration.  Test and prop bodies run over fixed
-- data and are not checked.
declFindings : FileFacts -> List Decl -> Ctx -> Decl -> List Finding
declFindings facts decls ctx d =
  flatMap (bodyFindings facts decls ctx.ctxSpan) (declBodies d)

bodyFindings : FileFacts -> List Decl -> Option Loc -> DeclBody -> List Finding
bodyFindings facts decls fallback (DeclBody owner body) = match ownerOf owner
  Some (o, name) =>
    ownerFindings facts (i => get i (sigDomains decls name)) fallback (o, body)
  None => []

ownerOf : BodyOwner -> Option (Owner, String)
ownerOf (OwnerClause name ps) = Some (Owner name ps None, name)
ownerOf (OwnerImplMethod _ _ _) = None
ownerOf (OwnerIfaceDefault _ _ _) = None
ownerOf (OwnerLetGroup _ _) = None
ownerOf (OwnerTest _) = None
ownerOf (OwnerProp _ _) = None

-- The `where`/`let` loops of one group.  A local loop has no signature in the
-- file's declaration list, so only the String externs are checked in it.
localFindings : FileFacts -> Ctx -> Expr -> List Finding
localFindings facts ctx e
  | ctx.ctxInTest = []
  | otherwise =
    flatMap (ownerFindings facts (_ => None) ctx.ctxSpan) (letOwners e)

-- ── signatures ───────────────────────────────────────────────────────────────

-- The head type name of each argument of the top-level signature of `name`;
-- `[]` when it has none.
sigDomains : List Decl -> String -> List String
sigDomains decls name = optionOr [] (findMap (sigOf name) decls)

sigOf : String -> Decl -> Option (List String)
sigOf name (DTypeSig _ n t _) = if n == name then Some (domains t) else None
sigOf name (DAttrib _ d) = sigOf name d
sigOf _ _ = None

domains : Ty -> List String
domains (TyConstrained _ t) = domains t
domains (TyEffect _ _ t) = domains t
domains (TyQual t _ _) = domains t
domains (TyFun a b) = headOf a :: domains b
domains _ = []

headOf : Ty -> String
headOf (TyCon { tyConName = n }) = lastSegment n
headOf (TyApp f _) = headOf f
headOf (TyNamed _ t _) = headOf t
headOf (TyQual t _ _) = headOf t
headOf _ = ""

-- ── use sites ────────────────────────────────────────────────────────────────

-- Which form sliced the parameter: a String extern, or a polymorphic slice
-- that needs the parameter's declared type.
data Form = Extern | Polymorphic

-- A slice of a bare variable: the span, the form, the callee, the variable and
-- the other arguments (the bounds).
data Use = Use (Option Loc) Form String String (List Expr)

-- The slices in `body`.  The bodies of nested `let`/`where` groups are owners of
-- their own and are not entered.
usesIn : Option Loc -> Expr -> List Use
usesIn _ (ELoc l inner) = usesIn (Some l) inner
usesIn loc (ELetGroup _ body) = usesIn loc body
usesIn loc e = useHere loc e ++ flatMap (usesIn loc) (childExprs e)

useHere : Option Loc -> Expr -> List Use
useHere loc (EApp f a) = match spineOf f [a]
  (hd, args) => callUse loc hd args
useHere loc (EBinOp "|>" l r _) = match spineOf r []
  (hd, args) => callUse loc hd (args ++ [l])
useHere loc (ESlice c lo hi _) = match unwrapLoc c
  EVar v => [Use (orElseLoc (firstLoc c) loc) Polymorphic "a.[..]" v [lo, hi]]
  _ => []
useHere _ _ = []

callUse : Option Loc -> Expr -> List Expr -> List Use
callUse loc hd args = match unwrapLoc hd
  EVar n => calleeUse (orElseLoc (firstLoc hd) loc) (lastSegment n) args
  _ => []

calleeUse : Option Loc -> String -> List Expr -> List Use
calleeUse loc "stringSlice" [lo, hi, s] =
  containerUse loc Extern "stringSlice" s [lo, hi]
calleeUse loc "charAtStr" [s, i] = containerUse loc Extern "charAtStr" s [i]
calleeUse loc "drop" [n, c] = containerUse loc Polymorphic "drop" c [n]
calleeUse loc "slice" [c, lo, hi] =
  containerUse loc Polymorphic "slice" c [lo, hi]
calleeUse loc "sliceClamped" [lo, hi, c] =
  containerUse loc Polymorphic "sliceClamped" c [lo, hi]
calleeUse _ _ _ = []

containerUse : Option Loc -> Form -> String -> Expr -> List Expr -> List Use
containerUse loc form callee c bounds = match unwrapLoc c
  EVar v => [Use loc form callee v bounds]
  _ => []

-- ── the loop ─────────────────────────────────────────────────────────────────

-- The name a parameter binds as a whole, with its position.
wholeParams : List Pat -> List (String, Int)
wholeParams ps = go 0 ps
  where
    go _ [] = []
    go i ((PVar n _ _) :: rest) = (n, i) :: go (i + 1) rest
    go i ((PAs n _ _ _) :: rest) = (n, i) :: go (i + 1) rest
    go i (_ :: rest) = go (i + 1) rest

ownerFindings : FileFacts ->
  (Int -> Option String) ->
  Option Loc ->
  (Owner, Expr) ->
  List Finding
ownerFindings facts types fallback (owner@(Owner _ ps _), body) =
  match wholeParams ps
    [] => []
    params => match candidates params (usesIn None body)
      [] => []
      uses => match selfCalls (factScopes facts) owner body
        [] => []
        calls =>
          let advancing = advancingNames ps calls
          dedupe
            (flatMap (useFinding types fallback params calls advancing) uses)

candidates : List (String, Int) -> List Use -> List Use
candidates params = filter ((Use _ _ _ v _) => any ((n, _) => n == v) params)

-- The parameter of a self-call at `i` is the parameter's own name in every
-- self-call of the owner.
passedUnchanged : List SelfCall -> Int -> Bool
passedUnchanged calls i = all (rolesAt i) calls
  where
    rolesAt k (SelfCall _ _ roles) = get k roles == Some (Unchanged k)

-- The names bound by the parameters that some self-call advances.
advancingNames : List Pat -> List SelfCall -> List String
advancingNames ps calls = go 0 ps
  where
    go _ [] = []
    go i (p :: rest)
      | any (advancesAt i) calls = patBoundNames p ++ go (i + 1) rest
      | otherwise = go (i + 1) rest
    advancesAt i (SelfCall _ _ roles) = match get i roles
      Some (Advanced _) => True
      _ => False

useFinding : (Int -> Option String) ->
  Option Loc ->
  List (String, Int) ->
  List SelfCall ->
  List String ->
  Use ->
  List Finding
useFinding types fallback params calls advancing (Use loc form callee v bounds) =
  match findMap (paramPos v) params
    None => []
    Some i =>
      if passedUnchanged calls i
        && any (b => any (n => mentionsVar n b) advancing) bounds
        && formApplies types form i then
        [report (orElseLoc loc fallback) (message form callee v (types i))]
      else
        []

paramPos : String -> (String, Int) -> Option Int
paramPos v (n, i) = if n == v then Some i else None

-- A String extern needs no declared type.  A polymorphic slice needs the
-- parameter declared `String`, `Array` or `Bytes`.
formApplies : (Int -> Option String) -> Form -> Int -> Bool
formApplies _ Extern _ = True
formApplies types Polymorphic i = match types i
  Some "String" => True
  Some "Array" => True
  Some "Bytes" => True
  _ => False

-- One finding per span.
dedupe : List Finding -> List Finding
dedupe = nubBy sameSpan

sameSpan : Finding -> Finding -> Bool
sameSpan (Finding { loc = a, ... }) (Finding { loc = b, ... }) = a == b

-- ── findings ─────────────────────────────────────────────────────────────────

report : Option Loc -> String -> Finding
report loc msg = Finding {
  rule = ruleNameResliceInLoop,
  message = msg,
  severity = SevWarning,
  loc = loc,
  fix = noFix,
}

message : Form -> String -> String -> Option String -> String
message form callee v ty =
  "`\{callee}` on `\{v}`, which the loop passes on unchanged while another argument advances, starts from the front of `\{v}` on every step. \{costNote form ty} \{fixTarget form ty}"

-- A String is located by walking from its front, so its cost depends on the
-- engine; an Array or Bytes slice copies the piece on every engine.
costNote : Form -> Option String -> String
costNote Extern _ = stringCost
costNote Polymorphic (Some "String") = stringCost
costNote Polymorphic _ = "The loop is quadratic."

stringCost : String
stringCost =
  "The loop is quadratic on the WasmGC engine and, on the native runtime, when it alternates between strings, goes backward or slices the tail."

fixTarget : Form -> Option String -> String
fixTarget Extern _ = stringFix
fixTarget Polymorphic (Some "String") = stringFix
fixTarget Polymorphic _ =
  "Keep the offset and index the value (`a.[i]`) instead of slicing it again"

stringFix : String
stringFix =
  "Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert with `toChars` once and index the `Array`"
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true) (mem "orElseLoc" false) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "nubBy" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "firstLoc" false) (mem "mentionsVar" false) (mem "ruleNameResliceInLoop" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameResliceInLoop")) (fa "summary" (ELit (LString "a loop parameter re-sliced from its start on every step: quadratic on some engines and access patterns. Walk a `StrCursor`, or convert with `toChars` once"))) (fa "doc" (ELit (LString "A self-recursive loop that passes a `String`, `Array` or `Bytes` parameter on unchanged while another argument advances, and slices that parameter by the advancing index, starts from the front of the parameter on every step. The rule reports the String externs `stringSlice` and `charAtStr` on such a parameter, and `slice`, `sliceClamped`, `drop` and `a.[lo..hi]` on a parameter whose declared type, in the enclosing top-level signature, is `String`, `Array` or `Bytes`. A `List` parameter is skipped (`drop` on a list is the loop itself), and so is a slice whose bounds mention no advancing name. A partial application and a call to a different function (mutual recursion) are not self-calls. `stringSliceBytes` is not reported: it copies only the piece and does not walk the string.\n\nFor a `String`, `stringSlice` and `charAtStr` locate their offset from the front of the string. On the native runtime a forward scan of one string is linear, because the runtime keeps a cursor cache for one string; the loop is quadratic when it alternates between two strings, goes backward or slices the tail, and on the WasmGC engine, which has no cache, even a forward scan is quadratic. Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert once with `toChars` and index the `Array`. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-reslice-in-loop` with the bound as its reason.\n\nBefore:\n  go s i = if i < stringLength s then stringSlice i (i + 1) s :: go s (i + 1) else []\nAfter:\n  go cs i = if i < length cs then cs.[i] :: go cs (i + 1) else []  -- with `cs = toChars s`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleReslice")) (EVar "None")))
(DTypeSig false "ruleReslice" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleReslice" (PWild PWild (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "facts")) (EVar "decls"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "facts")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "stringSlice")) (ELit (LString "charAtStr")) (ELit (LString "slice")) (ELit (LString "drop")) (ELit (LString ".["))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "facts") (PVar "decls") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "bodyFindings") (EVar "facts")) (EVar "decls")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "bodyFindings" ((PVar "facts") (PVar "decls") (PVar "fallback") (PCon "DeclBody" (PVar "owner") (PVar "body"))) (EMatch (EApp (EVar "ownerOf") (EVar "owner")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name"))) () (EApp (EApp (EApp (EApp (EVar "ownerFindings") (EVar "facts")) (ELam ((PVar "i")) (EApp (EApp (EVar "get") (EVar "i")) (EApp (EApp (EVar "sigDomains") (EVar "decls")) (EVar "name"))))) (EVar "fallback")) (ETuple (EVar "o") (EVar "body")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownerOf" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "Option") (TyTuple (TyCon "Owner") (TyCon "String")))))
(DFunDef false "ownerOf" ((PCon "OwnerClause" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None")) (EVar "name"))))
(DFunDef false "ownerOf" ((PCon "OwnerImplMethod" PWild PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerIfaceDefault" PWild PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerLetGroup" PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerTest" PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerProp" PWild PWild)) (EVar "None"))
(DTypeSig false "localFindings" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "facts") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "facts")) (ELam (PWild) (EVar "None"))) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "letOwners") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sigDomains" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sigDomains" ((PVar "decls") (PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "findMap") (EApp (EVar "sigOf") (EVar "name"))) (EVar "decls"))))
(DTypeSig false "sigOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigOf" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "t") PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EApp (EVar "domains") (EVar "t"))) (EVar "None")))
(DFunDef false "sigOf" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigOf") (EVar "name")) (EVar "d")))
(DFunDef false "sigOf" (PWild PWild) (EVar "None"))
(DTypeSig false "domains" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "domains" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EApp (EVar "headOf") (EVar "a")) (EApp (EVar "domains") (EVar "b"))))
(DFunDef false "domains" (PWild) (EListLit))
(DTypeSig false "headOf" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "headOf" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "lastSegment") (EVar "n")))
(DFunDef false "headOf" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headOf") (EVar "f")))
(DFunDef false "headOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "headOf") (EVar "t")))
(DFunDef false "headOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "headOf") (EVar "t")))
(DFunDef false "headOf" (PWild) (ELit (LString "")))
(DData Private "Form" () ((variant "Extern" (ConPos)) (variant "Polymorphic" (ConPos))) ())
(DData Private "Use" () ((variant "Use" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Form") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr"))))) ())
(DTypeSig false "usesIn" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "usesIn" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "usesIn") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "usesIn" ((PVar "loc") (PCon "ELetGroup" PWild (PVar "body"))) (EApp (EApp (EVar "usesIn") (EVar "loc")) (EVar "body")))
(DFunDef false "usesIn" ((PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "useHere") (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "usesIn") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "useHere" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "useHere" ((PVar "loc") (PCon "EApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callUse") (EVar "loc")) (EVar "hd")) (EVar "args")))))
(DFunDef false "useHere" ((PVar "loc") (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callUse") (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))))))
(DFunDef false "useHere" ((PVar "loc") (PCon "ESlice" (PVar "c") (PVar "lo") (PVar "hi") PWild)) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Use") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "c"))) (EVar "loc"))) (EVar "Polymorphic")) (ELit (LString "a.[..]"))) (EVar "v")) (EListLit (EVar "lo") (EVar "hi"))))) (arm PWild () (EListLit))))
(DFunDef false "useHere" (PWild PWild) (EListLit))
(DTypeSig false "callUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))
(DFunDef false "callUse" ((PVar "loc") (PVar "hd") (PVar "args")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EApp (EVar "calleeUse") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EApp (EVar "lastSegment") (EVar "n"))) (EVar "args"))) (arm PWild () (EListLit))))
(DTypeSig false "calleeUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "stringSlice")) (PList (PVar "lo") (PVar "hi") (PVar "s"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Extern")) (ELit (LString "stringSlice"))) (EVar "s")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "charAtStr")) (PList (PVar "s") (PVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Extern")) (ELit (LString "charAtStr"))) (EVar "s")) (EListLit (EVar "i"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "drop")) (PList (PVar "n") (PVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "drop"))) (EVar "c")) (EListLit (EVar "n"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "slice")) (PList (PVar "c") (PVar "lo") (PVar "hi"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "slice"))) (EVar "c")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "sliceClamped")) (PList (PVar "lo") (PVar "hi") (PVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "sliceClamped"))) (EVar "c")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" (PWild PWild PWild) (EListLit))
(DTypeSig false "containerUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Form") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))))
(DFunDef false "containerUse" ((PVar "loc") (PVar "form") (PVar "callee") (PVar "c") (PVar "bounds")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Use") (EVar "loc")) (EVar "form")) (EVar "callee")) (EVar "v")) (EVar "bounds")))) (arm PWild () (EListLit))))
(DTypeSig false "wholeParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "wholeParams" ((PVar "ps")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PCon "PVar" (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))) (clause ((PVar "i") (PCons (PCon "PAs" (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "ps"))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileFacts") (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PVar "facts") (PVar "types") (PVar "fallback") (PTuple (PAs "owner" (PCon "Owner" PWild (PVar "ps") PWild)) (PVar "body"))) (EMatch (EApp (EVar "wholeParams") (EVar "ps")) (arm (PList) () (EListLit)) (arm (PVar "params") () (EMatch (EApp (EApp (EVar "candidates") (EVar "params")) (EApp (EApp (EVar "usesIn") (EVar "None")) (EVar "body"))) (arm (PList) () (EListLit)) (arm (PVar "uses") () (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "owner")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "advancing") (EApp (EApp (EVar "advancingNames") (EVar "ps")) (EVar "calls"))) (DoExpr (EApp (EVar "dedupe") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "useFinding") (EVar "types")) (EVar "fallback")) (EVar "params")) (EVar "calls")) (EVar "advancing"))) (EVar "uses"))))))))))))
(DTypeSig false "candidates" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "candidates" ((PVar "params")) (EApp (EVar "filter") (ELam ((PCon "Use" PWild PWild PWild (PVar "v") PWild)) (EApp (EApp (EVar "any") (ELam ((PTuple (PVar "n") PWild)) (EBinOp "==" (EVar "n") (EVar "v")))) (EVar "params")))))
(DTypeSig false "passedUnchanged" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "passedUnchanged" ((PVar "calls") (PVar "i")) (ELetGroup ((lgb "rolesAt" (clause ((PVar "k") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EBinOp "==" (EApp (EApp (EVar "get") (EVar "k")) (EVar "roles")) (EApp (EVar "Some") (EApp (EVar "Unchanged") (EVar "k"))))))) (EApp (EApp (EVar "all") (EApp (EVar "rolesAt") (EVar "i"))) (EVar "calls"))))
(DTypeSig false "advancingNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "advancingNames" ((PVar "ps") (PVar "calls")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "p") (PVar "rest"))) (EIf (EApp (EApp (EVar "any") (EApp (EVar "advancesAt") (EVar "i"))) (EVar "calls")) (EBinOp "++" (EApp (EVar "patBoundNames") (EVar "p")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))) (lgb "advancesAt" (clause ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Advanced" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "ps"))))
(DTypeSig false "useFinding" (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Use") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "useFinding" ((PVar "types") (PVar "fallback") (PVar "params") (PVar "calls") (PVar "advancing") (PCon "Use" (PVar "loc") (PVar "form") (PVar "callee") (PVar "v") (PVar "bounds"))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "paramPos") (EVar "v"))) (EVar "params")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "passedUnchanged") (EVar "calls")) (EVar "i")) (EApp (EApp (EVar "any") (ELam ((PVar "b")) (EApp (EApp (EVar "any") (ELam ((PVar "n")) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "b")))) (EVar "advancing")))) (EVar "bounds"))) (EApp (EApp (EApp (EVar "formApplies") (EVar "types")) (EVar "form")) (EVar "i"))) (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (EApp (EApp (EApp (EApp (EVar "message") (EVar "form")) (EVar "callee")) (EVar "v")) (EApp (EVar "types") (EVar "i"))))) (EListLit)))))
(DTypeSig false "paramPos" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramPos" ((PVar "v") (PTuple (PVar "n") (PVar "i"))) (EIf (EBinOp "==" (EVar "n") (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "formApplies" (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Form") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "formApplies" (PWild (PCon "Extern") PWild) (EVar "True"))
(DFunDef false "formApplies" ((PVar "types") (PCon "Polymorphic") (PVar "i")) (EMatch (EApp (EVar "types") (EVar "i")) (arm (PCon "Some" (PLit (LString "String"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Array"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Bytes"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "dedupe" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dedupe" () (EApp (EVar "nubBy") (EVar "sameSpan")))
(DTypeSig false "sameSpan" (TyFun (TyCon "Finding") (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "sameSpan" ((PRec "Finding" ((rf "loc" (PVar "a"))) true) (PRec "Finding" ((rf "loc" (PVar "b"))) true)) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "msg")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameResliceInLoop")) (fa "message" (EVar "msg")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "noFix")))))
(DTypeSig false "message" (TyFun (TyCon "Form") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "message" ((PVar "form") (PVar "callee") (PVar "v") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "$core.display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "`, which the loop passes on unchanged while another argument advances, starts from the front of `"))) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` on every step. "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "costNote") (EVar "form")) (EVar "ty")))) (ELit (LString " "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "fixTarget") (EVar "form")) (EVar "ty")))) (ELit (LString ""))))
(DTypeSig false "costNote" (TyFun (TyCon "Form") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "costNote" ((PCon "Extern") PWild) (EVar "stringCost"))
(DFunDef false "costNote" ((PCon "Polymorphic") (PCon "Some" (PLit (LString "String")))) (EVar "stringCost"))
(DFunDef false "costNote" ((PCon "Polymorphic") PWild) (ELit (LString "The loop is quadratic.")))
(DTypeSig false "stringCost" (TyCon "String"))
(DFunDef false "stringCost" () (ELit (LString "The loop is quadratic on the WasmGC engine and, on the native runtime, when it alternates between strings, goes backward or slices the tail.")))
(DTypeSig false "fixTarget" (TyFun (TyCon "Form") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "fixTarget" ((PCon "Extern") PWild) (EVar "stringFix"))
(DFunDef false "fixTarget" ((PCon "Polymorphic") (PCon "Some" (PLit (LString "String")))) (EVar "stringFix"))
(DFunDef false "fixTarget" ((PCon "Polymorphic") PWild) (ELit (LString "Keep the offset and index the value (`a.[i]`) instead of slicing it again")))
(DTypeSig false "stringFix" (TyCon "String"))
(DFunDef false "stringFix" () (ELit (LString "Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert with `toChars` once and index the `Array`")))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true) (mem "orElseLoc" false) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "nubBy" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "firstLoc" false) (mem "mentionsVar" false) (mem "ruleNameResliceInLoop" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameResliceInLoop")) (fa "summary" (ELit (LString "a loop parameter re-sliced from its start on every step: quadratic on some engines and access patterns. Walk a `StrCursor`, or convert with `toChars` once"))) (fa "doc" (ELit (LString "A self-recursive loop that passes a `String`, `Array` or `Bytes` parameter on unchanged while another argument advances, and slices that parameter by the advancing index, starts from the front of the parameter on every step. The rule reports the String externs `stringSlice` and `charAtStr` on such a parameter, and `slice`, `sliceClamped`, `drop` and `a.[lo..hi]` on a parameter whose declared type, in the enclosing top-level signature, is `String`, `Array` or `Bytes`. A `List` parameter is skipped (`drop` on a list is the loop itself), and so is a slice whose bounds mention no advancing name. A partial application and a call to a different function (mutual recursion) are not self-calls. `stringSliceBytes` is not reported: it copies only the piece and does not walk the string.\n\nFor a `String`, `stringSlice` and `charAtStr` locate their offset from the front of the string. On the native runtime a forward scan of one string is linear, because the runtime keeps a cursor cache for one string; the loop is quadratic when it alternates between two strings, goes backward or slices the tail, and on the WasmGC engine, which has no cache, even a forward scan is quadratic. Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert once with `toChars` and index the `Array`. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-reslice-in-loop` with the bound as its reason.\n\nBefore:\n  go s i = if i < stringLength s then stringSlice i (i + 1) s :: go s (i + 1) else []\nAfter:\n  go cs i = if i < length cs then cs.[i] :: go cs (i + 1) else []  -- with `cs = toChars s`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleReslice")) (EVar "None")))
(DTypeSig false "ruleReslice" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleReslice" (PWild PWild (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "facts")) (EVar "decls"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "facts")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "stringSlice")) (ELit (LString "charAtStr")) (ELit (LString "slice")) (ELit (LString "drop")) (ELit (LString ".["))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "facts") (PVar "decls") (PVar "ctx") (PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "bodyFindings") (EVar "facts")) (EVar "decls")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "bodyFindings" ((PVar "facts") (PVar "decls") (PVar "fallback") (PCon "DeclBody" (PVar "owner") (PVar "body"))) (EMatch (EApp (EVar "ownerOf") (EVar "owner")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name"))) () (EApp (EApp (EApp (EApp (EVar "ownerFindings") (EVar "facts")) (ELam ((PVar "i")) (EApp (EApp (EVar "get") (EVar "i")) (EApp (EApp (EVar "sigDomains") (EVar "decls")) (EVar "name"))))) (EVar "fallback")) (ETuple (EVar "o") (EVar "body")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownerOf" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "Option") (TyTuple (TyCon "Owner") (TyCon "String")))))
(DFunDef false "ownerOf" ((PCon "OwnerClause" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None")) (EVar "name"))))
(DFunDef false "ownerOf" ((PCon "OwnerImplMethod" PWild PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerIfaceDefault" PWild PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerLetGroup" PWild PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerTest" PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerProp" PWild PWild)) (EVar "None"))
(DTypeSig false "localFindings" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "facts") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "facts")) (ELam (PWild) (EVar "None"))) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "letOwners") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sigDomains" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sigDomains" ((PVar "decls") (PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "findMap") (EApp (EVar "sigOf") (EVar "name"))) (EVar "decls"))))
(DTypeSig false "sigOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigOf" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "t") PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EApp (EVar "domains") (EVar "t"))) (EVar "None")))
(DFunDef false "sigOf" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigOf") (EVar "name")) (EVar "d")))
(DFunDef false "sigOf" (PWild PWild) (EVar "None"))
(DTypeSig false "domains" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "domains" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "domains") (EVar "t")))
(DFunDef false "domains" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EApp (EVar "headOf") (EVar "a")) (EApp (EVar "domains") (EVar "b"))))
(DFunDef false "domains" (PWild) (EListLit))
(DTypeSig false "headOf" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "headOf" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "lastSegment") (EVar "n")))
(DFunDef false "headOf" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headOf") (EVar "f")))
(DFunDef false "headOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "headOf") (EVar "t")))
(DFunDef false "headOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "headOf") (EVar "t")))
(DFunDef false "headOf" (PWild) (ELit (LString "")))
(DData Private "Form" () ((variant "Extern" (ConPos)) (variant "Polymorphic" (ConPos))) ())
(DData Private "Use" () ((variant "Use" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Form") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr"))))) ())
(DTypeSig false "usesIn" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "usesIn" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "usesIn") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "usesIn" ((PVar "loc") (PCon "ELetGroup" PWild (PVar "body"))) (EApp (EApp (EVar "usesIn") (EVar "loc")) (EVar "body")))
(DFunDef false "usesIn" ((PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "useHere") (EVar "loc")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "usesIn") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "useHere" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "useHere" ((PVar "loc") (PCon "EApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callUse") (EVar "loc")) (EVar "hd")) (EVar "args")))))
(DFunDef false "useHere" ((PVar "loc") (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callUse") (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))))))
(DFunDef false "useHere" ((PVar "loc") (PCon "ESlice" (PVar "c") (PVar "lo") (PVar "hi") PWild)) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Use") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "c"))) (EVar "loc"))) (EVar "Polymorphic")) (ELit (LString "a.[..]"))) (EVar "v")) (EListLit (EVar "lo") (EVar "hi"))))) (arm PWild () (EListLit))))
(DFunDef false "useHere" (PWild PWild) (EListLit))
(DTypeSig false "callUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))
(DFunDef false "callUse" ((PVar "loc") (PVar "hd") (PVar "args")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EApp (EVar "calleeUse") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EApp (EVar "lastSegment") (EVar "n"))) (EVar "args"))) (arm PWild () (EListLit))))
(DTypeSig false "calleeUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "stringSlice")) (PList (PVar "lo") (PVar "hi") (PVar "s"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Extern")) (ELit (LString "stringSlice"))) (EVar "s")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "charAtStr")) (PList (PVar "s") (PVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Extern")) (ELit (LString "charAtStr"))) (EVar "s")) (EListLit (EVar "i"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "drop")) (PList (PVar "n") (PVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "drop"))) (EVar "c")) (EListLit (EVar "n"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "slice")) (PList (PVar "c") (PVar "lo") (PVar "hi"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "slice"))) (EVar "c")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" ((PVar "loc") (PLit (LString "sliceClamped")) (PList (PVar "lo") (PVar "hi") (PVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "containerUse") (EVar "loc")) (EVar "Polymorphic")) (ELit (LString "sliceClamped"))) (EVar "c")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "calleeUse" (PWild PWild PWild) (EListLit))
(DTypeSig false "containerUse" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Form") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Use"))))))))
(DFunDef false "containerUse" ((PVar "loc") (PVar "form") (PVar "callee") (PVar "c") (PVar "bounds")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Use") (EVar "loc")) (EVar "form")) (EVar "callee")) (EVar "v")) (EVar "bounds")))) (arm PWild () (EListLit))))
(DTypeSig false "wholeParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "wholeParams" ((PVar "ps")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PCon "PVar" (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))) (clause ((PVar "i") (PCons (PCon "PAs" (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "ps"))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileFacts") (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PVar "facts") (PVar "types") (PVar "fallback") (PTuple (PAs "owner" (PCon "Owner" PWild (PVar "ps") PWild)) (PVar "body"))) (EMatch (EApp (EVar "wholeParams") (EVar "ps")) (arm (PList) () (EListLit)) (arm (PVar "params") () (EMatch (EApp (EApp (EVar "candidates") (EVar "params")) (EApp (EApp (EVar "usesIn") (EVar "None")) (EVar "body"))) (arm (PList) () (EListLit)) (arm (PVar "uses") () (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "owner")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "advancing") (EApp (EApp (EVar "advancingNames") (EVar "ps")) (EVar "calls"))) (DoExpr (EApp (EVar "dedupe") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "useFinding") (EVar "types")) (EVar "fallback")) (EVar "params")) (EVar "calls")) (EVar "advancing"))) (EVar "uses"))))))))))))
(DTypeSig false "candidates" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyApp (TyCon "List") (TyCon "Use")))))
(DFunDef false "candidates" ((PVar "params")) (EApp (EMethodRef "filter") (ELam ((PCon "Use" PWild PWild PWild (PVar "v") PWild)) (EApp (EApp (EDictApp "any") (ELam ((PTuple (PVar "n") PWild)) (EBinOp "==" (EVar "n") (EVar "v")))) (EVar "params")))))
(DTypeSig false "passedUnchanged" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "passedUnchanged" ((PVar "calls") (PVar "i")) (ELetGroup ((lgb "rolesAt" (clause ((PVar "k") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EBinOp "==" (EApp (EApp (EVar "get") (EVar "k")) (EVar "roles")) (EApp (EVar "Some") (EApp (EVar "Unchanged") (EVar "k"))))))) (EApp (EApp (EDictApp "all") (EApp (EVar "rolesAt") (EVar "i"))) (EVar "calls"))))
(DTypeSig false "advancingNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "advancingNames" ((PVar "ps") (PVar "calls")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "p") (PVar "rest"))) (EIf (EApp (EApp (EDictApp "any") (EApp (EVar "advancesAt") (EVar "i"))) (EVar "calls")) (EBinOp "++" (EApp (EVar "patBoundNames") (EVar "p")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))) (lgb "advancesAt" (clause ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Advanced" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "ps"))))
(DTypeSig false "useFinding" (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Use") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "useFinding" ((PVar "types") (PVar "fallback") (PVar "params") (PVar "calls") (PVar "advancing") (PCon "Use" (PVar "loc") (PVar "form") (PVar "callee") (PVar "v") (PVar "bounds"))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "paramPos") (EVar "v"))) (EVar "params")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "passedUnchanged") (EVar "calls")) (EVar "i")) (EApp (EApp (EDictApp "any") (ELam ((PVar "b")) (EApp (EApp (EDictApp "any") (ELam ((PVar "n")) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "b")))) (EVar "advancing")))) (EVar "bounds"))) (EApp (EApp (EApp (EVar "formApplies") (EVar "types")) (EVar "form")) (EVar "i"))) (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (EApp (EApp (EApp (EApp (EVar "message") (EVar "form")) (EVar "callee")) (EVar "v")) (EApp (EVar "types") (EVar "i"))))) (EListLit)))))
(DTypeSig false "paramPos" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramPos" ((PVar "v") (PTuple (PVar "n") (PVar "i"))) (EIf (EBinOp "==" (EVar "n") (EVar "v")) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "formApplies" (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Form") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "formApplies" (PWild (PCon "Extern") PWild) (EVar "True"))
(DFunDef false "formApplies" ((PVar "types") (PCon "Polymorphic") (PVar "i")) (EMatch (EApp (EVar "types") (EVar "i")) (arm (PCon "Some" (PLit (LString "String"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Array"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Bytes"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "dedupe" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dedupe" () (EApp (EVar "nubBy") (EVar "sameSpan")))
(DTypeSig false "sameSpan" (TyFun (TyCon "Finding") (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "sameSpan" ((PRec "Finding" ((rf "loc" (PVar "a"))) true) (PRec "Finding" ((rf "loc" (PVar "b"))) true)) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "msg")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameResliceInLoop")) (fa "message" (EVar "msg")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "noFix")))))
(DTypeSig false "message" (TyFun (TyCon "Form") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "message" ((PVar "form") (PVar "callee") (PVar "v") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "$core.display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "`, which the loop passes on unchanged while another argument advances, starts from the front of `"))) (EApp (EVar "$core.display") (EVar "v"))) (ELit (LString "` on every step. "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "costNote") (EVar "form")) (EVar "ty")))) (ELit (LString " "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "fixTarget") (EVar "form")) (EVar "ty")))) (ELit (LString ""))))
(DTypeSig false "costNote" (TyFun (TyCon "Form") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "costNote" ((PCon "Extern") PWild) (EVar "stringCost"))
(DFunDef false "costNote" ((PCon "Polymorphic") (PCon "Some" (PLit (LString "String")))) (EVar "stringCost"))
(DFunDef false "costNote" ((PCon "Polymorphic") PWild) (ELit (LString "The loop is quadratic.")))
(DTypeSig false "stringCost" (TyCon "String"))
(DFunDef false "stringCost" () (ELit (LString "The loop is quadratic on the WasmGC engine and, on the native runtime, when it alternates between strings, goes backward or slices the tail.")))
(DTypeSig false "fixTarget" (TyFun (TyCon "Form") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "fixTarget" ((PCon "Extern") PWild) (EVar "stringFix"))
(DFunDef false "fixTarget" ((PCon "Polymorphic") (PCon "Some" (PLit (LString "String")))) (EVar "stringFix"))
(DFunDef false "fixTarget" ((PCon "Polymorphic") PWild) (ELit (LString "Keep the offset and index the value (`a.[i]`) instead of slicing it again")))
(DTypeSig false "stringFix" (TyCon "String"))
(DFunDef false "stringFix" () (ELit (LString "Walk a `StrCursor` (`startCursor`, `nextChar`, `sliceBetween`), or convert with `toChars` once and index the `Array`")))
