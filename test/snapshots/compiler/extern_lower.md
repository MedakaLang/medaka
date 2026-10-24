# META
source_lines=306
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Addr(..), Pat(..), RecPatField(..)}
import ir.core_ir.{
  CProgram(..), CBind(..), CClause(..), CExpr(..), CImplEntry(..),
  CImplBody(..), CArm(..), CGuard(..), CStmt(..), CField(..),
  MethodEvidence(..), DeclFacts(..)
}
import ir.extern_types.{ExternDeclFact(..)}
import types.extern_source.{
  ExternSource(..), ExternProvenance(..), ExternBindingKind(..),
  runtimeExternSymbol, sourceExterns, ExternHeadRows
}
import types.runtime_abi_data.{runtimeAbiRows}
import types.program_facts.{ProgramFacts(..)}
import frontend.ast.{Decl}
import support.ordmap.{
  OrdMap, omEmpty, omFromPairs, omFromNames, omHasKey, omInsert, omLookup,
  omKeys
}
import support.util.{listLen, fallthroughName}

export type ExternVisitor = OrdMap Unit -> Int -> String -> Addr -> CExpr

export
externVar : ExternDeclFact -> CExpr
externVar fact = CVar fact.symbol AGlobal

export
externFact : ExternSource -> ExternDeclFact
externFact s = ExternDeclFact {
  symbol = s.sourceSymbol,
  originModule = s.sourceModule,
  declaredName = s.sourceName,
  bindingKind = s.sourceBinding,
  hostBindings = s.sourceHosts,
  callableShape = s.sourceAbi,
  provenance = s.sourceProvenance,
}

export
implicitRuntimeFacts : List ExternDeclFact
implicitRuntimeFacts =
  map
    ((name, shape) => ExternDeclFact {
      symbol = runtimeExternSymbol name,
      originModule = "runtime",
      declaredName = name,
      bindingKind = RuntimeBinding name,
      hostBindings = [],
      callableShape = Some shape,
      provenance = NoSourceSignature,
    })
    runtimeAbiRows

export
lowerExterns : ProgramFacts -> List Decl -> CProgram -> CProgram
lowerExterns input decls (prog@(CProgram groups _ _ _ _ facts)) =
  let sources =
    optionOr (sourceExterns RawSource "<raw>" [] decls) input.pfExternSources
  let rows = map externFact sources ++ implicitRuntimeFacts
  let inventory = omFromPairs (map (f => (f.symbol, f)) rows) omEmpty
  let names =
    omFromPairs
      (map (f => (f.declaredName, f)) implicitRuntimeFacts
        ++ (if isSome input.pfExternSources then
          []
        else
          map (s => (s.sourceName, externFact s)) sources))
      omEmpty
  let globals = omFromNames (map ((CBind n _ _ _) => n) groups) omEmpty
  let selected =
    walkExternVars
      (scope supplied name addr =>
        if name == fallthroughName
          || omHasKey name scope
          || omHasKey name inventory then
          CVar name addr
        else match omLookup name names
          Some fact =>
            if omHasKey ("core__" ++ name) globals
              || omHasKey name globals && (supplied < 0 || isConstant fact) then
              CVar name addr
            else
              externVar fact
          None => CVar name addr)
      prog
  let (CProgram bs ca ct impls mc _) = selected
  CProgram bs ca ct impls mc { facts | factExterns = inventory }

isConstant : ExternDeclFact -> Bool
isConstant fact = match fact.callableShape
  Some shape => shape.writtenValueArity == 0
  None => False

export
walkExternVars : ExternVisitor -> CProgram -> CProgram
walkExternVars f (CProgram groups ca ct impls mc facts) =
  CProgram
    (map (walkBind f omEmpty) groups)
    ca
    ct
    (map (walkEntry f) impls)
    mc
    facts

bindPatScope : Pat -> OrdMap Unit -> OrdMap Unit
bindPatScope pat scope = omFromNames (patNames pat) scope

bindPatsScope : List Pat -> OrdMap Unit -> OrdMap Unit
bindPatsScope pats scope = omFromNames (flatMap patNames pats) scope

bindLetScope : Pat -> CExpr -> OrdMap Unit -> OrdMap Unit
bindLetScope pat _ scope = bindPatScope pat scope

bindGroupScope : List CBind -> OrdMap Unit -> OrdMap Unit
bindGroupScope binds scope =
  omFromNames (map ((CBind n _ _ _) => n) binds) scope

patNames : Pat -> List String
patNames (PVar n _ _) = [n]
patNames (PCon _ ps) = flatMap patNames ps
patNames (PCons a b) = patNames a ++ patNames b
patNames (PTuple ps) = flatMap patNames ps
patNames (PList ps) = flatMap patNames ps
patNames (PAs n _ _ p) = n :: patNames p
patNames (PRec _ fs _) = flatMap fieldNames fs
patNames PWild = []
patNames (PLit _) = []
patNames (PRng _ _ _) = []

fieldNames : RecPatField -> List String
fieldNames (RecPatField n _ _ None) = [n]
fieldNames (RecPatField _ _ _ (Some p)) = patNames p

export
externHeadRows : CProgram -> ExternHeadRows
externHeadRows (CProgram _ _ _ _ _ facts) =
  flatMap
    (key => match omLookup key facts.factExterns
      Some fact => match (fact.bindingKind, fact.callableShape)
        (ForeignBinding, Some shape) => [
          (
            fact.symbol,
            (fact.hostBindings, (shape.parameterHeads, shape.resultHead)),
          ),
        ]
        _ => []
      None => [])
    (omKeys facts.factExterns)

export
externRuntimeKey : OrdMap ExternDeclFact -> String -> Option String
externRuntimeKey inventory symbol = match omLookup symbol inventory
  Some fact => match fact.bindingKind
    RuntimeBinding key => Some key
    ForeignBinding => None
  None => None

walkBind : ExternVisitor -> OrdMap Unit -> CBind -> CBind
walkBind env scope (CBind name clauses site bid) =
  CBind name (map (walkClause env scope) clauses) site bid

walkClause : ExternVisitor -> OrdMap Unit -> CClause -> CClause
walkClause env scope (CClause pats body) =
  CClause pats (walkExpr env (bindPatsScope pats scope) body)

walkEntry : ExternVisitor -> CImplEntry -> CImplEntry
walkEntry env (CImplEntry m s d (CImplTagged tag key iface sym pos pats body)) =
  CImplEntry
    m
    s
    d
    (CImplTagged
      tag
      key
      iface
      sym
      pos
      pats
      (walkExpr env (bindPatsScope pats omEmpty) body))
walkEntry env (CImplEntry m s d (CImplDefault w tag key sym pos pats body)) =
  CImplEntry
    m
    s
    d
    (CImplDefault
      w
      tag
      key
      sym
      pos
      pats
      (walkExpr env (bindPatsScope pats omEmpty) body))

-- Every constructor is listed, with no catch-all arm, so a new expression form
-- must decide where its binders scope.
walkExpr : ExternVisitor -> OrdMap Unit -> CExpr -> CExpr
walkExpr env scope (CApp (CVar name addr) args site) =
  CApp (env scope (listLen args) name addr) (map (walkExpr env scope) args) site
walkExpr env scope (CApp f args site) =
  CApp (walkExpr env scope f) (map (walkExpr env scope) args) site
walkExpr _ _ (CLit l) = CLit l
walkExpr env scope (CVar x addr) = env scope (0 - 1) x addr
walkExpr env scope (CLam pats body) =
  CLam pats (walkExpr env (bindPatsScope pats scope) body)
walkExpr env scope (CLet recF pat rhs body) =
  let inner = bindLetScope pat rhs scope
  CLet
    recF
    pat
    (walkExpr env (if recF then inner else scope) rhs)
    (walkExpr env inner body)
walkExpr env scope (CLetGroup binds body) =
  let inner = bindGroupScope binds scope
  CLetGroup (map (walkBind env inner) binds) (walkExpr env inner body)
walkExpr env scope (CMatch scrut arms) =
  CMatch (walkExpr env scope scrut) (map (walkArm env scope) arms)
walkExpr env scope (CDecision scrut arms tree) =
  CDecision (walkExpr env scope scrut) (map (walkArm env scope) arms) tree
walkExpr env scope (CIf c t e) =
  CIf (walkExpr env scope c) (walkExpr env scope t) (walkExpr env scope e)
walkExpr env scope (CBinPrim op l r tag site) =
  CBinPrim op (walkExpr env scope l) (walkExpr env scope r) tag site
walkExpr env scope (CUnOp op x) = CUnOp op (walkExpr env scope x)
walkExpr env scope (CTuple es) = CTuple (map (walkExpr env scope) es)
walkExpr env scope (CList es) = CList (map (walkExpr env scope) es)
walkExpr env scope (CRecord name fields) =
  CRecord name (map (walkField env scope) fields)
walkExpr env scope (CFieldAccess x label name ord) =
  CFieldAccess (walkExpr env scope x) label name ord
walkExpr env scope (CRecordUpdate name base fields) =
  CRecordUpdate
    name
    (walkExpr env scope base)
    (map (walkField env scope) fields)
walkExpr env scope (CVariantUpdate con base fields) =
  CVariantUpdate
    con
    (walkExpr env scope base)
    (map (walkField env scope) fields)
walkExpr env scope (CArray es) = CArray (map (walkExpr env scope) es)
walkExpr env scope (CRangeList lo hi incl) =
  CRangeList (walkExpr env scope lo) (walkExpr env scope hi) incl
walkExpr env scope (CRangeArray lo hi incl) =
  CRangeArray (walkExpr env scope lo) (walkExpr env scope hi) incl
walkExpr env scope (CIndex a i) =
  CIndex (walkExpr env scope a) (walkExpr env scope i)
walkExpr env scope (CSlice a lo hi incl) =
  CSlice
    (walkExpr env scope a)
    (walkExpr env scope lo)
    (walkExpr env scope hi)
    incl
walkExpr env scope (CStringIndex a i) =
  CStringIndex (walkExpr env scope a) (walkExpr env scope i)
walkExpr env scope (CStringSlice a lo hi incl) =
  CStringSlice
    (walkExpr env scope a)
    (walkExpr env scope lo)
    (walkExpr env scope hi)
    incl
walkExpr env scope (CListIndex a i) =
  CListIndex (walkExpr env scope a) (walkExpr env scope i)
walkExpr env scope (CListSlice a lo hi incl) =
  CListSlice
    (walkExpr env scope a)
    (walkExpr env scope lo)
    (walkExpr env scope hi)
    incl
walkExpr env scope (CBlock stmts) = CBlock (walkStmts env scope stmts)
walkExpr _ _ (CMethod name (MethodEvidence iface arity r ir mr)) =
  CMethod name (MethodEvidence iface arity r ir mr)
walkExpr _ _ (CDict name rs) = CDict name rs

-- An arm's pattern scopes over its guards and body; a `Pat <- e` guard's
-- pattern scopes over the guards after it and the body.
walkArm : ExternVisitor -> OrdMap Unit -> CArm -> CArm
walkArm env scope (CArm pat guards body) =
  let inner = bindPatScope pat scope
  let (guards2, bodyScope) = walkGuards env inner guards
  CArm pat guards2 (walkExpr env bodyScope body)

walkGuards : ExternVisitor ->
  OrdMap Unit ->
  List CGuard ->
  (List CGuard, OrdMap Unit)
walkGuards _ scope [] = ([], scope)
walkGuards env scope ((CGBool c) :: rest) =
  let (rest2, out) = walkGuards env scope rest
  (CGBool (walkExpr env scope c) :: rest2, out)
walkGuards env scope ((CGBind pat e) :: rest) =
  let (rest2, out) = walkGuards env (bindPatScope pat scope) rest
  (CGBind pat (walkExpr env scope e) :: rest2, out)

walkStmts : ExternVisitor -> OrdMap Unit -> List CStmt -> List CStmt
walkStmts _ _ [] = []
walkStmts env scope ((CSExpr e) :: rest) =
  CSExpr (walkExpr env scope e) :: walkStmts env scope rest
walkStmts env scope ((CSLet recF pat e) :: rest) =
  let inner = bindLetScope pat e scope
  CSLet recF pat (walkExpr env (if recF then inner else scope) e)
    :: walkStmts env inner rest
walkStmts env scope ((CSAssign x e) :: rest) =
  CSAssign x (walkExpr env scope e) :: walkStmts env scope rest

walkField : ExternVisitor -> OrdMap Unit -> CField -> CField
walkField env scope (CField k o e) = CField k o (walkExpr env scope e)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "MethodEvidence" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" true) (mem "ExternProvenance" true) (mem "ExternBindingKind" true) (mem "runtimeExternSymbol" false) (mem "sourceExterns" false) (mem "ExternHeadRows" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "fallthroughName" false))))
(DTypeAlias true "ExternVisitor" () (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Addr") (TyCon "CExpr"))))))
(DTypeSig true "externVar" (TyFun (TyCon "ExternDeclFact") (TyCon "CExpr")))
(DFunDef false "externVar" ((PVar "fact")) (EApp (EApp (EVar "CVar") (EFieldAccess (EVar "fact") "symbol")) (EVar "AGlobal")))
(DTypeSig true "externFact" (TyFun (TyCon "ExternSource") (TyCon "ExternDeclFact")))
(DFunDef false "externFact" ((PVar "s")) (ERecordCreate "ExternDeclFact" ((fa "symbol" (EFieldAccess (EVar "s") "sourceSymbol")) (fa "originModule" (EFieldAccess (EVar "s") "sourceModule")) (fa "declaredName" (EFieldAccess (EVar "s") "sourceName")) (fa "bindingKind" (EFieldAccess (EVar "s") "sourceBinding")) (fa "hostBindings" (EFieldAccess (EVar "s") "sourceHosts")) (fa "callableShape" (EFieldAccess (EVar "s") "sourceAbi")) (fa "provenance" (EFieldAccess (EVar "s") "sourceProvenance")))))
(DTypeSig true "implicitRuntimeFacts" (TyApp (TyCon "List") (TyCon "ExternDeclFact")))
(DFunDef false "implicitRuntimeFacts" () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "shape"))) (ERecordCreate "ExternDeclFact" ((fa "symbol" (EApp (EVar "runtimeExternSymbol") (EVar "name"))) (fa "originModule" (ELit (LString "runtime"))) (fa "declaredName" (EVar "name")) (fa "bindingKind" (EApp (EVar "RuntimeBinding") (EVar "name"))) (fa "hostBindings" (EListLit)) (fa "callableShape" (EApp (EVar "Some") (EVar "shape"))) (fa "provenance" (EVar "NoSourceSignature")))))) (EVar "runtimeAbiRows")))
(DTypeSig true "lowerExterns" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "CProgram")))))
(DFunDef false "lowerExterns" ((PVar "input") (PVar "decls") (PAs "prog" (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "RawSource")) (ELit (LString "<raw>"))) (EListLit)) (EVar "decls"))) (EFieldAccess (EVar "input") "pfExternSources"))) (DoLet false false (PVar "rows") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "externFact")) (EVar "sources")) (EVar "implicitRuntimeFacts"))) (DoLet false false (PVar "inventory") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EFieldAccess (EVar "f") "symbol") (EVar "f")))) (EVar "rows"))) (EVar "omEmpty"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromPairs") (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EFieldAccess (EVar "f") "declaredName") (EVar "f")))) (EVar "implicitRuntimeFacts")) (EIf (EApp (EVar "isSome") (EFieldAccess (EVar "input") "pfExternSources")) (EListLit) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (ETuple (EFieldAccess (EVar "s") "sourceName") (EApp (EVar "externFact") (EVar "s"))))) (EVar "sources"))))) (EVar "omEmpty"))) (DoLet false false (PVar "globals") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))) (EVar "groups"))) (EVar "omEmpty"))) (DoLet false false (PVar "selected") (EApp (EApp (EVar "walkExternVars") (ELam ((PVar "scope") (PVar "supplied") (PVar "name") (PVar "addr")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "fallthroughName")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "inventory"))) (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "names")) (arm (PCon "Some" (PVar "fact")) () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "name"))) (EVar "globals")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "globals")) (EBinOp "||" (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (EApp (EVar "isConstant") (EVar "fact"))))) (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")) (EApp (EVar "externVar") (EVar "fact")))) (arm (PCon "None") () (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr"))))))) (EVar "prog"))) (DoLet false false (PCon "CProgram" (PVar "bs") (PVar "ca") (PVar "ct") (PVar "impls") (PVar "mc") PWild) (EVar "selected")) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "bs")) (EVar "ca")) (EVar "ct")) (EVar "impls")) (EVar "mc")) (ERecordUpdate (EVar "facts") ((fa "factExterns" (EVar "inventory"))))))))
(DTypeSig false "isConstant" (TyFun (TyCon "ExternDeclFact") (TyCon "Bool")))
(DFunDef false "isConstant" ((PVar "fact")) (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "Some" (PVar "shape")) () (EBinOp "==" (EFieldAccess (EVar "shape") "writtenValueArity") (ELit (LInt 0)))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "walkExternVars" (TyFun (TyCon "ExternVisitor") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "walkExternVars" ((PVar "f") (PCon "CProgram" (PVar "groups") (PVar "ca") (PVar "ct") (PVar "impls") (PVar "mc") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkBind") (EVar "f")) (EVar "omEmpty"))) (EVar "groups"))) (EVar "ca")) (EVar "ct")) (EApp (EApp (EVar "map") (EApp (EVar "walkEntry") (EVar "f"))) (EVar "impls"))) (EVar "mc")) (EVar "facts")))
(DTypeSig false "bindPatScope" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPatScope" ((PVar "pat") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "patNames") (EVar "pat"))) (EVar "scope")))
(DTypeSig false "bindPatsScope" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPatsScope" ((PVar "pats") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (EVar "patNames")) (EVar "pats"))) (EVar "scope")))
(DTypeSig false "bindLetScope" (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "bindLetScope" ((PVar "pat") PWild (PVar "scope")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope")))
(DTypeSig false "bindGroupScope" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindGroupScope" ((PVar "binds") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))) (EVar "binds"))) (EVar "scope")))
(DTypeSig false "patNames" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patNames" ((PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "patNames" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patNames") (EVar "a")) (EApp (EVar "patNames") (EVar "b"))))
(DFunDef false "patNames" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PAs" (PVar "n") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "n") (EApp (EVar "patNames") (EVar "p"))))
(DFunDef false "patNames" ((PCon "PRec" PWild (PVar "fs") PWild)) (EApp (EApp (EVar "flatMap") (EVar "fieldNames")) (EVar "fs")))
(DFunDef false "patNames" ((PCon "PWild")) (EListLit))
(DFunDef false "patNames" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patNames" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DTypeSig false "fieldNames" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PCon "RecPatField" (PVar "n") PWild PWild (PCon "None"))) (EListLit (EVar "n")))
(DFunDef false "fieldNames" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patNames") (EVar "p")))
(DTypeSig true "externHeadRows" (TyFun (TyCon "CProgram") (TyCon "ExternHeadRows")))
(DFunDef false "externHeadRows" ((PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) () (EMatch (ETuple (EFieldAccess (EVar "fact") "bindingKind") (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "ForeignBinding") (PCon "Some" (PVar "shape"))) () (EListLit (ETuple (EFieldAccess (EVar "fact") "symbol") (ETuple (EFieldAccess (EVar "fact") "hostBindings") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EListLit)))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))))
(DTypeSig true "externRuntimeKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "externRuntimeKey" ((PVar "inventory") (PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "inventory")) (arm (PCon "Some" (PVar "fact")) () (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "RuntimeBinding" (PVar "key")) () (EApp (EVar "Some") (EVar "key"))) (arm (PCon "ForeignBinding") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "walkBind" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyCon "CBind")))))
(DFunDef false "walkBind" ((PVar "env") (PVar "scope") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkClause") (EVar "env")) (EVar "scope"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "walkClause" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CClause") (TyCon "CClause")))))
(DFunDef false "walkClause" ((PVar "env") (PVar "scope") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DTypeSig false "walkEntry" (TyFun (TyCon "ExternVisitor") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "walkEntry" ((PVar "env") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DFunDef false "walkEntry" ((PVar "env") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "w") (PVar "tag") (PVar "key") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "w")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CApp" (PCon "CVar" (PVar "name") (PVar "addr")) (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EApp (EVar "env") (EVar "scope")) (EApp (EVar "listLen") (EVar "args"))) (EVar "name")) (EVar "addr"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "args"))) (EVar "site")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "f"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "args"))) (EVar "site")))
(DFunDef false "walkExpr" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EApp (EApp (EVar "env") (EVar "scope")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "x")) (EVar "addr")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recF")) (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkBind") (EVar "env")) (EVar "inner"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkArm") (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkArm") (EVar "env")) (EVar "scope"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "c"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "l"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "stmts"))))
(DFunDef false "walkExpr" (PWild PWild (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr")))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "MethodEvidence") (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr"))))
(DFunDef false "walkExpr" (PWild PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "walkArm" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyCon "CArm")))))
(DFunDef false "walkArm" ((PVar "env") (PVar "scope") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (DoLet false false (PTuple (PVar "guards2") (PVar "bodyScope")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EVar "inner")) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "bodyScope")) (EVar "body"))))))
(DTypeSig false "walkGuards" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "walkGuards" ((PVar "env") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "out")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "c"))) (EVar "rest2")) (EVar "out")))))
(DFunDef false "walkGuards" ((PVar "env") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "out")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "out")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))))
(DFunDef false "walkStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "rest"))))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "recF")) (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "inner")) (EVar "rest"))))))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "rest"))))
(DTypeSig false "walkField" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CField") (TyCon "CField")))))
(DFunDef false "walkField" ((PVar "env") (PVar "scope") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "MethodEvidence" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" true) (mem "ExternProvenance" true) (mem "ExternBindingKind" true) (mem "runtimeExternSymbol" false) (mem "sourceExterns" false) (mem "ExternHeadRows" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "fallthroughName" false))))
(DTypeAlias true "ExternVisitor" () (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Addr") (TyCon "CExpr"))))))
(DTypeSig true "externVar" (TyFun (TyCon "ExternDeclFact") (TyCon "CExpr")))
(DFunDef false "externVar" ((PVar "fact")) (EApp (EApp (EVar "CVar") (EFieldAccess (EVar "fact") "symbol")) (EVar "AGlobal")))
(DTypeSig true "externFact" (TyFun (TyCon "ExternSource") (TyCon "ExternDeclFact")))
(DFunDef false "externFact" ((PVar "s")) (ERecordCreate "ExternDeclFact" ((fa "symbol" (EFieldAccess (EVar "s") "sourceSymbol")) (fa "originModule" (EFieldAccess (EVar "s") "sourceModule")) (fa "declaredName" (EFieldAccess (EVar "s") "sourceName")) (fa "bindingKind" (EFieldAccess (EVar "s") "sourceBinding")) (fa "hostBindings" (EFieldAccess (EVar "s") "sourceHosts")) (fa "callableShape" (EFieldAccess (EVar "s") "sourceAbi")) (fa "provenance" (EFieldAccess (EVar "s") "sourceProvenance")))))
(DTypeSig true "implicitRuntimeFacts" (TyApp (TyCon "List") (TyCon "ExternDeclFact")))
(DFunDef false "implicitRuntimeFacts" () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "shape"))) (ERecordCreate "ExternDeclFact" ((fa "symbol" (EApp (EVar "runtimeExternSymbol") (EVar "name"))) (fa "originModule" (ELit (LString "runtime"))) (fa "declaredName" (EVar "name")) (fa "bindingKind" (EApp (EVar "RuntimeBinding") (EVar "name"))) (fa "hostBindings" (EListLit)) (fa "callableShape" (EApp (EVar "Some") (EVar "shape"))) (fa "provenance" (EVar "NoSourceSignature")))))) (EVar "runtimeAbiRows")))
(DTypeSig true "lowerExterns" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "CProgram")))))
(DFunDef false "lowerExterns" ((PVar "input") (PVar "decls") (PAs "prog" (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "RawSource")) (ELit (LString "<raw>"))) (EListLit)) (EVar "decls"))) (EFieldAccess (EVar "input") "pfExternSources"))) (DoLet false false (PVar "rows") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "externFact")) (EVar "sources")) (EVar "implicitRuntimeFacts"))) (DoLet false false (PVar "inventory") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EFieldAccess (EVar "f") "symbol") (EVar "f")))) (EVar "rows"))) (EVar "omEmpty"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromPairs") (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EFieldAccess (EVar "f") "declaredName") (EVar "f")))) (EVar "implicitRuntimeFacts")) (EIf (EApp (EVar "isSome") (EFieldAccess (EVar "input") "pfExternSources")) (EListLit) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (ETuple (EFieldAccess (EVar "s") "sourceName") (EApp (EVar "externFact") (EVar "s"))))) (EVar "sources"))))) (EVar "omEmpty"))) (DoLet false false (PVar "globals") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))) (EVar "groups"))) (EVar "omEmpty"))) (DoLet false false (PVar "selected") (EApp (EApp (EVar "walkExternVars") (ELam ((PVar "scope") (PVar "supplied") (PVar "name") (PVar "addr")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "fallthroughName")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "inventory"))) (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "names")) (arm (PCon "Some" (PVar "fact")) () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "name"))) (EVar "globals")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "globals")) (EBinOp "||" (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (EApp (EVar "isConstant") (EVar "fact"))))) (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")) (EApp (EVar "externVar") (EVar "fact")))) (arm (PCon "None") () (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr"))))))) (EVar "prog"))) (DoLet false false (PCon "CProgram" (PVar "bs") (PVar "ca") (PVar "ct") (PVar "impls") (PVar "mc") PWild) (EVar "selected")) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "bs")) (EVar "ca")) (EVar "ct")) (EVar "impls")) (EVar "mc")) (ERecordUpdate (EVar "facts") ((fa "factExterns" (EVar "inventory"))))))))
(DTypeSig false "isConstant" (TyFun (TyCon "ExternDeclFact") (TyCon "Bool")))
(DFunDef false "isConstant" ((PVar "fact")) (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "Some" (PVar "shape")) () (EBinOp "==" (EFieldAccess (EVar "shape") "writtenValueArity") (ELit (LInt 0)))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "walkExternVars" (TyFun (TyCon "ExternVisitor") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "walkExternVars" ((PVar "f") (PCon "CProgram" (PVar "groups") (PVar "ca") (PVar "ct") (PVar "impls") (PVar "mc") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkBind") (EVar "f")) (EVar "omEmpty"))) (EVar "groups"))) (EVar "ca")) (EVar "ct")) (EApp (EApp (EMethodRef "map") (EApp (EVar "walkEntry") (EVar "f"))) (EVar "impls"))) (EVar "mc")) (EVar "facts")))
(DTypeSig false "bindPatScope" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPatScope" ((PVar "pat") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "patNames") (EVar "pat"))) (EVar "scope")))
(DTypeSig false "bindPatsScope" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPatsScope" ((PVar "pats") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (EVar "patNames")) (EVar "pats"))) (EVar "scope")))
(DTypeSig false "bindLetScope" (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "bindLetScope" ((PVar "pat") PWild (PVar "scope")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope")))
(DTypeSig false "bindGroupScope" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindGroupScope" ((PVar "binds") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))) (EVar "binds"))) (EVar "scope")))
(DTypeSig false "patNames" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patNames" ((PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "patNames" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patNames") (EVar "a")) (EApp (EVar "patNames") (EVar "b"))))
(DFunDef false "patNames" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patNames")) (EVar "ps")))
(DFunDef false "patNames" ((PCon "PAs" (PVar "n") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "n") (EApp (EVar "patNames") (EVar "p"))))
(DFunDef false "patNames" ((PCon "PRec" PWild (PVar "fs") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "fieldNames")) (EVar "fs")))
(DFunDef false "patNames" ((PCon "PWild")) (EListLit))
(DFunDef false "patNames" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patNames" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DTypeSig false "fieldNames" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PCon "RecPatField" (PVar "n") PWild PWild (PCon "None"))) (EListLit (EVar "n")))
(DFunDef false "fieldNames" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patNames") (EVar "p")))
(DTypeSig true "externHeadRows" (TyFun (TyCon "CProgram") (TyCon "ExternHeadRows")))
(DFunDef false "externHeadRows" ((PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) () (EMatch (ETuple (EFieldAccess (EVar "fact") "bindingKind") (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "ForeignBinding") (PCon "Some" (PVar "shape"))) () (EListLit (ETuple (EFieldAccess (EVar "fact") "symbol") (ETuple (EFieldAccess (EVar "fact") "hostBindings") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EListLit)))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))))
(DTypeSig true "externRuntimeKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "externRuntimeKey" ((PVar "inventory") (PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "inventory")) (arm (PCon "Some" (PVar "fact")) () (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "RuntimeBinding" (PVar "key")) () (EApp (EVar "Some") (EVar "key"))) (arm (PCon "ForeignBinding") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "walkBind" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyCon "CBind")))))
(DFunDef false "walkBind" ((PVar "env") (PVar "scope") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkClause") (EVar "env")) (EVar "scope"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "walkClause" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CClause") (TyCon "CClause")))))
(DFunDef false "walkClause" ((PVar "env") (PVar "scope") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DTypeSig false "walkEntry" (TyFun (TyCon "ExternVisitor") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "walkEntry" ((PVar "env") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DFunDef false "walkEntry" ((PVar "env") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "w") (PVar "tag") (PVar "key") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "w")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CApp" (PCon "CVar" (PVar "name") (PVar "addr")) (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EApp (EVar "env") (EVar "scope")) (EApp (EVar "listLen") (EVar "args"))) (EVar "name")) (EVar "addr"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "args"))) (EVar "site")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "f"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "args"))) (EVar "site")))
(DFunDef false "walkExpr" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EApp (EApp (EVar "env") (EVar "scope")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "x")) (EVar "addr")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recF")) (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkBind") (EVar "env")) (EVar "inner"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkArm") (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkArm") (EVar "env")) (EVar "scope"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "c"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "l"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkField") (EVar "env")) (EVar "scope"))) (EVar "fields"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope"))) (EVar "es"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "walkExpr" ((PVar "env") (PVar "scope") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "stmts"))))
(DFunDef false "walkExpr" (PWild PWild (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr")))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "MethodEvidence") (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr"))))
(DFunDef false "walkExpr" (PWild PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "walkArm" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyCon "CArm")))))
(DFunDef false "walkArm" ((PVar "env") (PVar "scope") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (DoLet false false (PTuple (PVar "guards2") (PVar "bodyScope")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EVar "inner")) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "bodyScope")) (EVar "body"))))))
(DTypeSig false "walkGuards" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "walkGuards" ((PVar "env") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "out")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "c"))) (EVar "rest2")) (EVar "out")))))
(DFunDef false "walkGuards" ((PVar "env") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "out")) (EApp (EApp (EApp (EVar "walkGuards") (EVar "env")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "out")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))))
(DFunDef false "walkStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "rest"))))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "recF")) (EVar "pat")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "inner")) (EVar "rest"))))))
(DFunDef false "walkStmts" ((PVar "env") (PVar "scope") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EApp (EVar "walkStmts") (EVar "env")) (EVar "scope")) (EVar "rest"))))
(DTypeSig false "walkField" (TyFun (TyCon "ExternVisitor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CField") (TyCon "CField")))))
(DFunDef false "walkField" ((PVar "env") (PVar "scope") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "env")) (EVar "scope")) (EVar "e"))))
