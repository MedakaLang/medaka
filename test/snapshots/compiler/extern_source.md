# META
source_lines=130
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Decl(..), ExternDecl(..), externBindings}
import types.runtime_abi_types.{CallableShape(..)}
import types.runtime_abi.{runtimeAbi, sourceShape}
import support.ordmap.{omEmpty, omFromPairs, omLookup}
import support.util.{listLen}
import string.{byteLength}
import array as A

-- Runtime bindings carry catalog identity; foreign bindings use host declarations.
-- lint-disable-next-line rule-clone-type
public export data ExternBindingKind =
  | ForeignBinding
  | RuntimeBinding String
  deriving (Eq, Debug)

public export data ExternProvenance =
  | CheckedSource
  | RawSource
  | NoSourceSignature
  deriving (Eq, Debug)

public export data ExternSource = ExternSource {
  sourceSymbol : String,
  sourceModule : String,
  sourceName : String,
  sourceBinding : ExternBindingKind,
  sourceHosts : List (String, String),
  sourceAbi : Option CallableShape,
  sourceProvenance : ExternProvenance,
} deriving (Eq, Debug)

export type ExternHeadRows = List (String, (List (String, String), (List String, String)))

lenKey : String -> String
lenKey s = "\{intToString (byteLength s)}:\{s}"

export
runtimeExternSymbol : String -> String
runtimeExternSymbol key = "$extern$r" ++ lenKey key

export
sourceExternSymbol : String -> String -> String
sourceExternSymbol mid name = "$extern$u\{lenKey mid}\{lenKey name}"

export
sourceExterns : ExternProvenance ->
  String ->
  ExternHeadRows ->
  List Decl ->
  List ExternSource
sourceExterns provenance mid heads decls =
  let index = omFromPairs heads omEmpty
  map
    (ed =>
      let raw = sourceShape ed.edTy
      let shape = match omLookup ed.edName index
        Some (_, (params, ret)) => { raw |
          writtenValueArity = listLen params,
          loweredCoreArity = listLen params,
          parameterHeads = params,
          resultHead = ret,
        }
        None => raw
      let (kind, abi) = match runtimeAbi ed.edName
        Some canonical => (RuntimeBinding ed.edName, canonical)
        None => (ForeignBinding, shape)
      ExternSource {
        sourceSymbol = sourceExternSymbol mid ed.edName,
        sourceModule = mid,
        sourceName = ed.edName,
        sourceBinding = kind,
        sourceHosts = map (b => (b.ebHost, b.ebSymbol)) (externBindings ed),
        sourceAbi = Some abi,
        sourceProvenance = provenance,
      })
    (externRecords decls)

externRecords : List Decl -> List ExternDecl
externRecords [] = []
externRecords ((DExtern ed) :: rest) = ed :: externRecords rest
externRecords ((DAttrib _ inner) :: rest) = externRecords (inner :: rest)
externRecords (_ :: rest) = externRecords rest

export
externSourceHeadRows : List ExternSource -> ExternHeadRows
externSourceHeadRows sources =
  flatMap
    (s => match (s.sourceBinding, s.sourceAbi)
      (ForeignBinding, Some shape) => [
        (
          s.sourceSymbol,
          (s.sourceHosts, (shape.parameterHeads, shape.resultHead)),
        ),
      ]
      _ => [])
    sources

export
externDisplayName : String -> Option String
externDisplayName symbol =
  if stringStartsWith "$extern$u" symbol then
    let bytes = stringToUtf8Bytes (stringSlice 9 (stringLength symbol) symbol)
    match readLenKey bytes
      Some (_, rest) => map fst (readLenKey rest)
      None => None
  else if stringStartsWith "$extern$r" symbol then
    map
      fst
      (readLenKey
        (stringToUtf8Bytes (stringSlice 9 (stringLength symbol) symbol)))
  else
    None

readLenKey : Array Int -> Option (String, Array Int)
readLenKey bytes = readLenDigits bytes 0 0

readLenDigits : Array Int -> Int -> Int -> Option (String, Array Int)
readLenDigits bytes i n
  | i >= arrayLength bytes = None
  | otherwise =
    let b = arrayGetUnsafe i bytes
    if b == 58 && i > 0 && n <= arrayLength bytes - i - 1 then
      Some (
        stringFromUtf8Bytes (A.sliceClamped (i + 1) (i + 1 + n) bytes),
        A.drop (i + 1 + n) bytes,
      )
    else if b >= 48 && b <= 57 then
      readLenDigits bytes (i + 1) (n * 10 + b - 48)
    else
      None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "externBindings" false))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi") ((mem "runtimeAbi" false) (mem "sourceShape" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("string") ((mem "byteLength" false))))
(DUse false (UseAlias ("array") "A"))
(DData Public "ExternBindingKind" () ((variant "ForeignBinding" (ConPos)) (variant "RuntimeBinding" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "ExternBindingKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ForeignBinding") (PCon "ForeignBinding")) () (EVar "True")) (arm (PTuple (PCon "RuntimeBinding" (PVar "__a0")) (PCon "RuntimeBinding" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExternBindingKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ForeignBinding") () (ELit (LString "ForeignBinding"))) (arm (PCon "RuntimeBinding" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeBinding ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "ExternProvenance" () ((variant "CheckedSource" (ConPos)) (variant "RawSource" (ConPos)) (variant "NoSourceSignature" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ExternProvenance")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "CheckedSource") (PCon "CheckedSource")) () (EVar "True")) (arm (PTuple (PCon "RawSource") (PCon "RawSource")) () (EVar "True")) (arm (PTuple (PCon "NoSourceSignature") (PCon "NoSourceSignature")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExternProvenance")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "CheckedSource") () (ELit (LString "CheckedSource"))) (arm (PCon "RawSource") () (ELit (LString "RawSource"))) (arm (PCon "NoSourceSignature") () (ELit (LString "NoSourceSignature")))))))
(DData Public "ExternSource" () ((variant "ExternSource" (ConNamed (field "sourceSymbol" (TyCon "String")) (field "sourceModule" (TyCon "String")) (field "sourceName" (TyCon "String")) (field "sourceBinding" (TyCon "ExternBindingKind")) (field "sourceHosts" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "sourceAbi" (TyApp (TyCon "Option") (TyCon "CallableShape"))) (field "sourceProvenance" (TyCon "ExternProvenance"))))) ())
(DImpl true "Eq" ((TyCon "ExternSource")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__a0")) (rf "sourceModule" (PVar "__a1")) (rf "sourceName" (PVar "__a2")) (rf "sourceBinding" (PVar "__a3")) (rf "sourceHosts" (PVar "__a4")) (rf "sourceAbi" (PVar "__a5")) (rf "sourceProvenance" (PVar "__a6"))) false) (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__b0")) (rf "sourceModule" (PVar "__b1")) (rf "sourceName" (PVar "__b2")) (rf "sourceBinding" (PVar "__b3")) (rf "sourceHosts" (PVar "__b4")) (rf "sourceAbi" (PVar "__b5")) (rf "sourceProvenance" (PVar "__b6"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EVar "eq") (EVar "__a6")) (EVar "__b6"))))))))
(DImpl true "Debug" ((TyCon "ExternSource")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__a0")) (rf "sourceModule" (PVar "__a1")) (rf "sourceName" (PVar "__a2")) (rf "sourceBinding" (PVar "__a3")) (rf "sourceHosts" (PVar "__a4")) (rf "sourceAbi" (PVar "__a5")) (rf "sourceProvenance" (PVar "__a6"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ExternSource {")) (ELit (LString " sourceSymbol = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", sourceModule = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", sourceName = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", sourceBinding = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", sourceHosts = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString ", sourceAbi = "))) (EApp (EVar "debug") (EVar "__a5"))) (ELit (LString ", sourceProvenance = "))) (EApp (EVar "debug") (EVar "__a6"))) (ELit (LString " }"))))))))
(DTypeAlias true "ExternHeadRows" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DTypeSig false "lenKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lenKey" ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "byteLength") (EVar "s"))))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "s"))) (ELit (LString ""))))
(DTypeSig true "runtimeExternSymbol" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimeExternSymbol" ((PVar "key")) (EBinOp "++" (ELit (LString "$extern$r")) (EApp (EVar "lenKey") (EVar "key"))))
(DTypeSig true "sourceExternSymbol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sourceExternSymbol" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$extern$u")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "mid")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "sourceExterns" (TyFun (TyCon "ExternProvenance") (TyFun (TyCon "String") (TyFun (TyCon "ExternHeadRows") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternSource")))))))
(DFunDef false "sourceExterns" ((PVar "provenance") (PVar "mid") (PVar "heads") (PVar "decls")) (EBlock (DoLet false false (PVar "index") (EApp (EApp (EVar "omFromPairs") (EVar "heads")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))) (DoLet false false (PVar "shape") (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "ed") "edName")) (EVar "index")) (arm (PCon "Some" (PTuple PWild (PTuple (PVar "params") (PVar "ret")))) () (ERecordUpdate (EVar "raw") ((fa "writtenValueArity" (EApp (EVar "listLen") (EVar "params"))) (fa "loweredCoreArity" (EApp (EVar "listLen") (EVar "params"))) (fa "parameterHeads" (EVar "params")) (fa "resultHead" (EVar "ret"))))) (arm (PCon "None") () (EVar "raw")))) (DoLet false false (PTuple (PVar "kind") (PVar "abi")) (EMatch (EApp (EVar "runtimeAbi") (EFieldAccess (EVar "ed") "edName")) (arm (PCon "Some" (PVar "canonical")) () (ETuple (EApp (EVar "RuntimeBinding") (EFieldAccess (EVar "ed") "edName")) (EVar "canonical"))) (arm (PCon "None") () (ETuple (EVar "ForeignBinding") (EVar "shape"))))) (DoExpr (ERecordCreate "ExternSource" ((fa "sourceSymbol" (EApp (EApp (EVar "sourceExternSymbol") (EVar "mid")) (EFieldAccess (EVar "ed") "edName"))) (fa "sourceModule" (EVar "mid")) (fa "sourceName" (EFieldAccess (EVar "ed") "edName")) (fa "sourceBinding" (EVar "kind")) (fa "sourceHosts" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EFieldAccess (EVar "b") "ebHost") (EFieldAccess (EVar "b") "ebSymbol")))) (EApp (EVar "externBindings") (EVar "ed")))) (fa "sourceAbi" (EApp (EVar "Some") (EVar "abi"))) (fa "sourceProvenance" (EVar "provenance")))))))) (EApp (EVar "externRecords") (EVar "decls"))))))
(DTypeSig false "externRecords" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externRecords" ((PList)) (EListLit))
(DFunDef false "externRecords" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externRecords") (EVar "rest"))))
(DFunDef false "externRecords" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "externRecords") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "externRecords" ((PCons PWild (PVar "rest"))) (EApp (EVar "externRecords") (EVar "rest")))
(DTypeSig true "externSourceHeadRows" (TyFun (TyApp (TyCon "List") (TyCon "ExternSource")) (TyCon "ExternHeadRows")))
(DFunDef false "externSourceHeadRows" ((PVar "sources")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EMatch (ETuple (EFieldAccess (EVar "s") "sourceBinding") (EFieldAccess (EVar "s") "sourceAbi")) (arm (PTuple (PCon "ForeignBinding") (PCon "Some" (PVar "shape"))) () (EListLit (ETuple (EFieldAccess (EVar "s") "sourceSymbol") (ETuple (EFieldAccess (EVar "s") "sourceHosts") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EListLit))))) (EVar "sources")))
(DTypeSig true "externDisplayName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "externDisplayName" ((PVar "symbol")) (EIf (EApp (EApp (EVar "stringStartsWith") (ELit (LString "$extern$u"))) (EVar "symbol")) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "symbol"))) (EVar "symbol")))) (DoExpr (EMatch (EApp (EVar "readLenKey") (EVar "bytes")) (arm (PCon "Some" (PTuple PWild (PVar "rest"))) () (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "readLenKey") (EVar "rest")))) (arm (PCon "None") () (EVar "None"))))) (EIf (EApp (EApp (EVar "stringStartsWith") (ELit (LString "$extern$r"))) (EVar "symbol")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "readLenKey") (EApp (EVar "stringToUtf8Bytes") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "symbol"))) (EVar "symbol"))))) (EVar "None"))))
(DTypeSig false "readLenKey" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "readLenKey" ((PVar "bytes")) (EApp (EApp (EApp (EVar "readLenDigits") (EVar "bytes")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "readLenDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "readLenDigits" ((PVar "bytes") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b") (ELit (LInt 58))) (EBinOp ">" (EVar "i") (ELit (LInt 0)))) (EBinOp "<=" (EVar "n") (EBinOp "-" (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (EVar "i")) (ELit (LInt 1))))) (EApp (EVar "Some") (ETuple (EApp (EVar "stringFromUtf8Bytes") (EApp (EApp (EApp (EVar "A.sliceClamped") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EVar "bytes"))) (EApp (EApp (EVar "A.drop") (EBinOp "+" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EVar "bytes")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 48))) (EBinOp "<=" (EVar "b") (ELit (LInt 57)))) (EApp (EApp (EApp (EVar "readLenDigits") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "n") (ELit (LInt 10))) (EVar "b")) (ELit (LInt 48)))) (EVar "None"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "externBindings" false))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi") ((mem "runtimeAbi" false) (mem "sourceShape" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("string") ((mem "byteLength" false))))
(DUse false (UseAlias ("array") "A"))
(DData Public "ExternBindingKind" () ((variant "ForeignBinding" (ConPos)) (variant "RuntimeBinding" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "ExternBindingKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ForeignBinding") (PCon "ForeignBinding")) () (EVar "True")) (arm (PTuple (PCon "RuntimeBinding" (PVar "__a0")) (PCon "RuntimeBinding" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExternBindingKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ForeignBinding") () (ELit (LString "ForeignBinding"))) (arm (PCon "RuntimeBinding" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeBinding ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "ExternProvenance" () ((variant "CheckedSource" (ConPos)) (variant "RawSource" (ConPos)) (variant "NoSourceSignature" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ExternProvenance")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "CheckedSource") (PCon "CheckedSource")) () (EVar "True")) (arm (PTuple (PCon "RawSource") (PCon "RawSource")) () (EVar "True")) (arm (PTuple (PCon "NoSourceSignature") (PCon "NoSourceSignature")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExternProvenance")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "CheckedSource") () (ELit (LString "CheckedSource"))) (arm (PCon "RawSource") () (ELit (LString "RawSource"))) (arm (PCon "NoSourceSignature") () (ELit (LString "NoSourceSignature")))))))
(DData Public "ExternSource" () ((variant "ExternSource" (ConNamed (field "sourceSymbol" (TyCon "String")) (field "sourceModule" (TyCon "String")) (field "sourceName" (TyCon "String")) (field "sourceBinding" (TyCon "ExternBindingKind")) (field "sourceHosts" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "sourceAbi" (TyApp (TyCon "Option") (TyCon "CallableShape"))) (field "sourceProvenance" (TyCon "ExternProvenance"))))) ())
(DImpl true "Eq" ((TyCon "ExternSource")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__a0")) (rf "sourceModule" (PVar "__a1")) (rf "sourceName" (PVar "__a2")) (rf "sourceBinding" (PVar "__a3")) (rf "sourceHosts" (PVar "__a4")) (rf "sourceAbi" (PVar "__a5")) (rf "sourceProvenance" (PVar "__a6"))) false) (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__b0")) (rf "sourceModule" (PVar "__b1")) (rf "sourceName" (PVar "__b2")) (rf "sourceBinding" (PVar "__b3")) (rf "sourceHosts" (PVar "__b4")) (rf "sourceAbi" (PVar "__b5")) (rf "sourceProvenance" (PVar "__b6"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EMethodRef "eq") (EVar "__a6")) (EVar "__b6"))))))))
(DImpl true "Debug" ((TyCon "ExternSource")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "ExternSource" ((rf "sourceSymbol" (PVar "__a0")) (rf "sourceModule" (PVar "__a1")) (rf "sourceName" (PVar "__a2")) (rf "sourceBinding" (PVar "__a3")) (rf "sourceHosts" (PVar "__a4")) (rf "sourceAbi" (PVar "__a5")) (rf "sourceProvenance" (PVar "__a6"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ExternSource {")) (ELit (LString " sourceSymbol = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", sourceModule = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", sourceName = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", sourceBinding = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", sourceHosts = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString ", sourceAbi = "))) (EApp (EMethodRef "debug") (EVar "__a5"))) (ELit (LString ", sourceProvenance = "))) (EApp (EMethodRef "debug") (EVar "__a6"))) (ELit (LString " }"))))))))
(DTypeAlias true "ExternHeadRows" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DTypeSig false "lenKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lenKey" ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "byteLength") (EVar "s"))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ""))))
(DTypeSig true "runtimeExternSymbol" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimeExternSymbol" ((PVar "key")) (EBinOp "++" (ELit (LString "$extern$r")) (EApp (EVar "lenKey") (EVar "key"))))
(DTypeSig true "sourceExternSymbol" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sourceExternSymbol" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$extern$u")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "mid")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "sourceExterns" (TyFun (TyCon "ExternProvenance") (TyFun (TyCon "String") (TyFun (TyCon "ExternHeadRows") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternSource")))))))
(DFunDef false "sourceExterns" ((PVar "provenance") (PVar "mid") (PVar "heads") (PVar "decls")) (EBlock (DoLet false false (PVar "index") (EApp (EApp (EVar "omFromPairs") (EVar "heads")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))) (DoLet false false (PVar "shape") (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "ed") "edName")) (EMethodRef "index")) (arm (PCon "Some" (PTuple PWild (PTuple (PVar "params") (PVar "ret")))) () (ERecordUpdate (EVar "raw") ((fa "writtenValueArity" (EApp (EVar "listLen") (EVar "params"))) (fa "loweredCoreArity" (EApp (EVar "listLen") (EVar "params"))) (fa "parameterHeads" (EVar "params")) (fa "resultHead" (EVar "ret"))))) (arm (PCon "None") () (EVar "raw")))) (DoLet false false (PTuple (PVar "kind") (PVar "abi")) (EMatch (EApp (EVar "runtimeAbi") (EFieldAccess (EVar "ed") "edName")) (arm (PCon "Some" (PVar "canonical")) () (ETuple (EApp (EVar "RuntimeBinding") (EFieldAccess (EVar "ed") "edName")) (EVar "canonical"))) (arm (PCon "None") () (ETuple (EVar "ForeignBinding") (EVar "shape"))))) (DoExpr (ERecordCreate "ExternSource" ((fa "sourceSymbol" (EApp (EApp (EVar "sourceExternSymbol") (EVar "mid")) (EFieldAccess (EVar "ed") "edName"))) (fa "sourceModule" (EVar "mid")) (fa "sourceName" (EFieldAccess (EVar "ed") "edName")) (fa "sourceBinding" (EVar "kind")) (fa "sourceHosts" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EFieldAccess (EVar "b") "ebHost") (EFieldAccess (EVar "b") "ebSymbol")))) (EApp (EVar "externBindings") (EVar "ed")))) (fa "sourceAbi" (EApp (EVar "Some") (EVar "abi"))) (fa "sourceProvenance" (EVar "provenance")))))))) (EApp (EVar "externRecords") (EVar "decls"))))))
(DTypeSig false "externRecords" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externRecords" ((PList)) (EListLit))
(DFunDef false "externRecords" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externRecords") (EVar "rest"))))
(DFunDef false "externRecords" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "externRecords") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "externRecords" ((PCons PWild (PVar "rest"))) (EApp (EVar "externRecords") (EVar "rest")))
(DTypeSig true "externSourceHeadRows" (TyFun (TyApp (TyCon "List") (TyCon "ExternSource")) (TyCon "ExternHeadRows")))
(DFunDef false "externSourceHeadRows" ((PVar "sources")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EMatch (ETuple (EFieldAccess (EVar "s") "sourceBinding") (EFieldAccess (EVar "s") "sourceAbi")) (arm (PTuple (PCon "ForeignBinding") (PCon "Some" (PVar "shape"))) () (EListLit (ETuple (EFieldAccess (EVar "s") "sourceSymbol") (ETuple (EFieldAccess (EVar "s") "sourceHosts") (ETuple (EFieldAccess (EVar "shape") "parameterHeads") (EFieldAccess (EVar "shape") "resultHead")))))) (arm PWild () (EListLit))))) (EVar "sources")))
(DTypeSig true "externDisplayName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "externDisplayName" ((PVar "symbol")) (EIf (EApp (EApp (EVar "stringStartsWith") (ELit (LString "$extern$u"))) (EVar "symbol")) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "symbol"))) (EVar "symbol")))) (DoExpr (EMatch (EApp (EVar "readLenKey") (EVar "bytes")) (arm (PCon "Some" (PTuple PWild (PVar "rest"))) () (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "readLenKey") (EVar "rest")))) (arm (PCon "None") () (EVar "None"))))) (EIf (EApp (EApp (EVar "stringStartsWith") (ELit (LString "$extern$r"))) (EVar "symbol")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "readLenKey") (EApp (EVar "stringToUtf8Bytes") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "symbol"))) (EVar "symbol"))))) (EVar "None"))))
(DTypeSig false "readLenKey" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "readLenKey" ((PVar "bytes")) (EApp (EApp (EApp (EVar "readLenDigits") (EVar "bytes")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "readLenDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "readLenDigits" ((PVar "bytes") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b") (ELit (LInt 58))) (EBinOp ">" (EVar "i") (ELit (LInt 0)))) (EBinOp "<=" (EVar "n") (EBinOp "-" (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (EVar "i")) (ELit (LInt 1))))) (EApp (EVar "Some") (ETuple (EApp (EVar "stringFromUtf8Bytes") (EApp (EApp (EApp (EVar "A.sliceClamped") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EVar "bytes"))) (EApp (EApp (EVar "A.drop") (EBinOp "+" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EVar "bytes")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "b") (ELit (LInt 48))) (EBinOp "<=" (EVar "b") (ELit (LInt 57)))) (EApp (EApp (EApp (EVar "readLenDigits") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "n") (ELit (LInt 10))) (EVar "b")) (ELit (LInt 48)))) (EVar "None"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
