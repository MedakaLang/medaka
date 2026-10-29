# META
source_lines=118
stages=DESUGAR,MARK
# SOURCE
-- lint rule hand-rolled-derivable: hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6).

import frontend.ast.{Ns(..), TabKey(..), Loc(..), Ty(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains}
import frontend.exhaust.{Oracle, oGetCtors}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex(..),
  mkRule,
  factOracle,
}
import tools.lint_shared.{
  declLocList,
  isStdlibPath,
  ruleNameDerivable,
  tyHeadName,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameDerivable,
      summary =
        "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)",
      doc =
        "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDerivable
    None

-- ── rule: hand-rolled-derivable (STYLE §6) ────────────────────────────────────
-- A `DImpl` for Eq/Ord/Debug over a single named (TyCon-headed) type.  DImpl
-- carries no loc, so loc = None.
derivableIfaces : List String
derivableIfaces = ["Eq", "Ord", "Debug"]

-- Skip stdlib-owned files entirely: every hand-written `impl Eq/Ord/Debug` in
-- the stdlib is legitimate (a primitive with no `data` decl to derive from, the
-- `Ordering` Eq-ctor/Eq-class clash, a non-structural container instance whose
-- `deriving` would be semantically WRONG, or a bootstrap-prelude type).  For
-- USER code we additionally require the type to have a `data`/`record`
-- declaration whose constructors are visible in the linted file (`oGetCtors`
-- returns `Some`) — a primitive has none, so `impl Eq for Int` is never flagged.
ruleDerivable : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleDerivable _ path facts pos prog
  | isStdlibPath path = []
  | otherwise =
    let orc = factOracle facts
    flatMap (derivableDeclL orc) (declLocList pos prog)

derivableDeclL : Oracle -> (Decl, Option Loc) -> List Finding
derivableDeclL orc (d, loc) = derivableDecl orc loc d

derivableDecl : Oracle -> Option Loc -> Decl -> List Finding
derivableDecl orc loc (DImpl { iface, tys, ... }) =
  derivableHit orc loc iface tys
derivableDecl orc loc (DAttrib _ d) = derivableDecl orc loc d
derivableDecl _ _ _ = []

derivableHit : Oracle -> Option Loc -> String -> List Ty -> List Finding
derivableHit orc loc iface tys
  | contains iface derivableIfaces = match singleNamedType tys
    Some tyName =>
      if hasUserDataDecl orc tyName then
        [
          Finding {
            rule = ruleNameDerivable,
            message =
              "hand-written `impl \{iface}` for '\{tyName}' — use `deriving (\{iface})`",
            severity = SevWarning,
            loc = loc,
          },
        ]
      else
        []
    None => []
  | otherwise = []

-- the type has a `data`/`record` declaration (with constructors) visible in the
-- linted file — so `deriving` is actually available for it.  Primitive types
-- (Int/Float/Bool/String/Char/Unit/Array) have no such decl → `oGetCtors` = None.
-- ⚠️ This oracle is built from ONE file's raw decls with no identity-stamping
-- pass in the loop, so the key is bare BY CONSTRUCTION on both the write and
-- read side — `TkBare NsType tyName` directly, rather than routed through
-- `tabKeyOf`'s origin dance (which would land in the same place, since
-- `mkIdent _ OriginUnresolved _ = None`, but naming it directly keeps this
-- module out of the #1110 OriginUnresolved ratchet).
hasUserDataDecl : Oracle -> String -> Bool
hasUserDataDecl orc tyName = match oGetCtors orc (TkBare NsType tyName)
  Some _ => True
  None => False

-- the head type name iff `tys` is exactly one TyCon-headed type
singleNamedType : List Ty -> Option String
singleNamedType [t] = tyHeadName t
singleNamedType _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "TabKey" true) (mem "Loc" true) (mem "Ty" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "oGetCtors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "isStdlibPath" false) (mem "ruleNameDerivable" false) (mem "tyHeadName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDerivable")) (fa "summary" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "doc" (ELit (LString "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDerivable")) (EVar "None")))
(DTypeSig false "derivableIfaces" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "derivableIfaces" () (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug"))))
(DTypeSig false "ruleDerivable" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDerivable" (PWild (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "derivableDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivableDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "derivableDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DTypeSig false "derivableDecl" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PRec "DImpl" ((rf "iface" None) (rf "tys" None)) true)) (EApp (EApp (EApp (EApp (EVar "derivableHit") (EVar "orc")) (EVar "loc")) (EVar "iface")) (EVar "tys")))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DFunDef false "derivableDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "derivableHit" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "derivableHit" ((PVar "orc") (PVar "loc") (PVar "iface") (PVar "tys")) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "derivableIfaces")) (EMatch (EApp (EVar "singleNamedType") (EVar "tys")) (arm (PCon "Some" (PVar "tyName")) () (EIf (EApp (EApp (EVar "hasUserDataDecl") (EVar "orc")) (EVar "tyName")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDerivable")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hand-written `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` for '"))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString "' — use `deriving ("))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ")`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit))) (arm (PCon "None") () (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasUserDataDecl" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasUserDataDecl" ((PVar "orc") (PVar "tyName")) (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "tyName"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "singleNamedType" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "singleNamedType" ((PList (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "singleNamedType" (PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "TabKey" true) (mem "Loc" true) (mem "Ty" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "oGetCtors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "isStdlibPath" false) (mem "ruleNameDerivable" false) (mem "tyHeadName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDerivable")) (fa "summary" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "doc" (ELit (LString "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDerivable")) (EVar "None")))
(DTypeSig false "derivableIfaces" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "derivableIfaces" () (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug"))))
(DTypeSig false "ruleDerivable" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDerivable" (PWild (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "derivableDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivableDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "derivableDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DTypeSig false "derivableDecl" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PRec "DImpl" ((rf "iface" None) (rf "tys" None)) true)) (EApp (EApp (EApp (EApp (EVar "derivableHit") (EVar "orc")) (EVar "loc")) (EVar "iface")) (EVar "tys")))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DFunDef false "derivableDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "derivableHit" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "derivableHit" ((PVar "orc") (PVar "loc") (PVar "iface") (PVar "tys")) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "derivableIfaces")) (EMatch (EApp (EVar "singleNamedType") (EVar "tys")) (arm (PCon "Some" (PVar "tyName")) () (EIf (EApp (EApp (EVar "hasUserDataDecl") (EVar "orc")) (EVar "tyName")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDerivable")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hand-written `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` for '"))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString "' — use `deriving ("))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ")`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit))) (arm (PCon "None") () (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasUserDataDecl" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasUserDataDecl" ((PVar "orc") (PVar "tyName")) (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EVar "tyName"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "singleNamedType" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "singleNamedType" ((PList (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "singleNamedType" (PWild) (EVar "None"))
