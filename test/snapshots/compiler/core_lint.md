# META
source_lines=186
stages=DESUGAR,MARK
# SOURCE
-- compiler/ir/core_lint.mdk — invariants of Core IR that hold after every pass
-- of every pass list, checked on a program value.
--
-- Three rules, one finding line each:
--   scope    every variable is bound by an enclosing pattern, lambda, `let`,
--            let-group, block statement or clause, or names a program-level
--            thing (a binding, constructor, impl entry, extern or runtime name,
--            the last being a name of the runtime ABI table);
--   spine    no application has an application as its head, and none is empty;
--   decision every leaf of a decision tree indexes an arm of its `CDecision`.
-- An extern symbol (`$extern$…`, `extern_lower.externVar`) names an extern the
-- program does not declare before `lower-externs`.
-- A variable's `Addr` is not read: a clause parameter carries `AGlobal`.

import ir.core_ir.{
  CArm(..),
  CBind(..),
  CClause(..),
  CExpr(..),
  CField(..),
  CGuard(..),
  CImplBody(..),
  CImplEntry(..),
  CProgram(..),
  CStmt(..),
  CTBranch(..),
  CTree(..),
  DeclFacts(..),
  siteSentinelName,
}
import ir.core_walk.{bindNames, bindPats, foldExpr, implName}
import list.{reverse}
import types.runtime_abi_data.{runtimeAbiRows}
import support.ordmap.{OrdMap, omEmpty, omFromNames, omHasKey, omKeys}
import support.util.{fallthroughName, startsWith}

-- One line per fault, empty when the program is clean.
export
lintProgram : CProgram -> List String
lintProgram (CProgram binds ctors _ impls _ facts) =
  let globals =
    omFromNames
      (bindNames binds
        ++ map fst ctors
        ++ map implName impls
        ++ omKeys facts.factExterns
        ++ builtinCtors
        ++ map fst runtimeAbiRows)
      omEmpty
  flatMap (lintBind globals) binds ++ flatMap (lintImpl globals) impls

-- Names a program reads without declaring them: the two constructors `Bool` has
-- without a `data` declaration, the trap-site sentinel a native lowering packs,
-- and the heads the checker wraps around a declared file bound.
builtinCtors : List String
builtinCtors = [
  "True",
  "False",
  siteSentinelName,
  "$withFileReadBound",
  "$withFileWriteBound",
]

lintBind : OrdMap Unit -> CBind -> List String
lintBind globals (CBind name clauses _ _) =
  flatMap (lintClause globals ("binding " ++ name)) clauses

lintClause : OrdMap Unit -> String -> CClause -> List String
lintClause globals where_ (CClause pats body) =
  lintBody globals (bindPats pats omEmpty) where_ body

lintImpl : OrdMap Unit -> CImplEntry -> List String
lintImpl globals (CImplEntry name _ _ (CImplTagged _ _ _ _ _ pats body)) =
  lintBody globals (bindPats pats omEmpty) ("impl " ++ name) body
lintImpl globals (CImplEntry name _ _ (CImplDefault _ _ _ _ _ pats body)) =
  lintBody globals (bindPats pats omEmpty) ("impl " ++ name) body

lintBody : OrdMap Unit -> OrdMap Unit -> String -> CExpr -> List String
lintBody globals scope where_ body =
  map
    (f => "\{where_}: \{f}")
    (scopeFaults globals scope body ++ shapeFaults body)

-- ── spine and decision shape: node-local, so one fold ───────────────────────
shapeFaults : CExpr -> List String
shapeFaults e = reverse (foldExpr shapeStep [] e)

shapeStep : List String -> CExpr -> List String
shapeStep acc (CApp (CApp _ _ _) _ _) =
  "application headed by an application" :: acc
shapeStep acc (CApp _ [] _) = "application with no arguments" :: acc
shapeStep acc (CDecision _ arms tree) =
  fold (addLeafFault (length arms)) acc (leafIndices tree)
shapeStep acc _ = acc

addLeafFault : Int -> List String -> Int -> List String
addLeafFault n acc i =
  if i < 0 || i >= n then "decision leaf \{i} outside \{n} arms" :: acc else acc

leafIndices : CTree -> List Int
leafIndices (CTFail _) = []
leafIndices (CTLeaf i) = [i]
leafIndices (CTGuard i rest) = i :: leafIndices rest
leafIndices (CTSwitch branches def) =
  flatMap branchLeaves branches ++ leafIndices def
leafIndices (CTDrop rest) = leafIndices rest

branchLeaves : CTBranch -> List Int
branchLeaves (CTBranch _ t) = leafIndices t

-- ── scope: binders scope, so this walk carries the names in scope ───────────
scopeFaults : OrdMap Unit -> OrdMap Unit -> CExpr -> List String
scopeFaults globals scope (CVar x _) =
  if x == fallthroughName
    || startsWith "$extern$" x
    || omHasKey x scope
    || omHasKey x globals then
    []
  else
    ["unbound variable \{x}"]
scopeFaults _ _ (CLit _) = []
scopeFaults g s (CApp h args _) = flatMap (scopeFaults g s) (h :: args)
scopeFaults g s (CLam pats body) = scopeFaults g (bindPats pats s) body
scopeFaults g s (CLet isRec pat rhs body) =
  let inner = bindPats [pat] s
  scopeFaults g (if isRec then inner else s) rhs ++ scopeFaults g inner body
scopeFaults g s (CLetGroup binds body) =
  let inner = omFromNames (bindNames binds) s
  flatMap (groupClauseFaults g inner) binds ++ scopeFaults g inner body
scopeFaults g s (CMatch scrut arms) =
  scopeFaults g s scrut ++ flatMap (armFaults g s) arms
scopeFaults g s (CDecision scrut arms _) =
  scopeFaults g s scrut ++ flatMap (armFaults g s) arms
scopeFaults g s (CIf c t e) = flatMap (scopeFaults g s) [c, t, e]
scopeFaults g s (CBinPrim _ l r _ _) = flatMap (scopeFaults g s) [l, r]
scopeFaults g s (CUnOp _ x) = scopeFaults g s x
scopeFaults g s (CTuple es) = flatMap (scopeFaults g s) es
scopeFaults g s (CList es) = flatMap (scopeFaults g s) es
scopeFaults g s (CRecord _ fields) = flatMap (fieldFaults g s) fields
scopeFaults g s (CFieldAccess x _ _ _) = scopeFaults g s x
scopeFaults g s (CRecordUpdate _ base fields) =
  scopeFaults g s base ++ flatMap (fieldFaults g s) fields
scopeFaults g s (CVariantUpdate _ base fields) =
  scopeFaults g s base ++ flatMap (fieldFaults g s) fields
scopeFaults g s (CArray es) = flatMap (scopeFaults g s) es
scopeFaults g s (CRangeList lo hi _) = flatMap (scopeFaults g s) [lo, hi]
scopeFaults g s (CRangeArray lo hi _) = flatMap (scopeFaults g s) [lo, hi]
scopeFaults g s (CBlock stmts) = blockFaults g s stmts
scopeFaults _ _ (CMethod _ _) = []
scopeFaults _ _ (CDict _ _) = []

fieldFaults : OrdMap Unit -> OrdMap Unit -> CField -> List String
fieldFaults g s (CField _ _ e) = scopeFaults g s e

groupClauseFaults : OrdMap Unit -> OrdMap Unit -> CBind -> List String
groupClauseFaults g s (CBind _ clauses _ _) =
  flatMap ((CClause pats body) => scopeFaults g (bindPats pats s) body) clauses

-- A guard's pattern binds for the guards after it and for the body.
armFaults : OrdMap Unit -> OrdMap Unit -> CArm -> List String
armFaults g s (CArm pat guards body) =
  let (faults, inner) = guardFaults g (bindPats [pat] s) guards
  faults ++ scopeFaults g inner body
armFaults g s (CArmAlt pat guards _) =
  fst (guardFaults g (bindPats [pat] s) guards)

guardFaults : OrdMap Unit ->
  OrdMap Unit ->
  List CGuard ->
  (List String, OrdMap Unit)
guardFaults _ s [] = ([], s)
guardFaults g s ((CGBool e) :: rest) =
  let (more, out) = guardFaults g s rest
  (scopeFaults g s e ++ more, out)
guardFaults g s ((CGBind p e) :: rest) =
  let (more, out) = guardFaults g (bindPats [p] s) rest
  (scopeFaults g s e ++ more, out)

blockFaults : OrdMap Unit -> OrdMap Unit -> List CStmt -> List String
blockFaults _ _ [] = []
blockFaults g s ((CSExpr e) :: rest) = scopeFaults g s e ++ blockFaults g s rest
blockFaults g s ((CSAssign _ e) :: rest) =
  scopeFaults g s e ++ blockFaults g s rest
blockFaults g s ((CSLet isRec pat e) :: rest) =
  let inner = bindPats [pat] s
  scopeFaults g (if isRec then inner else s) e ++ blockFaults g inner rest
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true) (mem "DeclFacts" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "bindNames" false) (mem "bindPats" false) (mem "foldExpr" false) (mem "implName" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "fallthroughName" false) (mem "startsWith" false))))
(DTypeSig true "lintProgram" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintProgram" ((PCon "CProgram" (PVar "binds") (PVar "ctors") PWild (PVar "impls") PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "globals") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ctors"))) (EApp (EApp (EVar "map") (EVar "implName")) (EVar "impls"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))) (EVar "builtinCtors")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "runtimeAbiRows")))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "lintBind") (EVar "globals"))) (EVar "binds")) (EApp (EApp (EVar "flatMap") (EApp (EVar "lintImpl") (EVar "globals"))) (EVar "impls"))))))
(DTypeSig false "builtinCtors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtinCtors" () (EListLit (ELit (LString "True")) (ELit (LString "False")) (EVar "siteSentinelName") (ELit (LString "$withFileReadBound")) (ELit (LString "$withFileWriteBound"))))
(DTypeSig false "lintBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintBind" ((PVar "globals") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "lintClause") (EVar "globals")) (EBinOp "++" (ELit (LString "binding ")) (EVar "name")))) (EVar "clauses")))
(DTypeSig false "lintClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lintClause" ((PVar "globals") (PVar "where_") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "where_")) (EVar "body")))
(DTypeSig false "lintImpl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintImpl" ((PVar "globals") (PCon "CImplEntry" (PVar "name") PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EBinOp "++" (ELit (LString "impl ")) (EVar "name"))) (EVar "body")))
(DFunDef false "lintImpl" ((PVar "globals") (PCon "CImplEntry" (PVar "name") PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EBinOp "++" (ELit (LString "impl ")) (EVar "name"))) (EVar "body")))
(DTypeSig false "lintBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "lintBody" ((PVar "globals") (PVar "scope") (PVar "where_") (PVar "body")) (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "where_"))) (ELit (LString ": "))) (EApp (EVar "$core.display") (EVar "f"))) (ELit (LString ""))))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "globals")) (EVar "scope")) (EVar "body")) (EApp (EVar "shapeFaults") (EVar "body")))))
(DTypeSig false "shapeFaults" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "shapeFaults" ((PVar "e")) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "foldExpr") (EVar "shapeStep")) (EListLit)) (EVar "e"))))
(DTypeSig false "shapeStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CApp" (PCon "CApp" PWild PWild PWild) PWild PWild)) (EBinOp "::" (ELit (LString "application headed by an application")) (EVar "acc")))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CApp" PWild (PList) PWild)) (EBinOp "::" (ELit (LString "application with no arguments")) (EVar "acc")))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CDecision" PWild (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "addLeafFault") (EApp (EVar "length") (EVar "arms")))) (EVar "acc")) (EApp (EVar "leafIndices") (EVar "tree"))))
(DFunDef false "shapeStep" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "addLeafFault" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "addLeafFault" ((PVar "n") (PVar "acc") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EVar "n"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "decision leaf ")) (EApp (EVar "$core.display") (EVar "i"))) (ELit (LString " outside "))) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString " arms"))) (EVar "acc")) (EVar "acc")))
(DTypeSig false "leafIndices" (TyFun (TyCon "CTree") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "leafIndices" ((PCon "CTFail" PWild)) (EListLit))
(DFunDef false "leafIndices" ((PCon "CTLeaf" (PVar "i"))) (EListLit (EVar "i")))
(DFunDef false "leafIndices" ((PCon "CTGuard" (PVar "i") (PVar "rest"))) (EBinOp "::" (EVar "i") (EApp (EVar "leafIndices") (EVar "rest"))))
(DFunDef false "leafIndices" ((PCon "CTSwitch" (PVar "branches") (PVar "def"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "branchLeaves")) (EVar "branches")) (EApp (EVar "leafIndices") (EVar "def"))))
(DFunDef false "leafIndices" ((PCon "CTDrop" (PVar "rest"))) (EApp (EVar "leafIndices") (EVar "rest")))
(DTypeSig false "branchLeaves" (TyFun (TyCon "CTBranch") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "branchLeaves" ((PCon "CTBranch" PWild (PVar "t"))) (EApp (EVar "leafIndices") (EVar "t")))
(DTypeSig false "scopeFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "scopeFaults" ((PVar "globals") (PVar "scope") (PCon "CVar" (PVar "x") PWild)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "fallthroughName")) (EApp (EApp (EVar "startsWith") (ELit (LString "$extern$"))) (EVar "x"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "globals"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "unbound variable ")) (EApp (EVar "$core.display") (EVar "x"))) (ELit (LString ""))))))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CApp" (PVar "h") (PVar "args") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EBinOp "::" (EVar "h") (EVar "args"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "rhs")) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "omFromNames") (EApp (EVar "bindNames") (EVar "binds"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "groupClauseFaults") (EVar "g")) (EVar "inner"))) (EVar "binds")) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "scrut")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "armFaults") (EVar "g")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "scrut")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "armFaults") (EVar "g")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "c") (EVar "t") (EVar "e"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "l") (EVar "r"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "x")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "x")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "base")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "base")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "stmts")))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "fieldFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fieldFaults" ((PVar "g") (PVar "s") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")))
(DTypeSig false "groupClauseFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "groupClauseFaults" ((PVar "g") (PVar "s") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "armFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "armFaults" ((PVar "g") (PVar "s") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "faults") (PVar "inner")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))) (DoExpr (EBinOp "++" (EVar "faults") (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "armFaults" ((PVar "g") (PVar "s") (PCon "CArmAlt" (PVar "pat") (PVar "guards") PWild)) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))))
(DTypeSig false "guardFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "guardFaults" (PWild (PVar "s") (PList)) (ETuple (EListLit) (EVar "s")))
(DFunDef false "guardFaults" ((PVar "g") (PVar "s") (PCons (PCon "CGBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EVar "s")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EVar "more")) (EVar "out")))))
(DFunDef false "guardFaults" ((PVar "g") (PVar "s") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "p"))) (EVar "s"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EVar "more")) (EVar "out")))))
(DTypeSig false "blockFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "blockFaults" (PWild PWild (PList)) (EListLit))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "rest"))))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "rest"))))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "inner")) (EVar "rest"))))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true) (mem "DeclFacts" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "bindNames" false) (mem "bindPats" false) (mem "foldExpr" false) (mem "implName" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "fallthroughName" false) (mem "startsWith" false))))
(DTypeSig true "lintProgram" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintProgram" ((PCon "CProgram" (PVar "binds") (PVar "ctors") PWild (PVar "impls") PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "globals") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ctors"))) (EApp (EApp (EMethodRef "map") (EVar "implName")) (EVar "impls"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))) (EVar "builtinCtors")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "runtimeAbiRows")))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "lintBind") (EVar "globals"))) (EVar "binds")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "lintImpl") (EVar "globals"))) (EVar "impls"))))))
(DTypeSig false "builtinCtors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtinCtors" () (EListLit (ELit (LString "True")) (ELit (LString "False")) (EVar "siteSentinelName") (ELit (LString "$withFileReadBound")) (ELit (LString "$withFileWriteBound"))))
(DTypeSig false "lintBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintBind" ((PVar "globals") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "lintClause") (EVar "globals")) (EBinOp "++" (ELit (LString "binding ")) (EVar "name")))) (EVar "clauses")))
(DTypeSig false "lintClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lintClause" ((PVar "globals") (PVar "where_") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "where_")) (EVar "body")))
(DTypeSig false "lintImpl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintImpl" ((PVar "globals") (PCon "CImplEntry" (PVar "name") PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EBinOp "++" (ELit (LString "impl ")) (EVar "name"))) (EVar "body")))
(DFunDef false "lintImpl" ((PVar "globals") (PCon "CImplEntry" (PVar "name") PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "lintBody") (EVar "globals")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EBinOp "++" (ELit (LString "impl ")) (EVar "name"))) (EVar "body")))
(DTypeSig false "lintBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "lintBody" ((PVar "globals") (PVar "scope") (PVar "where_") (PVar "body")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "where_"))) (ELit (LString ": "))) (EApp (EVar "$core.display") (EVar "f"))) (ELit (LString ""))))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "globals")) (EVar "scope")) (EVar "body")) (EApp (EVar "shapeFaults") (EVar "body")))))
(DTypeSig false "shapeFaults" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "shapeFaults" ((PVar "e")) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "foldExpr") (EVar "shapeStep")) (EListLit)) (EVar "e"))))
(DTypeSig false "shapeStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CApp" (PCon "CApp" PWild PWild PWild) PWild PWild)) (EBinOp "::" (ELit (LString "application headed by an application")) (EVar "acc")))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CApp" PWild (PList) PWild)) (EBinOp "::" (ELit (LString "application with no arguments")) (EVar "acc")))
(DFunDef false "shapeStep" ((PVar "acc") (PCon "CDecision" PWild (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "addLeafFault") (EApp (EMethodRef "length") (EVar "arms")))) (EVar "acc")) (EApp (EVar "leafIndices") (EVar "tree"))))
(DFunDef false "shapeStep" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "addLeafFault" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "addLeafFault" ((PVar "n") (PVar "acc") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EVar "n"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "decision leaf ")) (EApp (EVar "$core.display") (EVar "i"))) (ELit (LString " outside "))) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString " arms"))) (EVar "acc")) (EVar "acc")))
(DTypeSig false "leafIndices" (TyFun (TyCon "CTree") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "leafIndices" ((PCon "CTFail" PWild)) (EListLit))
(DFunDef false "leafIndices" ((PCon "CTLeaf" (PVar "i"))) (EListLit (EVar "i")))
(DFunDef false "leafIndices" ((PCon "CTGuard" (PVar "i") (PVar "rest"))) (EBinOp "::" (EVar "i") (EApp (EVar "leafIndices") (EVar "rest"))))
(DFunDef false "leafIndices" ((PCon "CTSwitch" (PVar "branches") (PVar "def"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "branchLeaves")) (EVar "branches")) (EApp (EVar "leafIndices") (EVar "def"))))
(DFunDef false "leafIndices" ((PCon "CTDrop" (PVar "rest"))) (EApp (EVar "leafIndices") (EVar "rest")))
(DTypeSig false "branchLeaves" (TyFun (TyCon "CTBranch") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "branchLeaves" ((PCon "CTBranch" PWild (PVar "t"))) (EApp (EVar "leafIndices") (EVar "t")))
(DTypeSig false "scopeFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "scopeFaults" ((PVar "globals") (PVar "scope") (PCon "CVar" (PVar "x") PWild)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "fallthroughName")) (EApp (EApp (EVar "startsWith") (ELit (LString "$extern$"))) (EVar "x"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "globals"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "unbound variable ")) (EApp (EVar "$core.display") (EVar "x"))) (ELit (LString ""))))))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CApp" (PVar "h") (PVar "args") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EBinOp "::" (EVar "h") (EVar "args"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "rhs")) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "omFromNames") (EApp (EVar "bindNames") (EVar "binds"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "groupClauseFaults") (EVar "g")) (EVar "inner"))) (EVar "binds")) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "scrut")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "armFaults") (EVar "g")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "scrut")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "armFaults") (EVar "g")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "c") (EVar "t") (EVar "e"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "l") (EVar "r"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "x")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CList" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "x")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "base")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "base")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "fieldFaults") (EVar "g")) (EVar "s"))) (EVar "fields"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CArray" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EVar "es")))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s"))) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "scopeFaults" ((PVar "g") (PVar "s") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "stmts")))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "scopeFaults" (PWild PWild (PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "fieldFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fieldFaults" ((PVar "g") (PVar "s") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")))
(DTypeSig false "groupClauseFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "groupClauseFaults" ((PVar "g") (PVar "s") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "armFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "armFaults" ((PVar "g") (PVar "s") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "faults") (PVar "inner")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))) (DoExpr (EBinOp "++" (EVar "faults") (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "armFaults" ((PVar "g") (PVar "s") (PCon "CArmAlt" (PVar "pat") (PVar "guards") PWild)) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))))
(DTypeSig false "guardFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "guardFaults" (PWild (PVar "s") (PList)) (ETuple (EListLit) (EVar "s")))
(DFunDef false "guardFaults" ((PVar "g") (PVar "s") (PCons (PCon "CGBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EVar "s")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EVar "more")) (EVar "out")))))
(DFunDef false "guardFaults" ((PVar "g") (PVar "s") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "guardFaults") (EVar "g")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "p"))) (EVar "s"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EVar "more")) (EVar "out")))))
(DTypeSig false "blockFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "blockFaults" (PWild PWild (PList)) (EListLit))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "rest"))))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "s")) (EVar "rest"))))
(DFunDef false "blockFaults" ((PVar "g") (PVar "s") (PCons (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "scopeFaults") (EVar "g")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "e")) (EApp (EApp (EApp (EVar "blockFaults") (EVar "g")) (EVar "inner")) (EVar "rest"))))))
