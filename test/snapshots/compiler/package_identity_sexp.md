# META
source_lines=98
stages=DESUGAR,MARK
# SOURCE
import backend.package_identity.{PackageIdentity(..), packageDefects}
import backend.runtime_layout.{abiVersion}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey}
import support.sexp_value.{SExp(..), parseSExp, renderSExp, atomInt}
import map.{entries}
import crypto.sha256_fast.{sha256Fast}
import bytes.{encodeUtf8}
import hex as Hex

hash : String -> String
hash text = Hex.encode (sha256Fast (encodeUtf8 text))

rows : List (String, Int) -> SExp
rows pairs =
  SList (map ((name, n) => SList [SAtom name, SAtom (intToString n)]) pairs)

payload : PackageIdentity -> SExp
payload p = SList [
  SAtom "package-identity",
  SAtom "1",
  SAtom (intToString p.abi),
  SAtom p.fingerprint,
  SAtom (intToString p.typeHigh),
  SAtom (intToString p.fileHigh),
  rows (entries p.types),
  rows (entries p.files),
]

export
encodePackageIdentity : PackageIdentity -> String
encodePackageIdentity p =
  let body = payload p
  renderSExp
    (SList [SAtom "medaka-package-abi", SAtom (hash (renderSExp body)), body])

readRows : SExp -> Result String (List (String, Int))
readRows (SList xs) = traverse readRow xs
readRows _ = Err "identity: expected rows"

readRow : SExp -> Result String (String, Int)
readRow (SList [SAtom name, n]) =
  map
    (v => (name, v))
    (mapErr (_ => "identity: invalid number") (atomInt "number" n))
readRow _ = Err "identity: invalid row"

uniqueRows : List (String, Int) -> Result String (OrdMap Int)
uniqueRows xs = uniqueRowsInto xs omEmpty

uniqueRowsInto : List (String, Int) -> OrdMap Int -> Result String (OrdMap Int)
uniqueRowsInto [] acc = Ok acc
uniqueRowsInto ((name, n) :: rest) acc =
  if omHasKey name acc then
    Err "identity: duplicate name"
  else
    uniqueRowsInto rest (omInsert name n acc)

readPayload : String -> SExp -> Result String PackageIdentity
readPayload expected (SList [SAtom "package-identity", SAtom version, abiNode, SAtom fingerprint, typeHighNode, fileHighNode, typeRows, fileRows]) =
  do
    if version /= "1" then Err "identity: incompatible format" else Ok ()
    abi <- mapErr (_ => "identity: invalid ABI") (atomInt "abi" abiNode)
    if abi /= abiVersion then Err "identity: incompatible ABI" else Ok ()
    if fingerprint /= expected then Err "identity: stale fingerprint" else Ok ()
    typeHigh <- mapErr
      (_ => "identity: invalid type high-water mark")
      (atomInt "typeHigh" typeHighNode)
    fileHigh <- mapErr
      (_ => "identity: invalid file high-water mark")
      (atomInt "fileHigh" fileHighNode)
    ts <- readRows typeRows
    fs <- readRows fileRows
    types <- uniqueRows ts
    files <- uniqueRows fs
    let p = PackageIdentity {
      fingerprint = fingerprint,
      abi = abi,
      types = types,
      files = files,
      typeHigh = typeHigh,
      fileHigh = fileHigh,
    }
    match packageDefects p
      [] => Ok p
      defects => Err (stringJoin "; " defects)
readPayload _ _ = Err "identity: malformed payload"

export
decodePackageIdentity : String -> String -> Result String PackageIdentity
decodePackageIdentity expected text = do
  node <- mapErr (_ => "identity: malformed metadata") (parseSExp text)
  match node
    SList [SAtom "medaka-package-abi", SAtom digest, body] =>
      if digest /= hash (renderSExp body) then
        Err "identity: integrity failure"
      else
        readPayload expected body
    _ => Err "identity: malformed envelope"
# DESUGAR
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" true) (mem "packageDefects" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "parseSExp" false) (mem "renderSExp" false) (mem "atomInt" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DTypeSig false "hash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hash" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "rows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "SExp")))
(DFunDef false "rows" ((PVar "pairs")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))) (EVar "pairs"))))
(DTypeSig false "payload" (TyFun (TyCon "PackageIdentity") (TyCon "SExp")))
(DFunDef false "payload" ((PVar "p")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "package-identity"))) (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "abi"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "p") "fingerprint")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "typeHigh"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "fileHigh"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "types"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "files"))))))
(DTypeSig true "encodePackageIdentity" (TyFun (TyCon "PackageIdentity") (TyCon "String")))
(DFunDef false "encodePackageIdentity" ((PVar "p")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "payload") (EVar "p"))) (DoExpr (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-package-abi"))) (EApp (EVar "SAtom") (EApp (EVar "hash") (EApp (EVar "renderSExp") (EVar "body")))) (EVar "body")))))))
(DTypeSig false "readRows" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readRows" ((PCon "SList" (PVar "xs"))) (EApp (EApp (EVar "traverse") (EVar "readRow")) (EVar "xs")))
(DFunDef false "readRows" (PWild) (EApp (EVar "Err") (ELit (LString "identity: expected rows"))))
(DTypeSig false "readRow" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "readRow" ((PCon "SList" (PList (PCon "SAtom" (PVar "name")) (PVar "n")))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EVar "name") (EVar "v")))) (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid number")))) (EApp (EApp (EVar "atomInt") (ELit (LString "number"))) (EVar "n")))))
(DFunDef false "readRow" (PWild) (EApp (EVar "Err") (ELit (LString "identity: invalid row"))))
(DTypeSig false "uniqueRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "uniqueRows" ((PVar "xs")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "uniqueRowsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "uniqueRowsInto" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "uniqueRowsInto" ((PCons (PTuple (PVar "name") (PVar "n")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "acc")) (EApp (EVar "Err") (ELit (LString "identity: duplicate name"))) (EApp (EApp (EVar "uniqueRowsInto") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "n")) (EVar "acc")))))
(DTypeSig false "readPayload" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PackageIdentity")))))
(DFunDef false "readPayload" ((PVar "expected") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "package-identity"))) (PCon "SAtom" (PVar "version")) (PVar "abiNode") (PCon "SAtom" (PVar "fingerprint")) (PVar "typeHighNode") (PVar "fileHighNode") (PVar "typeRows") (PVar "fileRows")))) (EApp (EApp (EVar "andThen") (EIf (EBinOp "/=" (EVar "version") (ELit (LString "1"))) (EApp (EVar "Err") (ELit (LString "identity: incompatible format"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid ABI")))) (EApp (EApp (EVar "atomInt") (ELit (LString "abi"))) (EVar "abiNode")))) (ELam ((PVar "abi")) (EApp (EApp (EVar "andThen") (EIf (EBinOp "/=" (EVar "abi") (EVar "abiVersion")) (EApp (EVar "Err") (ELit (LString "identity: incompatible ABI"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EIf (EBinOp "/=" (EVar "fingerprint") (EVar "expected")) (EApp (EVar "Err") (ELit (LString "identity: stale fingerprint"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid type high-water mark")))) (EApp (EApp (EVar "atomInt") (ELit (LString "typeHigh"))) (EVar "typeHighNode")))) (ELam ((PVar "typeHigh")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid file high-water mark")))) (EApp (EApp (EVar "atomInt") (ELit (LString "fileHigh"))) (EVar "fileHighNode")))) (ELam ((PVar "fileHigh")) (EApp (EApp (EVar "andThen") (EApp (EVar "readRows") (EVar "typeRows"))) (ELam ((PVar "ts")) (EApp (EApp (EVar "andThen") (EApp (EVar "readRows") (EVar "fileRows"))) (ELam ((PVar "fs")) (EApp (EApp (EVar "andThen") (EApp (EVar "uniqueRows") (EVar "ts"))) (ELam ((PVar "types")) (EApp (EApp (EVar "andThen") (EApp (EVar "uniqueRows") (EVar "fs"))) (ELam ((PVar "files")) (ELet false (PVar "p") (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abi")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "typeHigh" (EVar "typeHigh")) (fa "fileHigh" (EVar "fileHigh")))) (EMatch (EApp (EVar "packageDefects") (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EVar "p"))) (arm (PVar "defects") () (EApp (EVar "Err") (EApp (EApp (EVar "stringJoin") (ELit (LString "; "))) (EVar "defects")))))))))))))))))))))))))))
(DFunDef false "readPayload" (PWild PWild) (EApp (EVar "Err") (ELit (LString "identity: malformed payload"))))
(DTypeSig true "decodePackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PackageIdentity")))))
(DFunDef false "decodePackageIdentity" ((PVar "expected") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: malformed metadata")))) (EApp (EVar "parseSExp") (EVar "text")))) (ELam ((PVar "node")) (EMatch (EVar "node") (arm (PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-package-abi"))) (PCon "SAtom" (PVar "digest")) (PVar "body"))) () (EIf (EBinOp "/=" (EVar "digest") (EApp (EVar "hash") (EApp (EVar "renderSExp") (EVar "body")))) (EApp (EVar "Err") (ELit (LString "identity: integrity failure"))) (EApp (EApp (EVar "readPayload") (EVar "expected")) (EVar "body")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "identity: malformed envelope"))))))))
# MARK
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" true) (mem "packageDefects" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "parseSExp" false) (mem "renderSExp" false) (mem "atomInt" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DTypeSig false "hash#shadow" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hash#shadow" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "rows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "SExp")))
(DFunDef false "rows" ((PVar "pairs")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))) (EVar "pairs"))))
(DTypeSig false "payload" (TyFun (TyCon "PackageIdentity") (TyCon "SExp")))
(DFunDef false "payload" ((PVar "p")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "package-identity"))) (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "abi"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "p") "fingerprint")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "typeHigh"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "fileHigh"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "types"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "files"))))))
(DTypeSig true "encodePackageIdentity" (TyFun (TyCon "PackageIdentity") (TyCon "String")))
(DFunDef false "encodePackageIdentity" ((PVar "p")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "payload") (EVar "p"))) (DoExpr (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-package-abi"))) (EApp (EVar "SAtom") (EApp (EVar "hash#shadow") (EApp (EVar "renderSExp") (EVar "body")))) (EVar "body")))))))
(DTypeSig false "readRows" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readRows" ((PCon "SList" (PVar "xs"))) (EApp (EApp (EMethodRef "traverse") (EVar "readRow")) (EVar "xs")))
(DFunDef false "readRows" (PWild) (EApp (EVar "Err") (ELit (LString "identity: expected rows"))))
(DTypeSig false "readRow" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "readRow" ((PCon "SList" (PList (PCon "SAtom" (PVar "name")) (PVar "n")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EVar "name") (EVar "v")))) (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid number")))) (EApp (EApp (EVar "atomInt") (ELit (LString "number"))) (EVar "n")))))
(DFunDef false "readRow" (PWild) (EApp (EVar "Err") (ELit (LString "identity: invalid row"))))
(DTypeSig false "uniqueRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "uniqueRows" ((PVar "xs")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "uniqueRowsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "uniqueRowsInto" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "uniqueRowsInto" ((PCons (PTuple (PVar "name") (PVar "n")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "acc")) (EApp (EVar "Err") (ELit (LString "identity: duplicate name"))) (EApp (EApp (EVar "uniqueRowsInto") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "n")) (EVar "acc")))))
(DTypeSig false "readPayload" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PackageIdentity")))))
(DFunDef false "readPayload" ((PVar "expected") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "package-identity"))) (PCon "SAtom" (PVar "version")) (PVar "abiNode") (PCon "SAtom" (PVar "fingerprint")) (PVar "typeHighNode") (PVar "fileHighNode") (PVar "typeRows") (PVar "fileRows")))) (EApp (EApp (EMethodRef "andThen") (EIf (EBinOp "/=" (EVar "version") (ELit (LString "1"))) (EApp (EVar "Err") (ELit (LString "identity: incompatible format"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid ABI")))) (EApp (EApp (EVar "atomInt") (ELit (LString "abi"))) (EVar "abiNode")))) (ELam ((PVar "abi")) (EApp (EApp (EMethodRef "andThen") (EIf (EBinOp "/=" (EVar "abi") (EVar "abiVersion")) (EApp (EVar "Err") (ELit (LString "identity: incompatible ABI"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EIf (EBinOp "/=" (EVar "fingerprint") (EVar "expected")) (EApp (EVar "Err") (ELit (LString "identity: stale fingerprint"))) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid type high-water mark")))) (EApp (EApp (EVar "atomInt") (ELit (LString "typeHigh"))) (EVar "typeHighNode")))) (ELam ((PVar "typeHigh")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: invalid file high-water mark")))) (EApp (EApp (EVar "atomInt") (ELit (LString "fileHigh"))) (EVar "fileHighNode")))) (ELam ((PVar "fileHigh")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readRows") (EVar "typeRows"))) (ELam ((PVar "ts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readRows") (EVar "fileRows"))) (ELam ((PVar "fs")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "uniqueRows") (EVar "ts"))) (ELam ((PVar "types")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "uniqueRows") (EVar "fs"))) (ELam ((PVar "files")) (ELet false (PVar "p") (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abi")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "typeHigh" (EVar "typeHigh")) (fa "fileHigh" (EVar "fileHigh")))) (EMatch (EApp (EVar "packageDefects") (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EVar "p"))) (arm (PVar "defects") () (EApp (EVar "Err") (EApp (EApp (EVar "stringJoin") (ELit (LString "; "))) (EVar "defects")))))))))))))))))))))))))))
(DFunDef false "readPayload" (PWild PWild) (EApp (EVar "Err") (ELit (LString "identity: malformed payload"))))
(DTypeSig true "decodePackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PackageIdentity")))))
(DFunDef false "decodePackageIdentity" ((PVar "expected") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (ELit (LString "identity: malformed metadata")))) (EApp (EVar "parseSExp") (EVar "text")))) (ELam ((PVar "node")) (EMatch (EVar "node") (arm (PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-package-abi"))) (PCon "SAtom" (PVar "digest")) (PVar "body"))) () (EIf (EBinOp "/=" (EVar "digest") (EApp (EVar "hash#shadow") (EApp (EVar "renderSExp") (EVar "body")))) (EApp (EVar "Err") (ELit (LString "identity: integrity failure"))) (EApp (EApp (EVar "readPayload") (EVar "expected")) (EVar "body")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "identity: malformed envelope"))))))))
