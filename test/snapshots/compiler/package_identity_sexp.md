# META
source_lines=137
stages=DESUGAR,MARK
# SOURCE
import backend.package_identity.{
  PackageIdentity(..), IdentityDefect, packageDefects, renderIdentityDefect
}
import backend.runtime_layout.{abiVersion}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey}
import support.sexp_value.{SExp(..), parseSExp, renderSExp, atomInt}
import map.{entries}
import crypto.sha256_fast.{sha256Fast}
import bytes.{encodeUtf8}
import hex as Hex

public export data PackageIdentityError =
  | MalformedMetadata
  | MalformedEnvelope
  | IntegrityFailure
  | MalformedPayload
  | IncompatibleFormat
  | InvalidAbi
  | IncompatibleAbi
  | StaleFingerprint
  | InvalidTypeHigh
  | InvalidFileHigh
  | ExpectedRows
  | InvalidRow
  | InvalidNumber
  | DuplicateName
  | InvalidPackage (List IdentityDefect)
  deriving (Eq, Debug, Display)

export
renderPackageIdentityError : PackageIdentityError -> String
renderPackageIdentityError MalformedMetadata = "identity: malformed metadata"
renderPackageIdentityError MalformedEnvelope = "identity: malformed envelope"
renderPackageIdentityError IntegrityFailure = "identity: integrity failure"
renderPackageIdentityError MalformedPayload = "identity: malformed payload"
renderPackageIdentityError IncompatibleFormat = "identity: incompatible format"
renderPackageIdentityError InvalidAbi = "identity: invalid ABI"
renderPackageIdentityError IncompatibleAbi = "identity: incompatible ABI"
renderPackageIdentityError StaleFingerprint = "identity: stale fingerprint"
renderPackageIdentityError InvalidTypeHigh =
  "identity: invalid type high-water mark"
renderPackageIdentityError InvalidFileHigh =
  "identity: invalid file high-water mark"
renderPackageIdentityError ExpectedRows = "identity: expected rows"
renderPackageIdentityError InvalidRow = "identity: invalid row"
renderPackageIdentityError InvalidNumber = "identity: invalid number"
renderPackageIdentityError DuplicateName = "identity: duplicate name"
renderPackageIdentityError (InvalidPackage defects) =
  stringJoin "; " (map renderIdentityDefect defects)

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

readRows : SExp -> Result PackageIdentityError (List (String, Int))
readRows (SList xs) = traverse readRow xs
readRows _ = Err ExpectedRows

readRow : SExp -> Result PackageIdentityError (String, Int)
readRow (SList [SAtom name, n]) =
  map (v => (name, v)) (mapErr (_ => InvalidNumber) (atomInt "number" n))
readRow _ = Err InvalidRow

uniqueRows : List (String, Int) -> Result PackageIdentityError (OrdMap Int)
uniqueRows xs = uniqueRowsInto xs omEmpty

uniqueRowsInto : List (String, Int) ->
  OrdMap Int ->
  Result PackageIdentityError (OrdMap Int)
uniqueRowsInto [] acc = Ok acc
uniqueRowsInto ((name, n) :: rest) acc =
  if omHasKey name acc then
    Err DuplicateName
  else
    uniqueRowsInto rest (omInsert name n acc)

readPayload : String -> SExp -> Result PackageIdentityError PackageIdentity
readPayload expected (SList [SAtom "package-identity", SAtom version, abiNode, SAtom fingerprint, typeHighNode, fileHighNode, typeRows, fileRows]) =
  do
    if version /= "1" then Err IncompatibleFormat else Ok ()
    abi <- mapErr (_ => InvalidAbi) (atomInt "abi" abiNode)
    if abi /= abiVersion then Err IncompatibleAbi else Ok ()
    if fingerprint /= expected then Err StaleFingerprint else Ok ()
    typeHigh <- mapErr (_ => InvalidTypeHigh) (atomInt "typeHigh" typeHighNode)
    fileHigh <- mapErr (_ => InvalidFileHigh) (atomInt "fileHigh" fileHighNode)
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
      defects => Err (InvalidPackage defects)
readPayload _ _ = Err MalformedPayload

export
decodePackageIdentity : String ->
  String ->
  Result PackageIdentityError PackageIdentity
decodePackageIdentity expected text = do
  node <- mapErr (_ => MalformedMetadata) (parseSExp text)
  match node
    SList [SAtom "medaka-package-abi", SAtom digest, body] =>
      if digest /= hash (renderSExp body) then
        Err IntegrityFailure
      else
        readPayload expected body
    _ => Err MalformedEnvelope
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" true) (mem "IdentityDefect" false) (mem "packageDefects" false) (mem "renderIdentityDefect" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "parseSExp" false) (mem "renderSExp" false) (mem "atomInt" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DData Public "PackageIdentityError" () ((variant "MalformedMetadata" (ConPos)) (variant "MalformedEnvelope" (ConPos)) (variant "IntegrityFailure" (ConPos)) (variant "MalformedPayload" (ConPos)) (variant "IncompatibleFormat" (ConPos)) (variant "InvalidAbi" (ConPos)) (variant "IncompatibleAbi" (ConPos)) (variant "StaleFingerprint" (ConPos)) (variant "InvalidTypeHigh" (ConPos)) (variant "InvalidFileHigh" (ConPos)) (variant "ExpectedRows" (ConPos)) (variant "InvalidRow" (ConPos)) (variant "InvalidNumber" (ConPos)) (variant "DuplicateName" (ConPos)) (variant "InvalidPackage" (ConPos (TyApp (TyCon "List") (TyCon "IdentityDefect"))))) ())
(DImpl true "Eq" ((TyCon "PackageIdentityError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MalformedMetadata") (PCon "MalformedMetadata")) () (EVar "True")) (arm (PTuple (PCon "MalformedEnvelope") (PCon "MalformedEnvelope")) () (EVar "True")) (arm (PTuple (PCon "IntegrityFailure") (PCon "IntegrityFailure")) () (EVar "True")) (arm (PTuple (PCon "MalformedPayload") (PCon "MalformedPayload")) () (EVar "True")) (arm (PTuple (PCon "IncompatibleFormat") (PCon "IncompatibleFormat")) () (EVar "True")) (arm (PTuple (PCon "InvalidAbi") (PCon "InvalidAbi")) () (EVar "True")) (arm (PTuple (PCon "IncompatibleAbi") (PCon "IncompatibleAbi")) () (EVar "True")) (arm (PTuple (PCon "StaleFingerprint") (PCon "StaleFingerprint")) () (EVar "True")) (arm (PTuple (PCon "InvalidTypeHigh") (PCon "InvalidTypeHigh")) () (EVar "True")) (arm (PTuple (PCon "InvalidFileHigh") (PCon "InvalidFileHigh")) () (EVar "True")) (arm (PTuple (PCon "ExpectedRows") (PCon "ExpectedRows")) () (EVar "True")) (arm (PTuple (PCon "InvalidRow") (PCon "InvalidRow")) () (EVar "True")) (arm (PTuple (PCon "InvalidNumber") (PCon "InvalidNumber")) () (EVar "True")) (arm (PTuple (PCon "DuplicateName") (PCon "DuplicateName")) () (EVar "True")) (arm (PTuple (PCon "InvalidPackage" (PVar "__a0")) (PCon "InvalidPackage" (PVar "__b0"))) () (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PackageIdentityError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MalformedMetadata") () (ELit (LString "MalformedMetadata"))) (arm (PCon "MalformedEnvelope") () (ELit (LString "MalformedEnvelope"))) (arm (PCon "IntegrityFailure") () (ELit (LString "IntegrityFailure"))) (arm (PCon "MalformedPayload") () (ELit (LString "MalformedPayload"))) (arm (PCon "IncompatibleFormat") () (ELit (LString "IncompatibleFormat"))) (arm (PCon "InvalidAbi") () (ELit (LString "InvalidAbi"))) (arm (PCon "IncompatibleAbi") () (ELit (LString "IncompatibleAbi"))) (arm (PCon "StaleFingerprint") () (ELit (LString "StaleFingerprint"))) (arm (PCon "InvalidTypeHigh") () (ELit (LString "InvalidTypeHigh"))) (arm (PCon "InvalidFileHigh") () (ELit (LString "InvalidFileHigh"))) (arm (PCon "ExpectedRows") () (ELit (LString "ExpectedRows"))) (arm (PCon "InvalidRow") () (ELit (LString "InvalidRow"))) (arm (PCon "InvalidNumber") () (ELit (LString "InvalidNumber"))) (arm (PCon "DuplicateName") () (ELit (LString "DuplicateName"))) (arm (PCon "InvalidPackage" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidPackage ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "PackageIdentityError")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MalformedMetadata") () (ELit (LString "MalformedMetadata"))) (arm (PCon "MalformedEnvelope") () (ELit (LString "MalformedEnvelope"))) (arm (PCon "IntegrityFailure") () (ELit (LString "IntegrityFailure"))) (arm (PCon "MalformedPayload") () (ELit (LString "MalformedPayload"))) (arm (PCon "IncompatibleFormat") () (ELit (LString "IncompatibleFormat"))) (arm (PCon "InvalidAbi") () (ELit (LString "InvalidAbi"))) (arm (PCon "IncompatibleAbi") () (ELit (LString "IncompatibleAbi"))) (arm (PCon "StaleFingerprint") () (ELit (LString "StaleFingerprint"))) (arm (PCon "InvalidTypeHigh") () (ELit (LString "InvalidTypeHigh"))) (arm (PCon "InvalidFileHigh") () (ELit (LString "InvalidFileHigh"))) (arm (PCon "ExpectedRows") () (ELit (LString "ExpectedRows"))) (arm (PCon "InvalidRow") () (ELit (LString "InvalidRow"))) (arm (PCon "InvalidNumber") () (ELit (LString "InvalidNumber"))) (arm (PCon "DuplicateName") () (ELit (LString "DuplicateName"))) (arm (PCon "InvalidPackage" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidPackage ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a0")))))))))
(DTypeSig true "renderPackageIdentityError" (TyFun (TyCon "PackageIdentityError") (TyCon "String")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedMetadata")) (ELit (LString "identity: malformed metadata")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedEnvelope")) (ELit (LString "identity: malformed envelope")))
(DFunDef false "renderPackageIdentityError" ((PCon "IntegrityFailure")) (ELit (LString "identity: integrity failure")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedPayload")) (ELit (LString "identity: malformed payload")))
(DFunDef false "renderPackageIdentityError" ((PCon "IncompatibleFormat")) (ELit (LString "identity: incompatible format")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidAbi")) (ELit (LString "identity: invalid ABI")))
(DFunDef false "renderPackageIdentityError" ((PCon "IncompatibleAbi")) (ELit (LString "identity: incompatible ABI")))
(DFunDef false "renderPackageIdentityError" ((PCon "StaleFingerprint")) (ELit (LString "identity: stale fingerprint")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidTypeHigh")) (ELit (LString "identity: invalid type high-water mark")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidFileHigh")) (ELit (LString "identity: invalid file high-water mark")))
(DFunDef false "renderPackageIdentityError" ((PCon "ExpectedRows")) (ELit (LString "identity: expected rows")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidRow")) (ELit (LString "identity: invalid row")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidNumber")) (ELit (LString "identity: invalid number")))
(DFunDef false "renderPackageIdentityError" ((PCon "DuplicateName")) (ELit (LString "identity: duplicate name")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidPackage" (PVar "defects"))) (EApp (EApp (EVar "stringJoin") (ELit (LString "; "))) (EApp (EApp (EVar "map") (EVar "renderIdentityDefect")) (EVar "defects"))))
(DTypeSig false "hash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hash" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "rows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "SExp")))
(DFunDef false "rows" ((PVar "pairs")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))) (EVar "pairs"))))
(DTypeSig false "payload" (TyFun (TyCon "PackageIdentity") (TyCon "SExp")))
(DFunDef false "payload" ((PVar "p")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "package-identity"))) (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "abi"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "p") "fingerprint")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "typeHigh"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "fileHigh"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "types"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "files"))))))
(DTypeSig true "encodePackageIdentity" (TyFun (TyCon "PackageIdentity") (TyCon "String")))
(DFunDef false "encodePackageIdentity" ((PVar "p")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "payload") (EVar "p"))) (DoExpr (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-package-abi"))) (EApp (EVar "SAtom") (EApp (EVar "hash") (EApp (EVar "renderSExp") (EVar "body")))) (EVar "body")))))))
(DTypeSig false "readRows" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readRows" ((PCon "SList" (PVar "xs"))) (EApp (EApp (EVar "traverse") (EVar "readRow")) (EVar "xs")))
(DFunDef false "readRows" (PWild) (EApp (EVar "Err") (EVar "ExpectedRows")))
(DTypeSig false "readRow" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "readRow" ((PCon "SList" (PList (PCon "SAtom" (PVar "name")) (PVar "n")))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EVar "name") (EVar "v")))) (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidNumber"))) (EApp (EApp (EVar "atomInt") (ELit (LString "number"))) (EVar "n")))))
(DFunDef false "readRow" (PWild) (EApp (EVar "Err") (EVar "InvalidRow")))
(DTypeSig false "uniqueRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "uniqueRows" ((PVar "xs")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "uniqueRowsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "uniqueRowsInto" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "uniqueRowsInto" ((PCons (PTuple (PVar "name") (PVar "n")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "acc")) (EApp (EVar "Err") (EVar "DuplicateName")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "n")) (EVar "acc")))))
(DTypeSig false "readPayload" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyCon "PackageIdentity")))))
(DFunDef false "readPayload" ((PVar "expected") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "package-identity"))) (PCon "SAtom" (PVar "version")) (PVar "abiNode") (PCon "SAtom" (PVar "fingerprint")) (PVar "typeHighNode") (PVar "fileHighNode") (PVar "typeRows") (PVar "fileRows")))) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "version") (ELit (LString "1"))) (EApp (EVar "Err") (EVar "IncompatibleFormat")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidAbi"))) (EApp (EApp (EVar "atomInt") (ELit (LString "abi"))) (EVar "abiNode")))) (ELam ((PVar "abi")) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "abi") (EVar "abiVersion")) (EApp (EVar "Err") (EVar "IncompatibleAbi")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "fingerprint") (EVar "expected")) (EApp (EVar "Err") (EVar "StaleFingerprint")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidTypeHigh"))) (EApp (EApp (EVar "atomInt") (ELit (LString "typeHigh"))) (EVar "typeHighNode")))) (ELam ((PVar "typeHigh")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidFileHigh"))) (EApp (EApp (EVar "atomInt") (ELit (LString "fileHigh"))) (EVar "fileHighNode")))) (ELam ((PVar "fileHigh")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "readRows") (EVar "typeRows"))) (ELam ((PVar "ts")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "readRows") (EVar "fileRows"))) (ELam ((PVar "fs")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "uniqueRows") (EVar "ts"))) (ELam ((PVar "types")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "uniqueRows") (EVar "fs"))) (ELam ((PVar "files")) (ELet false (PVar "p") (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abi")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "typeHigh" (EVar "typeHigh")) (fa "fileHigh" (EVar "fileHigh")))) (EMatch (EApp (EVar "packageDefects") (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EVar "p"))) (arm (PVar "defects") () (EApp (EVar "Err") (EApp (EVar "InvalidPackage") (EVar "defects")))))))))))))))))))))))))))
(DFunDef false "readPayload" (PWild PWild) (EApp (EVar "Err") (EVar "MalformedPayload")))
(DTypeSig true "decodePackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyCon "PackageIdentity")))))
(DFunDef false "decodePackageIdentity" ((PVar "expected") (PVar "text")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "MalformedMetadata"))) (EApp (EVar "parseSExp") (EVar "text")))) (ELam ((PVar "node")) (EMatch (EVar "node") (arm (PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-package-abi"))) (PCon "SAtom" (PVar "digest")) (PVar "body"))) () (EIf (EBinOp "/=" (EVar "digest") (EApp (EVar "hash") (EApp (EVar "renderSExp") (EVar "body")))) (EApp (EVar "Err") (EVar "IntegrityFailure")) (EApp (EApp (EVar "readPayload") (EVar "expected")) (EVar "body")))) (arm PWild () (EApp (EVar "Err") (EVar "MalformedEnvelope")))))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" true) (mem "IdentityDefect" false) (mem "packageDefects" false) (mem "renderIdentityDefect" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "parseSExp" false) (mem "renderSExp" false) (mem "atomInt" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DData Public "PackageIdentityError" () ((variant "MalformedMetadata" (ConPos)) (variant "MalformedEnvelope" (ConPos)) (variant "IntegrityFailure" (ConPos)) (variant "MalformedPayload" (ConPos)) (variant "IncompatibleFormat" (ConPos)) (variant "InvalidAbi" (ConPos)) (variant "IncompatibleAbi" (ConPos)) (variant "StaleFingerprint" (ConPos)) (variant "InvalidTypeHigh" (ConPos)) (variant "InvalidFileHigh" (ConPos)) (variant "ExpectedRows" (ConPos)) (variant "InvalidRow" (ConPos)) (variant "InvalidNumber" (ConPos)) (variant "DuplicateName" (ConPos)) (variant "InvalidPackage" (ConPos (TyApp (TyCon "List") (TyCon "IdentityDefect"))))) ())
(DImpl true "Eq" ((TyCon "PackageIdentityError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MalformedMetadata") (PCon "MalformedMetadata")) () (EVar "True")) (arm (PTuple (PCon "MalformedEnvelope") (PCon "MalformedEnvelope")) () (EVar "True")) (arm (PTuple (PCon "IntegrityFailure") (PCon "IntegrityFailure")) () (EVar "True")) (arm (PTuple (PCon "MalformedPayload") (PCon "MalformedPayload")) () (EVar "True")) (arm (PTuple (PCon "IncompatibleFormat") (PCon "IncompatibleFormat")) () (EVar "True")) (arm (PTuple (PCon "InvalidAbi") (PCon "InvalidAbi")) () (EVar "True")) (arm (PTuple (PCon "IncompatibleAbi") (PCon "IncompatibleAbi")) () (EVar "True")) (arm (PTuple (PCon "StaleFingerprint") (PCon "StaleFingerprint")) () (EVar "True")) (arm (PTuple (PCon "InvalidTypeHigh") (PCon "InvalidTypeHigh")) () (EVar "True")) (arm (PTuple (PCon "InvalidFileHigh") (PCon "InvalidFileHigh")) () (EVar "True")) (arm (PTuple (PCon "ExpectedRows") (PCon "ExpectedRows")) () (EVar "True")) (arm (PTuple (PCon "InvalidRow") (PCon "InvalidRow")) () (EVar "True")) (arm (PTuple (PCon "InvalidNumber") (PCon "InvalidNumber")) () (EVar "True")) (arm (PTuple (PCon "DuplicateName") (PCon "DuplicateName")) () (EVar "True")) (arm (PTuple (PCon "InvalidPackage" (PVar "__a0")) (PCon "InvalidPackage" (PVar "__b0"))) () (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PackageIdentityError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MalformedMetadata") () (ELit (LString "MalformedMetadata"))) (arm (PCon "MalformedEnvelope") () (ELit (LString "MalformedEnvelope"))) (arm (PCon "IntegrityFailure") () (ELit (LString "IntegrityFailure"))) (arm (PCon "MalformedPayload") () (ELit (LString "MalformedPayload"))) (arm (PCon "IncompatibleFormat") () (ELit (LString "IncompatibleFormat"))) (arm (PCon "InvalidAbi") () (ELit (LString "InvalidAbi"))) (arm (PCon "IncompatibleAbi") () (ELit (LString "IncompatibleAbi"))) (arm (PCon "StaleFingerprint") () (ELit (LString "StaleFingerprint"))) (arm (PCon "InvalidTypeHigh") () (ELit (LString "InvalidTypeHigh"))) (arm (PCon "InvalidFileHigh") () (ELit (LString "InvalidFileHigh"))) (arm (PCon "ExpectedRows") () (ELit (LString "ExpectedRows"))) (arm (PCon "InvalidRow") () (ELit (LString "InvalidRow"))) (arm (PCon "InvalidNumber") () (ELit (LString "InvalidNumber"))) (arm (PCon "DuplicateName") () (ELit (LString "DuplicateName"))) (arm (PCon "InvalidPackage" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidPackage ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "PackageIdentityError")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MalformedMetadata") () (ELit (LString "MalformedMetadata"))) (arm (PCon "MalformedEnvelope") () (ELit (LString "MalformedEnvelope"))) (arm (PCon "IntegrityFailure") () (ELit (LString "IntegrityFailure"))) (arm (PCon "MalformedPayload") () (ELit (LString "MalformedPayload"))) (arm (PCon "IncompatibleFormat") () (ELit (LString "IncompatibleFormat"))) (arm (PCon "InvalidAbi") () (ELit (LString "InvalidAbi"))) (arm (PCon "IncompatibleAbi") () (ELit (LString "IncompatibleAbi"))) (arm (PCon "StaleFingerprint") () (ELit (LString "StaleFingerprint"))) (arm (PCon "InvalidTypeHigh") () (ELit (LString "InvalidTypeHigh"))) (arm (PCon "InvalidFileHigh") () (ELit (LString "InvalidFileHigh"))) (arm (PCon "ExpectedRows") () (ELit (LString "ExpectedRows"))) (arm (PCon "InvalidRow") () (ELit (LString "InvalidRow"))) (arm (PCon "InvalidNumber") () (ELit (LString "InvalidNumber"))) (arm (PCon "DuplicateName") () (ELit (LString "DuplicateName"))) (arm (PCon "InvalidPackage" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidPackage ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a0")))))))))
(DTypeSig true "renderPackageIdentityError" (TyFun (TyCon "PackageIdentityError") (TyCon "String")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedMetadata")) (ELit (LString "identity: malformed metadata")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedEnvelope")) (ELit (LString "identity: malformed envelope")))
(DFunDef false "renderPackageIdentityError" ((PCon "IntegrityFailure")) (ELit (LString "identity: integrity failure")))
(DFunDef false "renderPackageIdentityError" ((PCon "MalformedPayload")) (ELit (LString "identity: malformed payload")))
(DFunDef false "renderPackageIdentityError" ((PCon "IncompatibleFormat")) (ELit (LString "identity: incompatible format")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidAbi")) (ELit (LString "identity: invalid ABI")))
(DFunDef false "renderPackageIdentityError" ((PCon "IncompatibleAbi")) (ELit (LString "identity: incompatible ABI")))
(DFunDef false "renderPackageIdentityError" ((PCon "StaleFingerprint")) (ELit (LString "identity: stale fingerprint")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidTypeHigh")) (ELit (LString "identity: invalid type high-water mark")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidFileHigh")) (ELit (LString "identity: invalid file high-water mark")))
(DFunDef false "renderPackageIdentityError" ((PCon "ExpectedRows")) (ELit (LString "identity: expected rows")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidRow")) (ELit (LString "identity: invalid row")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidNumber")) (ELit (LString "identity: invalid number")))
(DFunDef false "renderPackageIdentityError" ((PCon "DuplicateName")) (ELit (LString "identity: duplicate name")))
(DFunDef false "renderPackageIdentityError" ((PCon "InvalidPackage" (PVar "defects"))) (EApp (EApp (EVar "stringJoin") (ELit (LString "; "))) (EApp (EApp (EMethodRef "map") (EVar "renderIdentityDefect")) (EVar "defects"))))
(DTypeSig false "hash#shadow" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hash#shadow" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "rows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "SExp")))
(DFunDef false "rows" ((PVar "pairs")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))) (EVar "pairs"))))
(DTypeSig false "payload" (TyFun (TyCon "PackageIdentity") (TyCon "SExp")))
(DFunDef false "payload" ((PVar "p")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "package-identity"))) (EApp (EVar "SAtom") (ELit (LString "1"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "abi"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "p") "fingerprint")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "typeHigh"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "p") "fileHigh"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "types"))) (EApp (EVar "rows") (EApp (EVar "entries") (EFieldAccess (EVar "p") "files"))))))
(DTypeSig true "encodePackageIdentity" (TyFun (TyCon "PackageIdentity") (TyCon "String")))
(DFunDef false "encodePackageIdentity" ((PVar "p")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "payload") (EVar "p"))) (DoExpr (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-package-abi"))) (EApp (EVar "SAtom") (EApp (EVar "hash#shadow") (EApp (EVar "renderSExp") (EVar "body")))) (EVar "body")))))))
(DTypeSig false "readRows" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readRows" ((PCon "SList" (PVar "xs"))) (EApp (EApp (EMethodRef "traverse") (EVar "readRow")) (EVar "xs")))
(DFunDef false "readRows" (PWild) (EApp (EVar "Err") (EVar "ExpectedRows")))
(DTypeSig false "readRow" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "readRow" ((PCon "SList" (PList (PCon "SAtom" (PVar "name")) (PVar "n")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EVar "name") (EVar "v")))) (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidNumber"))) (EApp (EApp (EVar "atomInt") (ELit (LString "number"))) (EVar "n")))))
(DFunDef false "readRow" (PWild) (EApp (EVar "Err") (EVar "InvalidRow")))
(DTypeSig false "uniqueRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "uniqueRows" ((PVar "xs")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "uniqueRowsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "uniqueRowsInto" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "uniqueRowsInto" ((PCons (PTuple (PVar "name") (PVar "n")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "acc")) (EApp (EVar "Err") (EVar "DuplicateName")) (EApp (EApp (EVar "uniqueRowsInto") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "n")) (EVar "acc")))))
(DTypeSig false "readPayload" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyCon "PackageIdentity")))))
(DFunDef false "readPayload" ((PVar "expected") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "package-identity"))) (PCon "SAtom" (PVar "version")) (PVar "abiNode") (PCon "SAtom" (PVar "fingerprint")) (PVar "typeHighNode") (PVar "fileHighNode") (PVar "typeRows") (PVar "fileRows")))) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "version") (ELit (LString "1"))) (EApp (EVar "Err") (EVar "IncompatibleFormat")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidAbi"))) (EApp (EApp (EVar "atomInt") (ELit (LString "abi"))) (EVar "abiNode")))) (ELam ((PVar "abi")) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "abi") (EVar "abiVersion")) (EApp (EVar "Err") (EVar "IncompatibleAbi")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EIf (EBinOp "/=" (EVar "fingerprint") (EVar "expected")) (EApp (EVar "Err") (EVar "StaleFingerprint")) (EApp (EVar "Ok") (ELit LUnit)))) (ELam (PWild) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidTypeHigh"))) (EApp (EApp (EVar "atomInt") (ELit (LString "typeHigh"))) (EVar "typeHighNode")))) (ELam ((PVar "typeHigh")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "InvalidFileHigh"))) (EApp (EApp (EVar "atomInt") (ELit (LString "fileHigh"))) (EVar "fileHighNode")))) (ELam ((PVar "fileHigh")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "readRows") (EVar "typeRows"))) (ELam ((PVar "ts")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "readRows") (EVar "fileRows"))) (ELam ((PVar "fs")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "uniqueRows") (EVar "ts"))) (ELam ((PVar "types")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "uniqueRows") (EVar "fs"))) (ELam ((PVar "files")) (ELet false (PVar "p") (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abi")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "typeHigh" (EVar "typeHigh")) (fa "fileHigh" (EVar "fileHigh")))) (EMatch (EApp (EVar "packageDefects") (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EVar "p"))) (arm (PVar "defects") () (EApp (EVar "Err") (EApp (EVar "InvalidPackage") (EVar "defects")))))))))))))))))))))))))))
(DFunDef false "readPayload" (PWild PWild) (EApp (EVar "Err") (EVar "MalformedPayload")))
(DTypeSig true "decodePackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "PackageIdentityError")) (TyCon "PackageIdentity")))))
(DFunDef false "decodePackageIdentity" ((PVar "expected") (PVar "text")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "mapErr") (ELam (PWild) (EVar "MalformedMetadata"))) (EApp (EVar "parseSExp") (EVar "text")))) (ELam ((PVar "node")) (EMatch (EVar "node") (arm (PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-package-abi"))) (PCon "SAtom" (PVar "digest")) (PVar "body"))) () (EIf (EBinOp "/=" (EVar "digest") (EApp (EVar "hash#shadow") (EApp (EVar "renderSExp") (EVar "body")))) (EApp (EVar "Err") (EVar "IntegrityFailure")) (EApp (EApp (EVar "readPayload") (EVar "expected")) (EVar "body")))) (arm PWild () (EApp (EVar "Err") (EVar "MalformedEnvelope")))))))
