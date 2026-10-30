# META
source_lines=140
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-clone-type: a two-constructor `data` with Option's or Result's arities and no `impl`. Prefer the stdlib type.

-- ── rule: clone-type (#2566) ─────────────────────────────────────────
-- The TYPE-level analogue of `rule-stdlib-reimpl`: a two-constructor `data`
-- whose constructor arities are exactly `Option`'s (`None | Some a` -- 0 then 1)
-- or `Result`'s (`Err e | Ok a` -- 1 and 1), declared in a file that writes no
-- `impl` for it.  Such a type re-declares a prelude shape while getting none of
-- the prelude's combinators, so every consumer hand-rolls `map`/`andThen`/
-- `orElse`/`withDefault` at each use site.
--
-- Both conjuncts are SYNTACTIC, because the linter has no type environment: the
-- arity signature read off `dataCtors`, and the absence of a `DImpl` in the SAME
-- file whose target type head is this type's name.  A `deriving (Eq, Ord, Debug)`
-- clause is deliberately not counted as an impl -- a derived structural instance
-- is not the combinator API this rule is about, so a derived-only type is still
-- as impl-less as a bare one for this purpose.
--
-- Arity cannot separate a clone from a two-variant DOMAIN sum that lands on the
-- same shape by coincidence (`SExp = SAtom String | SList (List SExp)` is
-- atom-vs-list, not failure-vs-success), and no syntactic test can: the
-- difference is what the variants MEAN.  A declaration a human has ruled on for
-- exactly that reason carries a `-- lint-disable-next-line rule-clone-type`
-- directly above it, so the exclusion sits at the declaration it exonerates and
-- binds to THAT declaration alone; a global list of names would exclude every
-- like-named type anywhere in the tree, including ones nobody has read.

import frontend.ast.{Loc(..), Ty(..), Variant(..), ConPayload(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains, listLen}
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
  declLocList,
  ruleNameCloneType,
  tyHeadName,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameCloneType,
      summary =
        "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)",
      doc =
        "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleCloneType
    None

-- payload width of one constructor: positional arity, or field count for a
-- record-style payload.
cloneCtorArity : Variant -> Int
cloneCtorArity (Variant _ (ConPos ts)) = listLen ts
cloneCtorArity (Variant _ (ConNamed fs _)) = listLen fs

-- the prelude type these constructors clone, if any.  Either arm order counts:
-- `Some a | None` is the same shape as `None | Some a`.
cloneShapeName : List Variant -> Option String
cloneShapeName [a, b] =
  cloneShapeOfArities (cloneCtorArity a) (cloneCtorArity b)
cloneShapeName _ = None

cloneShapeOfArities : Int -> Int -> Option String
cloneShapeOfArities x y
  | x == 1 && y == 1 = Some "Result"
  | x + y == 1 = Some "Option"
  | otherwise = None

-- head names of every type this file writes an `impl` for.
cloneImplTargets : List Decl -> List String
cloneImplTargets ds = flatMap cloneImplTargetsOf ds

cloneImplTargetsOf : Decl -> List String
cloneImplTargetsOf (DImpl { tys, ... }) = flatMap cloneTyHeadList tys
cloneImplTargetsOf (DAttrib _ d) = cloneImplTargetsOf d
cloneImplTargetsOf _ = []

cloneTyHeadList : Ty -> List String
cloneTyHeadList t = match tyHeadName t
  Some n => [n]
  None => []

ruleCloneType : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleCloneType _ _ _ pos prog =
  let impls = cloneImplTargets prog
  flatMap (cloneTypeDeclL impls) (declLocList pos prog)

cloneTypeDeclL : List String -> (Decl, Option Loc) -> List Finding
cloneTypeDeclL impls (d, loc) = cloneTypeDecl impls loc d

cloneTypeDecl : List String -> Option Loc -> Decl -> List Finding
cloneTypeDecl impls loc (DData { dataName, dataCtors, ... }) =
  cloneTypeHit impls loc dataName dataCtors
cloneTypeDecl impls loc (DAttrib _ d) = cloneTypeDecl impls loc d
cloneTypeDecl _ _ _ = []

cloneTypeHit : List String ->
  Option Loc ->
  String ->
  List Variant ->
  List Finding
cloneTypeHit impls loc n ctors
  | contains n impls = []
  | otherwise = match cloneShapeName ctors
    Some shape => [cloneTypeFinding loc n shape]
    None => []

cloneTypeFinding : Option Loc -> String -> String -> Finding
cloneTypeFinding loc n shape = Finding {
  rule = ruleNameCloneType,
  message =
    "'\{n}' re-declares `\{shape}`'s constructor shape and its file writes no `impl` for it -- prefer the stdlib `\{shape}`, whose combinators come with it",
  severity = SevWarning,
  loc = loc,
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "ruleNameCloneType" false) (mem "tyHeadName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCloneType")) (fa "summary" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "doc" (ELit (LString "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleCloneType")) (EVar "None")))
(DTypeSig false "cloneCtorArity" (TyFun (TyCon "Variant") (TyCon "Int")))
(DFunDef false "cloneCtorArity" ((PCon "Variant" PWild (PCon "ConPos" (PVar "ts")))) (EApp (EVar "listLen") (EVar "ts")))
(DFunDef false "cloneCtorArity" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "cloneShapeName" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "cloneShapeName" ((PList (PVar "a") (PVar "b"))) (EApp (EApp (EVar "cloneShapeOfArities") (EApp (EVar "cloneCtorArity") (EVar "a"))) (EApp (EVar "cloneCtorArity") (EVar "b"))))
(DFunDef false "cloneShapeName" (PWild) (EVar "None"))
(DTypeSig false "cloneShapeOfArities" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "cloneShapeOfArities" ((PVar "x") (PVar "y")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LInt 1))) (EBinOp "==" (EVar "y") (ELit (LInt 1)))) (EApp (EVar "Some") (ELit (LString "Result"))) (EIf (EBinOp "==" (EBinOp "+" (EVar "x") (EVar "y")) (ELit (LInt 1))) (EApp (EVar "Some") (ELit (LString "Option"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cloneImplTargets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneImplTargets" ((PVar "ds")) (EApp (EApp (EVar "flatMap") (EVar "cloneImplTargetsOf")) (EVar "ds")))
(DTypeSig false "cloneImplTargetsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneImplTargetsOf" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "cloneTyHeadList")) (EVar "tys")))
(DFunDef false "cloneImplTargetsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "cloneImplTargetsOf") (EVar "d")))
(DFunDef false "cloneImplTargetsOf" (PWild) (EListLit))
(DTypeSig false "cloneTyHeadList" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneTyHeadList" ((PVar "t")) (EMatch (EApp (EVar "tyHeadName") (EVar "t")) (arm (PCon "Some" (PVar "n")) () (EListLit (EVar "n"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ruleCloneType" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleCloneType" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "impls") (EApp (EVar "cloneImplTargets") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "cloneTypeDeclL") (EVar "impls"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "cloneTypeDeclL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "cloneTypeDeclL" ((PVar "impls") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "cloneTypeDecl") (EVar "impls")) (EVar "loc")) (EVar "d")))
(DTypeSig false "cloneTypeDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "cloneTypeDecl" ((PVar "impls") (PVar "loc") (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None)) true)) (EApp (EApp (EApp (EApp (EVar "cloneTypeHit") (EVar "impls")) (EVar "loc")) (EVar "dataName")) (EVar "dataCtors")))
(DFunDef false "cloneTypeDecl" ((PVar "impls") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "cloneTypeDecl") (EVar "impls")) (EVar "loc")) (EVar "d")))
(DFunDef false "cloneTypeDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "cloneTypeHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "cloneTypeHit" ((PVar "impls") (PVar "loc") (PVar "n") (PVar "ctors")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "impls")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "cloneShapeName") (EVar "ctors")) (arm (PCon "Some" (PVar "shape")) () (EListLit (EApp (EApp (EApp (EVar "cloneTypeFinding") (EVar "loc")) (EVar "n")) (EVar "shape")))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cloneTypeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Finding")))))
(DFunDef false "cloneTypeFinding" ((PVar "loc") (PVar "n") (PVar "shape")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameCloneType")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' re-declares `"))) (EApp (EVar "display") (EVar "shape"))) (ELit (LString "`'s constructor shape and its file writes no `impl` for it -- prefer the stdlib `"))) (EApp (EVar "display") (EVar "shape"))) (ELit (LString "`, whose combinators come with it")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "ruleNameCloneType" false) (mem "tyHeadName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCloneType")) (fa "summary" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "doc" (ELit (LString "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleCloneType")) (EVar "None")))
(DTypeSig false "cloneCtorArity" (TyFun (TyCon "Variant") (TyCon "Int")))
(DFunDef false "cloneCtorArity" ((PCon "Variant" PWild (PCon "ConPos" (PVar "ts")))) (EApp (EVar "listLen") (EVar "ts")))
(DFunDef false "cloneCtorArity" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "cloneShapeName" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "cloneShapeName" ((PList (PVar "a") (PVar "b"))) (EApp (EApp (EVar "cloneShapeOfArities") (EApp (EVar "cloneCtorArity") (EVar "a"))) (EApp (EVar "cloneCtorArity") (EVar "b"))))
(DFunDef false "cloneShapeName" (PWild) (EVar "None"))
(DTypeSig false "cloneShapeOfArities" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "cloneShapeOfArities" ((PVar "x") (PVar "y")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LInt 1))) (EBinOp "==" (EVar "y") (ELit (LInt 1)))) (EApp (EVar "Some") (ELit (LString "Result"))) (EIf (EBinOp "==" (EBinOp "+" (EVar "x") (EVar "y")) (ELit (LInt 1))) (EApp (EVar "Some") (ELit (LString "Option"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cloneImplTargets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneImplTargets" ((PVar "ds")) (EApp (EApp (EDictApp "flatMap") (EVar "cloneImplTargetsOf")) (EVar "ds")))
(DTypeSig false "cloneImplTargetsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneImplTargetsOf" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "cloneTyHeadList")) (EVar "tys")))
(DFunDef false "cloneImplTargetsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "cloneImplTargetsOf") (EVar "d")))
(DFunDef false "cloneImplTargetsOf" (PWild) (EListLit))
(DTypeSig false "cloneTyHeadList" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cloneTyHeadList" ((PVar "t")) (EMatch (EApp (EVar "tyHeadName") (EVar "t")) (arm (PCon "Some" (PVar "n")) () (EListLit (EVar "n"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ruleCloneType" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleCloneType" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "impls") (EApp (EVar "cloneImplTargets") (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "cloneTypeDeclL") (EVar "impls"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "cloneTypeDeclL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "cloneTypeDeclL" ((PVar "impls") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "cloneTypeDecl") (EVar "impls")) (EVar "loc")) (EVar "d")))
(DTypeSig false "cloneTypeDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "cloneTypeDecl" ((PVar "impls") (PVar "loc") (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None)) true)) (EApp (EApp (EApp (EApp (EVar "cloneTypeHit") (EVar "impls")) (EVar "loc")) (EVar "dataName")) (EVar "dataCtors")))
(DFunDef false "cloneTypeDecl" ((PVar "impls") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "cloneTypeDecl") (EVar "impls")) (EVar "loc")) (EVar "d")))
(DFunDef false "cloneTypeDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "cloneTypeHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "cloneTypeHit" ((PVar "impls") (PVar "loc") (PVar "n") (PVar "ctors")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "impls")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "cloneShapeName") (EVar "ctors")) (arm (PCon "Some" (PVar "shape")) () (EListLit (EApp (EApp (EApp (EVar "cloneTypeFinding") (EVar "loc")) (EVar "n")) (EVar "shape")))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cloneTypeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Finding")))))
(DFunDef false "cloneTypeFinding" ((PVar "loc") (PVar "n") (PVar "shape")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameCloneType")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' re-declares `"))) (EApp (EMethodRef "display") (EVar "shape"))) (ELit (LString "`'s constructor shape and its file writes no `impl` for it -- prefer the stdlib `"))) (EApp (EMethodRef "display") (EVar "shape"))) (ELit (LString "`, whose combinators come with it")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
