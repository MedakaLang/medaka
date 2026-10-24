# META
source_lines=228
stages=DESUGAR,MARK
# SOURCE
import backend.emit_target.{Backend(..), backendName}
import backend.extern_catalog.{RuntimeExternDomain(..), catalogRow}
import ir.core_ir.{CProgram(..), DeclFacts(..)}
import ir.extern_types.{ExternDeclFact(..), ExternUse(..)}
import ir.extern_uses.{collectExternUses}
import types.extern_source.{ExternBindingKind(..)}
import types.runtime_abi_types.{CallableShape(..)}
import types.runtime_abi.{runtimeAbi, sourceShape}
import frontend.ast.{hostSymbol}
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert, omKeys, omHasKey}
import support.util.{listLen, reverseL, startsWith}

public export data RequirementBinding =
  | RuntimeRequirement String
  | ForeignRequirement String (Option String)
  deriving (Eq, Debug)

public export data ExternRequirement = ExternRequirement {
  declaration : ExternDeclFact,
  selectedBinding : RequirementBinding,
  selectedUses : List ExternUse,
} deriving (Eq, Debug)

public export data ExternRequirements = ExternRequirements {
  target : Backend,
  runtimeDomain : RuntimeExternDomain,
  rows : List ExternRequirement,
  nativePrototypes : List ExternDeclFact,
}

bindingFor : Backend -> ExternDeclFact -> RequirementBinding
bindingFor _ (ExternDeclFact { bindingKind = (RuntimeBinding key) }) =
  RuntimeRequirement key
bindingFor backend fact =
  let host = match backend
    LlvmBackend => "c"
    WasmBackend => "js"
    EvalBackend => "eval"
  ForeignRequirement host (hostSymbol host fact.hostBindings)

useIndex : List ExternUse -> OrdMap (List ExternUse)
useIndex =
  fold
    (acc use =>
      omInsert
        use.useSymbol
        (use :: optionOr [] (omLookup use.useSymbol acc))
        acc)
    omEmpty

export
planExterns : Backend -> RuntimeExternDomain -> CProgram -> ExternRequirements
planExterns target domain (cp@(CProgram _ _ _ _ _ facts)) =
  let uses = useIndex (collectExternUses cp)
  ExternRequirements {
    target = target,
    runtimeDomain = domain,
    nativePrototypes = prototypesFor target facts.factExterns,
    rows =
      filterMap
        (symbol =>
          map
            (fact => ExternRequirement {
              declaration = fact,
              selectedBinding = bindingFor target fact,
              selectedUses = reverseL (optionOr [] (omLookup symbol uses)),
            })
            (omLookup symbol facts.factExterns))
        (omKeys uses),
  }

-- Consumers index the validated selection, never the complete declaration domain.
export
requirementFacts : ExternRequirements -> OrdMap ExternDeclFact
requirementFacts requirements =
  fold
    (acc row => omInsert row.declaration.symbol row.declaration acc)
    omEmpty
    requirements.rows

export
requirementHostRows : ExternRequirements ->
  List (String, (String, (List String, String)))
requirementHostRows requirements =
  filterMap
    (row => match (row.selectedBinding, row.declaration.callableShape)
      (ForeignRequirement _ (Some host), Some shape) => Some (
        row.declaration.symbol,
        (host, (shape.parameterHeads, shape.resultHead)),
      )
      _ => None)
    requirements.rows

export
validateExternRequirements : Backend ->
  RuntimeExternDomain ->
  CProgram ->
  ExternRequirements ->
  List String
validateExternRequirements backend domain (cp@(CProgram _ _ _ _ _ facts)) requirements =
  let uses = useIndex (collectExternUses cp)
  let (selected, duplicates) =
    fold
      ((index, bad) row =>
        let symbol = row.declaration.symbol
        (
          omInsert symbol row index,
          if omHasKey symbol index then
            "duplicate-extern-requirement: " ++ symbol :: bad
          else
            bad,
        ))
      (omEmpty, [])
      requirements.rows
  (if backendName backend /= backendName requirements.target then
      ["extern-target-mismatch: " ++ backendName requirements.target]
    else
      [])
    ++ (if sameDomain domain requirements.runtimeDomain then
      []
    else
      ["extern-domain-mismatch"])
    ++ reverseL duplicates
    ++ flatMap
      (key => match omLookup key facts.factExterns
        Some fact if key /= fact.symbol =>
          ["extern-declaration-key-mismatch: " ++ key]
        _ => [])
      (omKeys facts.factExterns)
    ++ flatMap
      (symbol => match omLookup symbol facts.factExterns
        None => ["unknown-extern-declaration: " ++ symbol]
        Some fact =>
          validateShape fact
            ++ (match omLookup symbol selected
              None => ["missing-extern-requirement: " ++ symbol]
              Some row =>
                (if row.declaration.bindingKind /= fact.bindingKind
                    || row.declaration.hostBindings /= fact.hostBindings
                    || row.declaration.originModule /= fact.originModule
                    || row.declaration.declaredName /= fact.declaredName
                    || row.selectedBinding /= bindingFor backend fact then
                    ["extern-binding-mismatch: " ++ symbol]
                  else
                    [])
                  ++ (if row.declaration.callableShape /= fact.callableShape
                    || row.declaration.provenance /= fact.provenance then
                    ["extern-abi-mismatch: " ++ symbol]
                  else
                    [])
                  ++ (if row.selectedUses
                    /= reverseL (optionOr [] (omLookup symbol uses)) then
                    ["extern-use-mismatch: " ++ symbol]
                  else
                    [])))
      (omKeys uses)
    ++ flatMap
      (row =>
        if omHasKey row.declaration.symbol uses then
          []
        else
          ["unknown-extern-requirement: " ++ row.declaration.symbol])
      requirements.rows
    ++ (if requirements.nativePrototypes
      /= prototypesFor backend facts.factExterns then
      ["extern-prototype-mismatch"]
    else
      [])
    ++ flatMap validateShape requirements.nativePrototypes
    ++ validateAliases backend requirements.nativePrototypes

validateShape : ExternDeclFact -> List String
validateShape fact = match fact.callableShape
  None => ["missing-extern-abi: " ++ fact.symbol]
  Some shape =>
    let bad = ["extern-abi-mismatch: " ++ fact.symbol]
    if shape.writtenValueArity /= listLen shape.parameterHeads
      || shape.loweredCoreArity < shape.writtenValueArity
      || not (startsWith "v1:" shape.canonicalSignature)
      || shape.resultHead == "" then
      bad
    else match fact.bindingKind
      ForeignBinding =>
        if shape.loweredCoreArity /= shape.writtenValueArity then bad else []
      RuntimeBinding key => match (runtimeAbi key, catalogRow key)
        (Some canonical, Some _) => if shape /= canonical then bad else []
        _ => ["extern-binding-mismatch: " ++ fact.symbol]

sameDomain : RuntimeExternDomain -> RuntimeExternDomain -> Bool
sameDomain PreludeFreeRuntime PreludeFreeRuntime = True
sameDomain (LoadedRuntimeExterns a) (LoadedRuntimeExterns b) =
  map (ed => (ed.edName, sourceShape ed.edTy)) a
    == map (ed => (ed.edName, sourceShape ed.edTy)) b
sameDomain _ _ = False

-- Native prototypes remain complete even when no expression uses a declaration.
prototypesFor : Backend -> OrdMap ExternDeclFact -> List ExternDeclFact
prototypesFor LlvmBackend facts =
  filterMap
    (key => match omLookup key facts
      Some fact if fact.bindingKind == ForeignBinding
        && isSome (hostSymbol "c" fact.hostBindings) => Some fact
      _ => None)
    (omKeys facts)
prototypesFor _ _ = []

validateAliases : Backend -> List ExternDeclFact -> List String
validateAliases LlvmBackend rows =
  let (_, bad) =
    fold
      ((seen, bad) fact => match (
        hostSymbol "c" fact.hostBindings,
        fact.callableShape,
      )
        (Some host, Some shape) =>
          let abi = (shape.parameterHeads, shape.resultHead)
          (
            omInsert host abi seen,
            match omLookup host seen
              Some previous if previous /= abi =>
                "extern-abi-mismatch: C alias " ++ host :: bad
              _ => bad,
          )
        _ => (seen, bad))
      (omEmpty, [])
      rows
  reverseL bad
validateAliases _ _ = []
# DESUGAR
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" true) (mem "catalogRow" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true) (mem "ExternUse" true))))
(DUse false (UseGroup ("ir" "extern_uses") ((mem "collectExternUses" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternBindingKind" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi") ((mem "runtimeAbi" false) (mem "sourceShape" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "hostSymbol" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "startsWith" false))))
(DData Public "RequirementBinding" () ((variant "RuntimeRequirement" (ConPos (TyCon "String"))) (variant "ForeignRequirement" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "RequirementBinding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeRequirement" (PVar "__a0")) (PCon "RuntimeRequirement" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ForeignRequirement" (PVar "__a0") (PVar "__a1")) (PCon "ForeignRequirement" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RequirementBinding")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeRequirement" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeRequirement ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "ForeignRequirement" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ForeignRequirement ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "ExternRequirement" () ((variant "ExternRequirement" (ConNamed (field "declaration" (TyCon "ExternDeclFact")) (field "selectedBinding" (TyCon "RequirementBinding")) (field "selectedUses" (TyApp (TyCon "List") (TyCon "ExternUse")))))) ())
(DImpl true "Eq" ((TyCon "ExternRequirement")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ExternRequirement" ((rf "declaration" (PVar "__a0")) (rf "selectedBinding" (PVar "__a1")) (rf "selectedUses" (PVar "__a2"))) false) (PRec "ExternRequirement" ((rf "declaration" (PVar "__b0")) (rf "selectedBinding" (PVar "__b1")) (rf "selectedUses" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "ExternRequirement")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ExternRequirement" ((rf "declaration" (PVar "__a0")) (rf "selectedBinding" (PVar "__a1")) (rf "selectedUses" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ExternRequirement {")) (ELit (LString " declaration = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", selectedBinding = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", selectedUses = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "ExternRequirements" () ((variant "ExternRequirements" (ConNamed (field "target" (TyCon "Backend")) (field "runtimeDomain" (TyCon "RuntimeExternDomain")) (field "rows" (TyApp (TyCon "List") (TyCon "ExternRequirement"))) (field "nativePrototypes" (TyApp (TyCon "List") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "bindingFor" (TyFun (TyCon "Backend") (TyFun (TyCon "ExternDeclFact") (TyCon "RequirementBinding"))))
(DFunDef false "bindingFor" (PWild (PRec "ExternDeclFact" ((rf "bindingKind" (PCon "RuntimeBinding" (PVar "key")))) false)) (EApp (EVar "RuntimeRequirement") (EVar "key")))
(DFunDef false "bindingFor" ((PVar "backend") (PVar "fact")) (EBlock (DoLet false false (PVar "host") (EMatch (EVar "backend") (arm (PCon "LlvmBackend") () (ELit (LString "c"))) (arm (PCon "WasmBackend") () (ELit (LString "js"))) (arm (PCon "EvalBackend") () (ELit (LString "eval"))))) (DoExpr (EApp (EApp (EVar "ForeignRequirement") (EVar "host")) (EApp (EApp (EVar "hostSymbol") (EVar "host")) (EFieldAccess (EVar "fact") "hostBindings"))))))
(DTypeSig false "useIndex" (TyFun (TyApp (TyCon "List") (TyCon "ExternUse")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "ExternUse")))))
(DFunDef false "useIndex" () (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "use")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "use") "useSymbol")) (EBinOp "::" (EVar "use") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "use") "useSymbol")) (EVar "acc"))))) (EVar "acc")))) (EVar "omEmpty")))
(DTypeSig true "planExterns" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "ExternRequirements")))))
(DFunDef false "planExterns" ((PVar "target") (PVar "domain") (PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "useIndex") (EApp (EVar "collectExternUses") (EVar "cp")))) (DoExpr (ERecordCreate "ExternRequirements" ((fa "target" (EVar "target")) (fa "runtimeDomain" (EVar "domain")) (fa "nativePrototypes" (EApp (EApp (EVar "prototypesFor") (EVar "target")) (EFieldAccess (EVar "facts") "factExterns"))) (fa "rows" (EApp (EApp (EVar "filterMap") (ELam ((PVar "symbol")) (EApp (EApp (EVar "map") (ELam ((PVar "fact")) (ERecordCreate "ExternRequirement" ((fa "declaration" (EVar "fact")) (fa "selectedBinding" (EApp (EApp (EVar "bindingFor") (EVar "target")) (EVar "fact"))) (fa "selectedUses" (EApp (EVar "reverseL") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "uses"))))))))) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "facts") "factExterns"))))) (EApp (EVar "omKeys") (EVar "uses")))))))))
(DTypeSig true "requirementFacts" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact"))))
(DFunDef false "requirementFacts" ((PVar "requirements")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (EFieldAccess (EVar "row") "declaration")) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EVar "requirements") "rows")))
(DTypeSig true "requirementHostRows" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "requirementHostRows" ((PVar "requirements")) (EApp (EApp (EVar "filterMap") (ELam ((PVar "row")) (EMatch (ETuple (EFieldAccess (EVar "row") "selectedBinding") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "callableShape")) (arm (PTuple (PCon "ForeignRequirement" PWild (PCon "Some" (PVar "host"))) (PCon "Some" (PVar "shape"))) () (EApp (EVar "Some") (ETuple (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol") (ETuple (EVar "host") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EVar "None"))))) (EFieldAccess (EVar "requirements") "rows")))
(DTypeSig true "validateExternRequirements" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "validateExternRequirements" ((PVar "backend") (PVar "domain") (PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts"))) (PVar "requirements")) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "useIndex") (EApp (EVar "collectExternUses") (EVar "cp")))) (DoLet false false (PTuple (PVar "selected") (PVar "duplicates")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "index") (PVar "bad")) (PVar "row")) (EBlock (DoLet false false (PVar "symbol") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (DoExpr (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (EVar "row")) (EVar "index")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "symbol")) (EVar "index")) (EBinOp "::" (EBinOp "++" (ELit (LString "duplicate-extern-requirement: ")) (EVar "symbol")) (EVar "bad")) (EVar "bad"))))))) (ETuple (EVar "omEmpty") (EListLit))) (EFieldAccess (EVar "requirements") "rows"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "/=" (EApp (EVar "backendName") (EVar "backend")) (EApp (EVar "backendName") (EFieldAccess (EVar "requirements") "target"))) (EListLit (EBinOp "++" (ELit (LString "extern-target-mismatch: ")) (EApp (EVar "backendName") (EFieldAccess (EVar "requirements") "target")))) (EListLit)) (EIf (EApp (EApp (EVar "sameDomain") (EVar "domain")) (EFieldAccess (EVar "requirements") "runtimeDomain")) (EListLit) (EListLit (ELit (LString "extern-domain-mismatch"))))) (EApp (EVar "reverseL") (EVar "duplicates"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) ((GBool (EBinOp "/=" (EVar "key") (EFieldAccess (EVar "fact") "symbol")))) (EListLit (EBinOp "++" (ELit (LString "extern-declaration-key-mismatch: ")) (EVar "key")))) (arm PWild () (EListLit))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "unknown-extern-declaration: ")) (EVar "symbol")))) (arm (PCon "Some" (PVar "fact")) () (EBinOp "++" (EApp (EVar "validateShape") (EVar "fact")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "selected")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-requirement: ")) (EVar "symbol")))) (arm (PCon "Some" (PVar "row")) () (EBinOp "++" (EBinOp "++" (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "bindingKind") (EFieldAccess (EVar "fact") "bindingKind")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "hostBindings") (EFieldAccess (EVar "fact") "hostBindings"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "originModule") (EFieldAccess (EVar "fact") "originModule"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "declaredName") (EFieldAccess (EVar "fact") "declaredName"))) (EBinOp "/=" (EFieldAccess (EVar "row") "selectedBinding") (EApp (EApp (EVar "bindingFor") (EVar "backend")) (EVar "fact")))) (EListLit (EBinOp "++" (ELit (LString "extern-binding-mismatch: ")) (EVar "symbol"))) (EListLit)) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "callableShape") (EFieldAccess (EVar "fact") "callableShape")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "provenance") (EFieldAccess (EVar "fact") "provenance"))) (EListLit (EBinOp "++" (ELit (LString "extern-abi-mismatch: ")) (EVar "symbol"))) (EListLit))) (EIf (EBinOp "/=" (EFieldAccess (EVar "row") "selectedUses") (EApp (EVar "reverseL") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "uses"))))) (EListLit (EBinOp "++" (ELit (LString "extern-use-mismatch: ")) (EVar "symbol"))) (EListLit)))))))))) (EApp (EVar "omKeys") (EVar "uses")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "row")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (EVar "uses")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "unknown-extern-requirement: ")) (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")))))) (EFieldAccess (EVar "requirements") "rows"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "requirements") "nativePrototypes") (EApp (EApp (EVar "prototypesFor") (EVar "backend")) (EFieldAccess (EVar "facts") "factExterns"))) (EListLit (ELit (LString "extern-prototype-mismatch"))) (EListLit))) (EApp (EApp (EVar "flatMap") (EVar "validateShape")) (EFieldAccess (EVar "requirements") "nativePrototypes"))) (EApp (EApp (EVar "validateAliases") (EVar "backend")) (EFieldAccess (EVar "requirements") "nativePrototypes"))))))
(DTypeSig false "validateShape" (TyFun (TyCon "ExternDeclFact") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateShape" ((PVar "fact")) (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-abi: ")) (EFieldAccess (EVar "fact") "symbol")))) (arm (PCon "Some" (PVar "shape")) () (EBlock (DoLet false false (PVar "bad") (EListLit (EBinOp "++" (ELit (LString "extern-abi-mismatch: ")) (EFieldAccess (EVar "fact") "symbol")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "shape") "writtenValueArity") (EApp (EVar "listLen") (EFieldAccess (EVar "shape") "parameterHeads"))) (EBinOp "<" (EFieldAccess (EVar "shape") "loweredCoreArity") (EFieldAccess (EVar "shape") "writtenValueArity"))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "v1:"))) (EFieldAccess (EVar "shape") "canonicalSignature")))) (EBinOp "==" (EFieldAccess (EVar "shape") "resultHead") (ELit (LString "")))) (EVar "bad") (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "ForeignBinding") () (EIf (EBinOp "/=" (EFieldAccess (EVar "shape") "loweredCoreArity") (EFieldAccess (EVar "shape") "writtenValueArity")) (EVar "bad") (EListLit))) (arm (PCon "RuntimeBinding" (PVar "key")) () (EMatch (ETuple (EApp (EVar "runtimeAbi") (EVar "key")) (EApp (EVar "catalogRow") (EVar "key"))) (arm (PTuple (PCon "Some" (PVar "canonical")) (PCon "Some" PWild)) () (EIf (EBinOp "/=" (EVar "shape") (EVar "canonical")) (EVar "bad") (EListLit))) (arm PWild () (EListLit (EBinOp "++" (ELit (LString "extern-binding-mismatch: ")) (EFieldAccess (EVar "fact") "symbol")))))))))))))
(DTypeSig false "sameDomain" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "RuntimeExternDomain") (TyCon "Bool"))))
(DFunDef false "sameDomain" ((PCon "PreludeFreeRuntime") (PCon "PreludeFreeRuntime")) (EVar "True"))
(DFunDef false "sameDomain" ((PCon "LoadedRuntimeExterns" (PVar "a")) (PCon "LoadedRuntimeExterns" (PVar "b"))) (EBinOp "==" (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))))) (EVar "a")) (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))))) (EVar "b"))))
(DFunDef false "sameDomain" (PWild PWild) (EVar "False"))
(DTypeSig false "prototypesFor" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyApp (TyCon "List") (TyCon "ExternDeclFact")))))
(DFunDef false "prototypesFor" ((PCon "LlvmBackend") (PVar "facts")) (EApp (EApp (EVar "filterMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "facts")) (arm (PCon "Some" (PVar "fact")) ((GBool (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "fact") "bindingKind") (EVar "ForeignBinding")) (EApp (EVar "isSome") (EApp (EApp (EVar "hostSymbol") (ELit (LString "c"))) (EFieldAccess (EVar "fact") "hostBindings")))))) (EApp (EVar "Some") (EVar "fact"))) (arm PWild () (EVar "None"))))) (EApp (EVar "omKeys") (EVar "facts"))))
(DFunDef false "prototypesFor" (PWild PWild) (EListLit))
(DTypeSig false "validateAliases" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "ExternDeclFact")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateAliases" ((PCon "LlvmBackend") (PVar "rows")) (EBlock (DoLet false false (PTuple PWild (PVar "bad")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "seen") (PVar "bad")) (PVar "fact")) (EMatch (ETuple (EApp (EApp (EVar "hostSymbol") (ELit (LString "c"))) (EFieldAccess (EVar "fact") "hostBindings")) (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "Some" (PVar "host")) (PCon "Some" (PVar "shape"))) () (EBlock (DoLet false false (PVar "abi") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "host")) (EVar "abi")) (EVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "host")) (EVar "seen")) (arm (PCon "Some" (PVar "previous")) ((GBool (EBinOp "/=" (EVar "previous") (EVar "abi")))) (EBinOp "::" (EBinOp "++" (ELit (LString "extern-abi-mismatch: C alias ")) (EVar "host")) (EVar "bad"))) (arm PWild () (EVar "bad"))))))) (arm PWild () (ETuple (EVar "seen") (EVar "bad")))))) (ETuple (EVar "omEmpty") (EListLit))) (EVar "rows"))) (DoExpr (EApp (EVar "reverseL") (EVar "bad")))))
(DFunDef false "validateAliases" (PWild PWild) (EListLit))
# MARK
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" true) (mem "catalogRow" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true) (mem "ExternUse" true))))
(DUse false (UseGroup ("ir" "extern_uses") ((mem "collectExternUses" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternBindingKind" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi") ((mem "runtimeAbi" false) (mem "sourceShape" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "hostSymbol" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "startsWith" false))))
(DData Public "RequirementBinding" () ((variant "RuntimeRequirement" (ConPos (TyCon "String"))) (variant "ForeignRequirement" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "RequirementBinding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeRequirement" (PVar "__a0")) (PCon "RuntimeRequirement" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ForeignRequirement" (PVar "__a0") (PVar "__a1")) (PCon "ForeignRequirement" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RequirementBinding")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeRequirement" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeRequirement ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "ForeignRequirement" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ForeignRequirement ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "ExternRequirement" () ((variant "ExternRequirement" (ConNamed (field "declaration" (TyCon "ExternDeclFact")) (field "selectedBinding" (TyCon "RequirementBinding")) (field "selectedUses" (TyApp (TyCon "List") (TyCon "ExternUse")))))) ())
(DImpl true "Eq" ((TyCon "ExternRequirement")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ExternRequirement" ((rf "declaration" (PVar "__a0")) (rf "selectedBinding" (PVar "__a1")) (rf "selectedUses" (PVar "__a2"))) false) (PRec "ExternRequirement" ((rf "declaration" (PVar "__b0")) (rf "selectedBinding" (PVar "__b1")) (rf "selectedUses" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "ExternRequirement")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ExternRequirement" ((rf "declaration" (PVar "__a0")) (rf "selectedBinding" (PVar "__a1")) (rf "selectedUses" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ExternRequirement {")) (ELit (LString " declaration = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", selectedBinding = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", selectedUses = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "ExternRequirements" () ((variant "ExternRequirements" (ConNamed (field "target" (TyCon "Backend")) (field "runtimeDomain" (TyCon "RuntimeExternDomain")) (field "rows" (TyApp (TyCon "List") (TyCon "ExternRequirement"))) (field "nativePrototypes" (TyApp (TyCon "List") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "bindingFor" (TyFun (TyCon "Backend") (TyFun (TyCon "ExternDeclFact") (TyCon "RequirementBinding"))))
(DFunDef false "bindingFor" (PWild (PRec "ExternDeclFact" ((rf "bindingKind" (PCon "RuntimeBinding" (PVar "key")))) false)) (EApp (EVar "RuntimeRequirement") (EVar "key")))
(DFunDef false "bindingFor" ((PVar "backend") (PVar "fact")) (EBlock (DoLet false false (PVar "host") (EMatch (EVar "backend") (arm (PCon "LlvmBackend") () (ELit (LString "c"))) (arm (PCon "WasmBackend") () (ELit (LString "js"))) (arm (PCon "EvalBackend") () (ELit (LString "eval"))))) (DoExpr (EApp (EApp (EVar "ForeignRequirement") (EVar "host")) (EApp (EApp (EVar "hostSymbol") (EVar "host")) (EFieldAccess (EVar "fact") "hostBindings"))))))
(DTypeSig false "useIndex" (TyFun (TyApp (TyCon "List") (TyCon "ExternUse")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "ExternUse")))))
(DFunDef false "useIndex" () (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "use")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "use") "useSymbol")) (EBinOp "::" (EVar "use") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "use") "useSymbol")) (EVar "acc"))))) (EVar "acc")))) (EVar "omEmpty")))
(DTypeSig true "planExterns" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "ExternRequirements")))))
(DFunDef false "planExterns" ((PVar "target") (PVar "domain") (PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "useIndex") (EApp (EVar "collectExternUses") (EVar "cp")))) (DoExpr (ERecordCreate "ExternRequirements" ((fa "target" (EVar "target")) (fa "runtimeDomain" (EVar "domain")) (fa "nativePrototypes" (EApp (EApp (EVar "prototypesFor") (EVar "target")) (EFieldAccess (EVar "facts") "factExterns"))) (fa "rows" (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "symbol")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "fact")) (ERecordCreate "ExternRequirement" ((fa "declaration" (EVar "fact")) (fa "selectedBinding" (EApp (EApp (EVar "bindingFor") (EVar "target")) (EVar "fact"))) (fa "selectedUses" (EApp (EVar "reverseL") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "uses"))))))))) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "facts") "factExterns"))))) (EApp (EVar "omKeys") (EVar "uses")))))))))
(DTypeSig true "requirementFacts" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact"))))
(DFunDef false "requirementFacts" ((PVar "requirements")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (EFieldAccess (EVar "row") "declaration")) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EVar "requirements") "rows")))
(DTypeSig true "requirementHostRows" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "requirementHostRows" ((PVar "requirements")) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "row")) (EMatch (ETuple (EFieldAccess (EVar "row") "selectedBinding") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "callableShape")) (arm (PTuple (PCon "ForeignRequirement" PWild (PCon "Some" (PVar "host"))) (PCon "Some" (PVar "shape"))) () (EApp (EVar "Some") (ETuple (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol") (ETuple (EVar "host") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EVar "None"))))) (EFieldAccess (EVar "requirements") "rows")))
(DTypeSig true "validateExternRequirements" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "validateExternRequirements" ((PVar "backend") (PVar "domain") (PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts"))) (PVar "requirements")) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "useIndex") (EApp (EVar "collectExternUses") (EVar "cp")))) (DoLet false false (PTuple (PVar "selected") (PVar "duplicates")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "index") (PVar "bad")) (PVar "row")) (EBlock (DoLet false false (PVar "symbol") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (DoExpr (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (EVar "row")) (EMethodRef "index")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "symbol")) (EMethodRef "index")) (EBinOp "::" (EBinOp "++" (ELit (LString "duplicate-extern-requirement: ")) (EVar "symbol")) (EVar "bad")) (EVar "bad"))))))) (ETuple (EVar "omEmpty") (EListLit))) (EFieldAccess (EVar "requirements") "rows"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "/=" (EApp (EVar "backendName") (EVar "backend")) (EApp (EVar "backendName") (EFieldAccess (EVar "requirements") "target"))) (EListLit (EBinOp "++" (ELit (LString "extern-target-mismatch: ")) (EApp (EVar "backendName") (EFieldAccess (EVar "requirements") "target")))) (EListLit)) (EIf (EApp (EApp (EVar "sameDomain") (EVar "domain")) (EFieldAccess (EVar "requirements") "runtimeDomain")) (EListLit) (EListLit (ELit (LString "extern-domain-mismatch"))))) (EApp (EVar "reverseL") (EVar "duplicates"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) ((GBool (EBinOp "/=" (EVar "key") (EFieldAccess (EVar "fact") "symbol")))) (EListLit (EBinOp "++" (ELit (LString "extern-declaration-key-mismatch: ")) (EVar "key")))) (arm PWild () (EListLit))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "unknown-extern-declaration: ")) (EVar "symbol")))) (arm (PCon "Some" (PVar "fact")) () (EBinOp "++" (EApp (EVar "validateShape") (EVar "fact")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "selected")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-requirement: ")) (EVar "symbol")))) (arm (PCon "Some" (PVar "row")) () (EBinOp "++" (EBinOp "++" (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "bindingKind") (EFieldAccess (EVar "fact") "bindingKind")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "hostBindings") (EFieldAccess (EVar "fact") "hostBindings"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "originModule") (EFieldAccess (EVar "fact") "originModule"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "declaredName") (EFieldAccess (EVar "fact") "declaredName"))) (EBinOp "/=" (EFieldAccess (EVar "row") "selectedBinding") (EApp (EApp (EVar "bindingFor") (EVar "backend")) (EVar "fact")))) (EListLit (EBinOp "++" (ELit (LString "extern-binding-mismatch: ")) (EVar "symbol"))) (EListLit)) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "callableShape") (EFieldAccess (EVar "fact") "callableShape")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "row") "declaration") "provenance") (EFieldAccess (EVar "fact") "provenance"))) (EListLit (EBinOp "++" (ELit (LString "extern-abi-mismatch: ")) (EVar "symbol"))) (EListLit))) (EIf (EBinOp "/=" (EFieldAccess (EVar "row") "selectedUses") (EApp (EVar "reverseL") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EVar "uses"))))) (EListLit (EBinOp "++" (ELit (LString "extern-use-mismatch: ")) (EVar "symbol"))) (EListLit)))))))))) (EApp (EVar "omKeys") (EVar "uses")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "row")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")) (EVar "uses")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "unknown-extern-requirement: ")) (EFieldAccess (EFieldAccess (EVar "row") "declaration") "symbol")))))) (EFieldAccess (EVar "requirements") "rows"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "requirements") "nativePrototypes") (EApp (EApp (EVar "prototypesFor") (EVar "backend")) (EFieldAccess (EVar "facts") "factExterns"))) (EListLit (ELit (LString "extern-prototype-mismatch"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (EVar "validateShape")) (EFieldAccess (EVar "requirements") "nativePrototypes"))) (EApp (EApp (EVar "validateAliases") (EVar "backend")) (EFieldAccess (EVar "requirements") "nativePrototypes"))))))
(DTypeSig false "validateShape" (TyFun (TyCon "ExternDeclFact") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateShape" ((PVar "fact")) (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-abi: ")) (EFieldAccess (EVar "fact") "symbol")))) (arm (PCon "Some" (PVar "shape")) () (EBlock (DoLet false false (PVar "bad") (EListLit (EBinOp "++" (ELit (LString "extern-abi-mismatch: ")) (EFieldAccess (EVar "fact") "symbol")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "shape") "writtenValueArity") (EApp (EVar "listLen") (EFieldAccess (EVar "shape") "parameterHeads"))) (EBinOp "<" (EFieldAccess (EVar "shape") "loweredCoreArity") (EFieldAccess (EVar "shape") "writtenValueArity"))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "v1:"))) (EFieldAccess (EVar "shape") "canonicalSignature")))) (EBinOp "==" (EFieldAccess (EVar "shape") "resultHead") (ELit (LString "")))) (EVar "bad") (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "ForeignBinding") () (EIf (EBinOp "/=" (EFieldAccess (EVar "shape") "loweredCoreArity") (EFieldAccess (EVar "shape") "writtenValueArity")) (EVar "bad") (EListLit))) (arm (PCon "RuntimeBinding" (PVar "key")) () (EMatch (ETuple (EApp (EVar "runtimeAbi") (EVar "key")) (EApp (EVar "catalogRow") (EVar "key"))) (arm (PTuple (PCon "Some" (PVar "canonical")) (PCon "Some" PWild)) () (EIf (EBinOp "/=" (EVar "shape") (EVar "canonical")) (EVar "bad") (EListLit))) (arm PWild () (EListLit (EBinOp "++" (ELit (LString "extern-binding-mismatch: ")) (EFieldAccess (EVar "fact") "symbol")))))))))))))
(DTypeSig false "sameDomain" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "RuntimeExternDomain") (TyCon "Bool"))))
(DFunDef false "sameDomain" ((PCon "PreludeFreeRuntime") (PCon "PreludeFreeRuntime")) (EVar "True"))
(DFunDef false "sameDomain" ((PCon "LoadedRuntimeExterns" (PVar "a")) (PCon "LoadedRuntimeExterns" (PVar "b"))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))))) (EVar "a")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))))) (EVar "b"))))
(DFunDef false "sameDomain" (PWild PWild) (EVar "False"))
(DTypeSig false "prototypesFor" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyApp (TyCon "List") (TyCon "ExternDeclFact")))))
(DFunDef false "prototypesFor" ((PCon "LlvmBackend") (PVar "facts")) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "facts")) (arm (PCon "Some" (PVar "fact")) ((GBool (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "fact") "bindingKind") (EVar "ForeignBinding")) (EApp (EVar "isSome") (EApp (EApp (EVar "hostSymbol") (ELit (LString "c"))) (EFieldAccess (EVar "fact") "hostBindings")))))) (EApp (EVar "Some") (EVar "fact"))) (arm PWild () (EVar "None"))))) (EApp (EVar "omKeys") (EVar "facts"))))
(DFunDef false "prototypesFor" (PWild PWild) (EListLit))
(DTypeSig false "validateAliases" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "ExternDeclFact")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateAliases" ((PCon "LlvmBackend") (PVar "rows")) (EBlock (DoLet false false (PTuple PWild (PVar "bad")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "seen") (PVar "bad")) (PVar "fact")) (EMatch (ETuple (EApp (EApp (EVar "hostSymbol") (ELit (LString "c"))) (EFieldAccess (EVar "fact") "hostBindings")) (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "Some" (PVar "host")) (PCon "Some" (PVar "shape"))) () (EBlock (DoLet false false (PVar "abi") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "host")) (EVar "abi")) (EVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "host")) (EVar "seen")) (arm (PCon "Some" (PVar "previous")) ((GBool (EBinOp "/=" (EVar "previous") (EVar "abi")))) (EBinOp "::" (EBinOp "++" (ELit (LString "extern-abi-mismatch: C alias ")) (EVar "host")) (EVar "bad"))) (arm PWild () (EVar "bad"))))))) (arm PWild () (ETuple (EVar "seen") (EVar "bad")))))) (ETuple (EVar "omEmpty") (EListLit))) (EVar "rows"))) (DoExpr (EApp (EVar "reverseL") (EVar "bad")))))
(DFunDef false "validateAliases" (PWild PWild) (EListLit))
