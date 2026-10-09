# META
source_lines=298
stages=DESUGAR,MARK
# SOURCE
-- Checks a lowered program must pass before an emitter writes any of it.  Each
-- check reads only the `CProgram` the emitter received and the extern catalog,
-- so every build entry reports a refusal from one place, and before either
-- emitter has produced text.
--
-- The extern check: a runtime extern whose catalog row gives the backend no
-- lowering (`NotProvided`) is refused wherever the program references it
-- freely.  A reference is free when no local binder in scope and no top-level
-- binding or constructor of the program has the extern's name; those names
-- shadow the extern in both emitters' application ladders, so the emitter
-- would not lower the extern there.  The program checked is the one the
-- emitter received, after any reachability filter its entry ran.

import ir.core_ir.{
  CExpr(..),
  CField(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  CProgram(..),
}
import frontend.ast.{Pat(..), RecPatField(..)}
import backend.extern_catalog.{
  Disposition(..),
  GapKind,
  catalogRow,
  gapKindName,
  rowLlvm,
  rowWasm,
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey}
import support.util.{joinWith, reverseL}

public export data Backend = LlvmBackend | WasmBackend

export
backendName : Backend -> String
backendName LlvmBackend = "llvm"
backendName WasmBackend = "wasm"

-- A free reference to a runtime extern the backend does not lower: the extern,
-- the backend, the row's gap kind and reason, and the top-level binding the
-- first reference sits in.
public export data ExternFinding =
  | ExternFinding String Backend GapKind String String

export
findingExtern : ExternFinding -> String
findingExtern (ExternFinding name _ _ _ _) = name

export
findingBinding : ExternFinding -> String
findingBinding (ExternFinding _ _ _ _ binding) = binding

-- The gap kind and reason when `backend` does not lower runtime extern `name`,
-- or `None` for an extern it lowers and for a name that is not a runtime extern.
export
unprovidedOn : Backend -> String -> Option (GapKind, String)
unprovidedOn LlvmBackend name = match catalogRow name
  Some r => notProvidedOf (rowLlvm r)
  None => None
unprovidedOn WasmBackend name = match catalogRow name
  Some r => notProvidedOf (rowWasm r)
  None => None

notProvidedOf : Disposition f -> Option (GapKind, String)
notProvidedOf (NotProvided kind why) = Some (kind, why)
notProvidedOf _ = None

export
isUnprovidedOn : Backend -> String -> Bool
isUnprovidedOn backend name = isSome (unprovidedOn backend name)

-- Every free reference to a runtime extern `backend` does not lower, one
-- finding per distinct extern, in the order of first reference.
-- `runtimeExterns` names the externs the entry declared from
-- `stdlib/runtime.mdk`; a name among them with no catalog row is an internal
-- error, raised before the program is read.
export
validateExterns : Backend -> List String -> CProgram -> List ExternFinding
validateExterns backend runtimeExterns (CProgram groups ctors _ impls) =
  let _ = refuseMissingRows runtimeExterns
  let top = programNames groups ctors omEmpty
  let walked =
    walkImpls backend top impls (walkBinds backend top groups noFindings)
  match walked
    Walk _ found => reverseL found

-- The names in `names` that have no extern catalog row.
export
missingCatalogRows : List String -> List String
missingCatalogRows names = filter (n => isNone (catalogRow n)) names

export
missingRowsMessage : List String -> String
missingRowsMessage missing =
  let names = joinWith ", " (map quoteName missing)
  "internal error: runtime extern \{names} has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"

quoteName : String -> String
quoteName n = "'" ++ n ++ "'"

refuseMissingRows : List String -> Unit
refuseMissingRows names = match missingCatalogRows names
  [] => ()
  missing => panic (missingRowsMessage missing)

-- One line per finding: what the build refuses, and why the backend does not
-- lower the extern.
export
renderExternFinding : ExternFinding -> String
renderExternFinding (ExternFinding name backend kind why binding) =
  "\{backendName backend}: runtime extern '\{name}' is not available on the \{backendName backend} backend (\{gapKindName kind}: \{why}) [in \{binding}]"

export
renderExternRefusal : List ExternFinding -> String
renderExternRefusal findings = joinWith "\n" (map renderExternFinding findings)

-- The panic of an emitter that meets an extern `validateExterns` refuses: the
-- validator runs first on every emission, so reaching one means the two
-- disagree about which references are free.
export
unrefusedExternMessage : Backend -> String -> String
unrefusedExternMessage backend name =
  "internal error: the \{backendName backend} emitter reached runtime extern '\{name}', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"

-- The top-level bindings and constructors of the program.
programNames : List CBind -> List (String, Int) -> OrdMap Unit -> OrdMap Unit
programNames [] [] acc = acc
programNames [] ((ctor, _) :: rest) acc =
  programNames [] rest (omInsert ctor () acc)
programNames ((CBind name _ _) :: rest) ctors acc =
  programNames rest ctors (omInsert name () acc)

-- A reference is the program's own when a top-level binding has its name, or
-- the `core__` name a bare prelude reference resolves to in both emitters
-- (`canonFn`, `canonFnName`).
isProgramName : OrdMap Unit -> String -> Bool
isProgramName top x = omHasKey x top || omHasKey ("core__" ++ x) top

-- The walk's state: the externs already found, and the findings, newest first.
data Walk = Walk (OrdMap Unit) (List ExternFinding)

noFindings : Walk
noFindings = Walk omEmpty []

-- The backend, the program's own names, and the top-level binding being read.
data Ctx = Ctx Backend (OrdMap Unit) String

walkBinds : Backend -> OrdMap Unit -> List CBind -> Walk -> Walk
walkBinds _ _ [] w = w
walkBinds backend top ((CBind name clauses _) :: rest) w =
  walkBinds
    backend
    top
    rest
    (walkClauses (Ctx backend top name) omEmpty clauses w)

walkImpls : Backend -> OrdMap Unit -> List CImplEntry -> Walk -> Walk
walkImpls _ _ [] w = w
walkImpls backend top ((CImplEntry method _ body) :: rest) w =
  walkImpls backend top rest (walkImplBody backend top method body w)

walkImplBody : Backend -> OrdMap Unit -> String -> CImplBody -> Walk -> Walk
walkImplBody backend top method (CImplTagged tag _ _ _ pats body) w =
  walkE (Ctx backend top "impl \{method}@\{tag}") (bindPats pats omEmpty) body w
walkImplBody backend top method (CImplDefault _ tag _ _ pats body) w =
  walkE (Ctx backend top "impl \{method}@\{tag}") (bindPats pats omEmpty) body w

walkClauses : Ctx -> OrdMap Unit -> List CClause -> Walk -> Walk
walkClauses _ _ [] w = w
walkClauses ctx scope ((CClause pats body) :: rest) w =
  walkClauses ctx scope rest (walkE ctx (bindPats pats scope) body w)

-- Every constructor is listed, with no catch-all arm, so a new expression form
-- must decide where its binders scope.
walkE : Ctx -> OrdMap Unit -> CExpr -> Walk -> Walk
walkE ctx scope (CVar x _) w = noteVar ctx scope x w
walkE _ _ (CLit _) w = w
walkE ctx scope (CApp f a) w = walkE ctx scope a (walkE ctx scope f w)
walkE ctx scope (CLam pats body) w = walkE ctx (bindPats pats scope) body w
walkE ctx scope (CLet recF pat rhs body) w =
  let inner = bindPat pat scope
  walkE ctx inner body (walkE ctx (if recF then inner else scope) rhs w)
walkE ctx scope (CLetGroup binds body) w =
  let inner = bindNames binds scope
  walkE ctx inner body (walkLocalBinds ctx inner binds w)
walkE ctx scope (CMatch scrut arms) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CDecision scrut arms _) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CIf c t f) w = walkList ctx scope [c, t, f] w
walkE ctx scope (CBinPrim _ l r _ _) w = walkList ctx scope [l, r] w
walkE ctx scope (CUnOp _ x) w = walkE ctx scope x w
walkE ctx scope (CTuple es) w = walkList ctx scope es w
walkE ctx scope (CList es) w = walkList ctx scope es w
walkE ctx scope (CRecord _ fields) w = walkFields ctx scope fields w
walkE ctx scope (CFieldAccess x _ _) w = walkE ctx scope x w
walkE ctx scope (CRecordUpdate _ base fields) w =
  walkFields ctx scope fields (walkE ctx scope base w)
walkE ctx scope (CVariantUpdate _ base fields) w =
  walkFields ctx scope fields (walkE ctx scope base w)
walkE ctx scope (CArray es) w = walkList ctx scope es w
walkE ctx scope (CRangeList lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CRangeArray lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CStringIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CStringSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CListIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CListSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CBlock stmts) w = walkStmts ctx scope stmts w
walkE _ _ (CMethod _ _ _ _ _ _) w = w
walkE _ _ (CDict _ _) w = w

noteVar : Ctx -> OrdMap Unit -> String -> Walk -> Walk
noteVar (Ctx backend top binding) scope x (w@(Walk seen found)) =
  if omHasKey x scope || omHasKey x seen then
    w
  else match unprovidedOn backend x
    None => w
    Some (kind, why) =>
      if isProgramName top x then
        w
      else
        Walk
          (omInsert x () seen)
          (ExternFinding x backend kind why binding :: found)

walkList : Ctx -> OrdMap Unit -> List CExpr -> Walk -> Walk
walkList _ _ [] w = w
walkList ctx scope (e :: rest) w = walkList ctx scope rest (walkE ctx scope e w)

walkFields : Ctx -> OrdMap Unit -> List CField -> Walk -> Walk
walkFields _ _ [] w = w
walkFields ctx scope ((CField _ e) :: rest) w =
  walkFields ctx scope rest (walkE ctx scope e w)

walkLocalBinds : Ctx -> OrdMap Unit -> List CBind -> Walk -> Walk
walkLocalBinds _ _ [] w = w
walkLocalBinds ctx scope ((CBind _ clauses _) :: rest) w =
  walkLocalBinds ctx scope rest (walkClauses ctx scope clauses w)

-- An arm's pattern scopes over its guards and body; a `Pat <- e` guard's
-- pattern scopes over the guards after it and the body.
walkArms : Ctx -> OrdMap Unit -> List CArm -> Walk -> Walk
walkArms _ _ [] w = w
walkArms ctx scope ((CArm pat guards body) :: rest) w =
  walkArms ctx scope rest (walkGuarded ctx (bindPat pat scope) guards body w)

walkGuarded : Ctx -> OrdMap Unit -> List CGuard -> CExpr -> Walk -> Walk
walkGuarded ctx scope [] body w = walkE ctx scope body w
walkGuarded ctx scope ((CGBool c) :: rest) body w =
  walkGuarded ctx scope rest body (walkE ctx scope c w)
walkGuarded ctx scope ((CGBind pat e) :: rest) body w =
  walkGuarded ctx (bindPat pat scope) rest body (walkE ctx scope e w)

walkStmts : Ctx -> OrdMap Unit -> List CStmt -> Walk -> Walk
walkStmts _ _ [] w = w
walkStmts ctx scope ((CSExpr e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)
walkStmts ctx scope ((CSLet recF pat e) :: rest) w =
  let inner = bindPat pat scope
  walkStmts ctx inner rest (walkE ctx (if recF then inner else scope) e w)
walkStmts ctx scope ((CSAssign _ e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)

bindNames : List CBind -> OrdMap Unit -> OrdMap Unit
bindNames [] s = s
bindNames ((CBind name _ _) :: rest) s = bindNames rest (omInsert name () s)

bindPats : List Pat -> OrdMap Unit -> OrdMap Unit
bindPats [] s = s
bindPats (p :: rest) s = bindPats rest (bindPat p s)

bindPat : Pat -> OrdMap Unit -> OrdMap Unit
bindPat (PVar x _) s = omInsert x () s
bindPat PWild s = s
bindPat (PLit _) s = s
bindPat (PCon _ ps) s = bindPats ps s
bindPat (PCons h t) s = bindPat t (bindPat h s)
bindPat (PTuple ps) s = bindPats ps s
bindPat (PList ps) s = bindPats ps s
bindPat (PAs x _ p) s = bindPat p (omInsert x () s)
bindPat (PRng _ _ _) s = s
bindPat (PRec _ fields _) s = bindRecFields fields s

-- A punned field `{x}` binds the field's own name.
bindRecFields : List RecPatField -> OrdMap Unit -> OrdMap Unit
bindRecFields [] s = s
bindRecFields ((RecPatField f _ None) :: rest) s =
  bindRecFields rest (omInsert f () s)
bindRecFields ((RecPatField _ _ (Some p)) :: rest) s =
  bindRecFields rest (bindPat p s)
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "GapKind" false) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls"))) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "walked") (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "impls")) (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "groups")) (EVar "noFindings")))) (DoExpr (EMatch (EVar "walked") (arm (PCon "Walk" PWild (PVar "found")) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EVar "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EVar "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "String")))) ())
(DTypeSig false "walkBinds" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "backend") (PVar "top") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkImpls" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "backend") (PVar "top") (PCons (PCon "CImplEntry" (PVar "method") PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkImplBody") (EVar "backend")) (EVar "top")) (EVar "method")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkImplBody" ((PVar "backend") (PVar "top") (PVar "method") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PVar "backend") (PVar "top") (PVar "method") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "a")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindNames") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" PWild (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "w")) (EVar "w"))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "x")) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EVar "x")) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindNames" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "s"))))
(DTypeSig false "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindPats" ((PCons (PVar "p") (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "rest")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "s"))))
(DTypeSig false "bindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPat" ((PCon "PVar" (PVar "x") PWild) (PVar "s")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PWild") (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PLit" PWild) (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PCon" PWild (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PVar "s")) (EApp (EApp (EVar "bindPat") (EVar "t")) (EApp (EApp (EVar "bindPat") (EVar "h")) (EVar "s"))))
(DFunDef false "bindPat" ((PCon "PTuple" (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PList" (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PAs" (PVar "x") PWild (PVar "p")) (PVar "s")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "s"))))
(DFunDef false "bindPat" ((PCon "PRng" PWild PWild PWild) (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "fields")) (EVar "s")))
(DTypeSig false "bindRecFields" (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindRecFields" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindRecFields" ((PCons (PCon "RecPatField" (PVar "f") PWild (PCon "None")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (ELit LUnit)) (EVar "s"))))
(DFunDef false "bindRecFields" ((PCons (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p"))) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "rest")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "s"))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "GapKind" false) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls"))) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "walked") (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "impls")) (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "groups")) (EVar "noFindings")))) (DoExpr (EMatch (EVar "walked") (arm (PCon "Walk" PWild (PVar "found")) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EMethodRef "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "String")))) ())
(DTypeSig false "walkBinds" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "backend") (PVar "top") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkImpls" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "backend") (PVar "top") (PCons (PCon "CImplEntry" (PVar "method") PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkImplBody") (EVar "backend")) (EVar "top")) (EVar "method")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkImplBody" ((PVar "backend") (PVar "top") (PVar "method") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PVar "backend") (PVar "top") (PVar "method") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "a")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindNames") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" PWild (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "w")) (EVar "w"))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "x")) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EVar "x")) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPat") (EVar "pat")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindNames" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "s"))))
(DTypeSig false "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindPats" ((PCons (PVar "p") (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "rest")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "s"))))
(DTypeSig false "bindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPat" ((PCon "PVar" (PVar "x") PWild) (PVar "s")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PWild") (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PLit" PWild) (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PCon" PWild (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PVar "s")) (EApp (EApp (EVar "bindPat") (EVar "t")) (EApp (EApp (EVar "bindPat") (EVar "h")) (EVar "s"))))
(DFunDef false "bindPat" ((PCon "PTuple" (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PList" (PVar "ps")) (PVar "s")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "s")))
(DFunDef false "bindPat" ((PCon "PAs" (PVar "x") PWild (PVar "p")) (PVar "s")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "s"))))
(DFunDef false "bindPat" ((PCon "PRng" PWild PWild PWild) (PVar "s")) (EVar "s"))
(DFunDef false "bindPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "fields")) (EVar "s")))
(DTypeSig false "bindRecFields" (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindRecFields" ((PList) (PVar "s")) (EVar "s"))
(DFunDef false "bindRecFields" ((PCons (PCon "RecPatField" (PVar "f") PWild (PCon "None")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (ELit LUnit)) (EVar "s"))))
(DFunDef false "bindRecFields" ((PCons (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p"))) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "bindRecFields") (EVar "rest")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "s"))))
