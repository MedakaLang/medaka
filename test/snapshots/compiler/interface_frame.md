# META
source_lines=234
stages=DESUGAR,MARK
# SOURCE
-- The framing every on-disk interface file shares: one header line, then the
-- bytes its digest covers.
--
--   (<tag> <version> <field> ... (digest <hex>))
--
-- A kind of file names its tag, its format version and the fields between the
-- version and the digest.  The digest is the SHA-256 of the bytes after the
-- header line.  The header's own fields are not under it, so a reader decides
-- freshness from the key first (`checkedFramed`'s gate) and only then hashes the
-- covered bytes and decodes them: a file written for other sources never has
-- its body looked at.
import crypto.sha256_fast.{sha256Fast}
import hex as Hex
import list.{take, drop}
import bytes.{encodeUtf8}
import string as S
import support.sexp_value.{
  SExp(..), SexpError(..), atomInt, expectAtom, parseSExp, renderSExp
}
import types.prelude_interface.{InterfaceKey(..)}

-- Why a file was refused: its header declares a format version other than the
-- one this compiler reads, it is malformed in some other way, or a reader's
-- gate found its key stale (the component the key differs in).
-- lint-disable-next-line rule-clone-type
public export data InterfaceFault =
  | WrongFormat Int
  | Malformed SexpError
  | StaleKey String

-- Decides from a header's key alone whether the file is stale, naming the
-- component that differs.
export type KeyGate = InterfaceKey -> Option String

export
noGate : KeyGate
noGate _ = None

-- The SHA-256 of a text, in lower-case hex.
export
sha256Hex : String -> String
sha256Hex text = Hex.encode (sha256Fast (encodeUtf8 text))

-- What the digest covers: the file's text after its first line.
export
bodyOf : String -> String
bodyOf text = match S.indexOf "\n" text
  Some i => S.drop (i + 1) text
  None => ""

export
refuse : String -> String -> Result InterfaceFault a
refuse path what =
  Err (Malformed SexpError { seOffset = 0, sePath = path, seWhat = what })

export
failure : SexpError -> Result InterfaceFault a
failure e = Err (Malformed e)

-- Why a file of the kind [noun], written at [version], is refused.
export
renderFramedFault : String -> Int -> InterfaceFault -> String
renderFramedFault noun version (WrongFormat v) =
  "\{noun} format version \{v}, this compiler reads \{version}"
renderFramedFault noun _ (Malformed e) = "\{e.sePath}: \{e.seWhat} (\{noun})"
renderFramedFault noun _ (StaleKey component) = "stale: \{component} (\{noun})"

-- The first line of [text] read as one s-expression, and the text after it;
-- [what] is why there is no such line.
export
firstLine : String -> String -> String -> Result InterfaceFault (SExp, String)
firstLine path what text = match S.indexOf "\n" text
  None => refuse path what
  Some i => match parseSExp (S.take i text)
    Err e => failure e
    Ok node => Ok (node, S.drop (i + 1) text)

-- ── the key's fields ────────────────────────────────────────────────────────

pairNode : (String, String) -> SExp
pairNode s = SList [SAtom (fst s), SAtom (snd s)]

-- The fields a prelude key writes: its sources and its compiler.
export
keyFields : InterfaceKey -> List SExp
keyFields key = [
  SList [SAtom "sources", SList (map pairNode key.ikSources)],
  SList [SAtom "compiler", SAtom key.ikCompiler],
]

sourceOf : SExp -> Result SexpError (String, String)
sourceOf (SList [SAtom p, SAtom h]) = Ok (p, h)
sourceOf _ = Err SexpError {
  seOffset = 0,
  sePath = "header/sources",
  seWhat = "expected a (path hash) pair",
}

-- The key of the first two fields of a header at [version], and the fields
-- after them.
export
readKeyFields : Int -> List SExp -> Result SexpError (InterfaceKey, List SExp)
readKeyFields version ((SList [SAtom "sources", SList srcs]) :: (SList [SAtom "compiler", c]) :: rest) =
  do
    sources <- traverse sourceOf srcs
    compiler <- expectAtom "header/compiler" c
    Ok (
      InterfaceKey {
        ikFormat = version,
        ikSources = sources,
        ikCompiler = compiler,
      },
      rest,
    )
readKeyFields _ _ = Err SexpError {
  seOffset = 0,
  sePath = "header",
  seWhat = "expected the sources and the compiler fields",
}

-- ── the header ──────────────────────────────────────────────────────────────

-- The header line of a file: [tag], [version], [fields] and the digest of the
-- bytes after the line.
export
framedHeader : String -> Int -> List SExp -> String -> SExp
framedHeader tag version fields digest =
  SList
    ([SAtom tag, SAtom (intToString version)]
      ++ fields
      ++ [SList [SAtom "digest", SAtom digest]])

-- The whole file: the header over [covered], then [covered].
export
framedFile : String -> Int -> List SExp -> String -> String
framedFile tag version fields covered =
  "\{renderSExp (framedHeader tag version fields (sha256Hex covered))}\n\{covered}"

-- The version the header declares, when it declares one.
export
declaredVersion : String -> SExp -> Option Int
declaredVersion tag (SList ((SAtom t) :: v :: _))
  | t == tag = match atomInt "" v
    Ok n => Some n
    Err _ => None
declaredVersion _ _ = None

fieldCountWord : Int -> String
fieldCountWord 5 = "five"
fieldCountWord 6 = "six"
fieldCountWord 7 = "seven"
fieldCountWord n = intToString n

-- The [count] fields between the version and the digest of a header, and the
-- digest it claims.  A version other than [version] is refused first.
export
headerOf : String -> Int -> Int -> SExp -> Result SexpError (List SExp, String)
headerOf tag version count (SList ((SAtom t) :: v :: rest))
  | t == tag = do
    declared <- atomInt "header/\{tag}.1" v
    if declared /= version then
      Err SexpError {
        seOffset = 0,
        sePath = "header/\{tag}.1",
        seWhat =
          "\{declared}: format version \{declared}, this compiler reads \{version}",
      }
    else if length rest /= count + 1 then
      shapeError tag (count + 3)
    else match drop count rest
      [SList [SAtom "digest", d]] => do
        digest <- expectAtom "header/digest" d
        Ok (take count rest, digest)
      _ => shapeError tag (count + 3)
headerOf tag _ count _ = shapeError tag (count + 3)

shapeError : String -> Int -> Result SexpError a
shapeError tag n = Err SexpError {
  seOffset = 0,
  sePath = "header",
  seWhat = "expected a \{tag} header of \{fieldCountWord n} fields",
}

-- The digest [claimed] against the bytes [covered].
export
verifyDigest : String -> String -> Result InterfaceFault Unit
verifyDigest claimed covered =
  if sha256Hex covered /= claimed then
    refuse "header/digest" "the body does not match the digest"
  else
    Ok ()

-- ── reading a file ──────────────────────────────────────────────────────────

-- The header's [count] fields and its digest, and the bytes the digest covers,
-- from a file's text: the version and the header's shape are checked, nothing
-- else.
export
openFramed : String ->
  Int ->
  Int ->
  String ->
  Result InterfaceFault (List SExp, String, String)
openFramed tag version count text = do
  (node, covered) <- firstLine "file" "no header line" text
  match declaredVersion tag node
    Some v if v /= version => Err (WrongFormat v)
    _ => do
      (fields, digest) <- mapErr Malformed (headerOf tag version count node)
      Ok (fields, digest, covered)

-- The key a file framed under [tag] at [version] claims and the bytes its
-- digest covers.  The version is checked first, then the header, then [gate]
-- on the key, then the digest: a file the gate calls stale has neither its
-- digest checked nor its body read.
export
checkedFramed : String ->
  Int ->
  KeyGate ->
  String ->
  Result InterfaceFault (InterfaceKey, String)
checkedFramed tag version gate text = do
  (fields, digest, covered) <- openFramed tag version 2 text
  (key, _) <- mapErr Malformed (readKeyFields version fields)
  _ <- gated gate key
  _ <- verifyDigest digest covered
  Ok (key, covered)

-- [key] when [gate] finds it fresh, else the stale component.
export
gated : KeyGate -> InterfaceKey -> Result InterfaceFault Unit
gated gate key = match gate key
  Some component => Err (StaleKey component)
  None => Ok ()
# DESUGAR
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "InterfaceFault" () ((variant "WrongFormat" (ConPos (TyCon "Int"))) (variant "Malformed" (ConPos (TyCon "SexpError"))) (variant "StaleKey" (ConPos (TyCon "String")))) ())
(DTypeAlias true "KeyGate" () (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "Option") (TyCon "String"))))
(DTypeSig true "noGate" (TyCon "KeyGate"))
(DFunDef false "noGate" (PWild) (EVar "None"))
(DTypeSig true "sha256Hex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Hex" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig true "bodyOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bodyOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "refuse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a")))))
(DFunDef false "refuse" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what")))))))
(DTypeSig true "failure" (TyFun (TyCon "SexpError") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a"))))
(DFunDef false "failure" ((PVar "e")) (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e"))))
(DTypeSig true "renderFramedFault" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceFault") (TyCon "String")))))
(DFunDef false "renderFramedFault" ((PVar "noun") (PVar "version") (PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "noun"))) (ELit (LString " format version "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "version"))) (ELit (LString ""))))
(DFunDef false "renderFramedFault" ((PVar "noun") PWild (PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "noun"))) (ELit (LString ")"))))
(DFunDef false "renderFramedFault" ((PVar "noun") PWild (PCon "StaleKey" (PVar "component"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EVar "display") (EVar "component"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "noun"))) (ELit (LString ")"))))
(DTypeSig true "firstLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "SExp") (TyCon "String")))))))
(DFunDef false "firstLine" ((PVar "path") (PVar "what") (PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "what"))) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "text"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EApp (EVar "Ok") (ETuple (EVar "node") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text")))))))))
(DTypeSig false "pairNode" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "pairNode" ((PVar "s")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "SAtom") (EApp (EVar "snd") (EVar "s"))))))
(DTypeSig true "keyFields" (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "keyFields" ((PVar "key")) (EListLit (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "sources"))) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "pairNode")) (EFieldAccess (EVar "key") "ikSources"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "compiler"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler"))))))
(DTypeSig false "sourceOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "sourceOf" ((PCon "SList" (PList (PCon "SAtom" (PVar "p")) (PCon "SAtom" (PVar "h"))))) (EApp (EVar "Ok") (ETuple (EVar "p") (EVar "h"))))
(DFunDef false "sourceOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sources"))) (fa "seWhat" (ELit (LString "expected a (path hash) pair")))))))
(DTypeSig true "readKeyFields" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "InterfaceKey") (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "readKeyFields" ((PVar "version") (PCons (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PCon "SList" (PVar "srcs")))) (PCons (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PVar "rest")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EVar "sourceOf")) (EVar "srcs"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/compiler"))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EVar "Ok") (ETuple (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))) (EVar "rest"))))))))
(DFunDef false "readKeyFields" (PWild PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected the sources and the compiler fields")))))))
(DTypeSig true "framedHeader" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyFun (TyCon "String") (TyCon "SExp"))))))
(DFunDef false "framedHeader" ((PVar "tag") (PVar "version") (PVar "fields") (PVar "digest")) (EApp (EVar "SList") (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "SAtom") (EVar "tag")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "version")))) (EVar "fields")) (EListLit (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "digest"))) (EApp (EVar "SAtom") (EVar "digest"))))))))
(DTypeSig true "framedFile" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "framedFile" ((PVar "tag") (PVar "version") (PVar "fields") (PVar "covered")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EApp (EVar "framedHeader") (EVar "tag")) (EVar "version")) (EVar "fields")) (EApp (EVar "sha256Hex") (EVar "covered")))))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "covered"))) (ELit (LString ""))))
(DTypeSig true "declaredVersion" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredVersion" ((PVar "tag") (PCon "SList" (PCons (PCon "SAtom" (PVar "t")) (PCons (PVar "v") PWild)))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declaredVersion" (PWild PWild) (EVar "None"))
(DTypeSig false "fieldCountWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fieldCountWord" ((PLit (LInt 5))) (ELit (LString "five")))
(DFunDef false "fieldCountWord" ((PLit (LInt 6))) (ELit (LString "six")))
(DFunDef false "fieldCountWord" ((PLit (LInt 7))) (ELit (LString "seven")))
(DFunDef false "fieldCountWord" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))
(DTypeSig true "headerOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String"))))))))
(DFunDef false "headerOf" ((PVar "tag") (PVar "version") (PVar "count") (PCon "SList" (PCons (PCon "SAtom" (PVar "t")) (PCons (PVar "v") (PVar "rest"))))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EBinOp "++" (EBinOp "++" (ELit (LString "header/")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ".1")))) (EVar "v"))) (ELam ((PVar "declared")) (EIf (EBinOp "/=" (EVar "declared") (EVar "version")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EBinOp "++" (EBinOp "++" (ELit (LString "header/")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ".1")))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "declared"))) (ELit (LString ": format version "))) (EApp (EVar "display") (EVar "declared"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "version"))) (ELit (LString ""))))))) (EIf (EBinOp "/=" (EApp (EVar "length") (EVar "rest")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EVar "count") (ELit (LInt 3)))) (EMatch (EApp (EApp (EVar "drop") (EVar "count")) (EVar "rest")) (arm (PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/digest"))) (EVar "d"))) (ELam ((PVar "digest")) (EApp (EVar "Ok") (ETuple (EApp (EApp (EVar "take") (EVar "count")) (EVar "rest")) (EVar "digest")))))) (arm PWild () (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EVar "count") (ELit (LInt 3)))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "headerOf" ((PVar "tag") PWild (PVar "count") PWild) (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EVar "count") (ELit (LInt 3)))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "tag") (PVar "n")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected a ")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString " header of "))) (EApp (EVar "display") (EApp (EVar "fieldCountWord") (EVar "n")))) (ELit (LString " fields"))))))))
(DTypeSig true "verifyDigest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit")))))
(DFunDef false "verifyDigest" ((PVar "claimed") (PVar "covered")) (EIf (EBinOp "/=" (EApp (EVar "sha256Hex") (EVar "covered")) (EVar "claimed")) (EApp (EApp (EVar "refuse") (ELit (LString "header/digest"))) (ELit (LString "the body does not match the digest"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "openFramed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String") (TyCon "String"))))))))
(DFunDef false "openFramed" ((PVar "tag") (PVar "version") (PVar "count") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "file"))) (ELit (LString "no header line"))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "covered")) () (EMatch (EApp (EApp (EVar "declaredVersion") (EVar "tag")) (EVar "node")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "version")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EApp (EApp (EVar "headerOf") (EVar "tag")) (EVar "version")) (EVar "count")) (EVar "node")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest")) () (EApp (EVar "Ok") (ETuple (EVar "fields") (EVar "digest") (EVar "covered"))))))))))))))
(DTypeSig true "checkedFramed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))))
(DFunDef false "checkedFramed" ((PVar "tag") (PVar "version") (PVar "gate") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "tag")) (EVar "version")) (ELit (LInt 2))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest") (PVar "covered")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EVar "readKeyFields") (EVar "version")) (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") PWild) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "gated") (EVar "gate")) (EVar "key"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "verifyDigest") (EVar "digest")) (EVar "covered"))) (ELam (PWild) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "covered"))))))))))))))))
(DTypeSig true "gated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "InterfaceKey") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit")))))
(DFunDef false "gated" ((PVar "gate") (PVar "key")) (EMatch (EApp (EVar "gate") (EVar "key")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Err") (EApp (EVar "StaleKey") (EVar "component")))) (arm (PCon "None") () (EApp (EVar "Ok") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("crypto" "sha256_fast") ((mem "sha256Fast" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "InterfaceFault" () ((variant "WrongFormat" (ConPos (TyCon "Int"))) (variant "Malformed" (ConPos (TyCon "SexpError"))) (variant "StaleKey" (ConPos (TyCon "String")))) ())
(DTypeAlias true "KeyGate" () (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "Option") (TyCon "String"))))
(DTypeSig true "noGate" (TyCon "KeyGate"))
(DFunDef false "noGate" (PWild) (EVar "None"))
(DTypeSig true "sha256Hex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Hex" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256Fast") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig true "bodyOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bodyOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "refuse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a")))))
(DFunDef false "refuse" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what")))))))
(DTypeSig true "failure" (TyFun (TyCon "SexpError") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a"))))
(DFunDef false "failure" ((PVar "e")) (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e"))))
(DTypeSig true "renderFramedFault" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceFault") (TyCon "String")))))
(DFunDef false "renderFramedFault" ((PVar "noun") (PVar "version") (PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "noun"))) (ELit (LString " format version "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "version"))) (ELit (LString ""))))
(DFunDef false "renderFramedFault" ((PVar "noun") PWild (PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "noun"))) (ELit (LString ")"))))
(DFunDef false "renderFramedFault" ((PVar "noun") PWild (PCon "StaleKey" (PVar "component"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EMethodRef "display") (EVar "component"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "noun"))) (ELit (LString ")"))))
(DTypeSig true "firstLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "SExp") (TyCon "String")))))))
(DFunDef false "firstLine" ((PVar "path") (PVar "what") (PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "what"))) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "text"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EApp (EVar "Ok") (ETuple (EVar "node") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text")))))))))
(DTypeSig false "pairNode" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "pairNode" ((PVar "s")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "SAtom") (EApp (EVar "snd") (EVar "s"))))))
(DTypeSig true "keyFields" (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "keyFields" ((PVar "key")) (EListLit (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "sources"))) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "pairNode")) (EFieldAccess (EVar "key") "ikSources"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "compiler"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler"))))))
(DTypeSig false "sourceOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "sourceOf" ((PCon "SList" (PList (PCon "SAtom" (PVar "p")) (PCon "SAtom" (PVar "h"))))) (EApp (EVar "Ok") (ETuple (EVar "p") (EVar "h"))))
(DFunDef false "sourceOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sources"))) (fa "seWhat" (ELit (LString "expected a (path hash) pair")))))))
(DTypeSig true "readKeyFields" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "InterfaceKey") (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "readKeyFields" ((PVar "version") (PCons (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PCon "SList" (PVar "srcs")))) (PCons (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PVar "rest")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EVar "sourceOf")) (EVar "srcs"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/compiler"))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EVar "Ok") (ETuple (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))) (EVar "rest"))))))))
(DFunDef false "readKeyFields" (PWild PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected the sources and the compiler fields")))))))
(DTypeSig true "framedHeader" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyFun (TyCon "String") (TyCon "SExp"))))))
(DFunDef false "framedHeader" ((PVar "tag") (PVar "version") (PVar "fields") (PVar "digest")) (EApp (EVar "SList") (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "SAtom") (EVar "tag")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "version")))) (EVar "fields")) (EListLit (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "digest"))) (EApp (EVar "SAtom") (EVar "digest"))))))))
(DTypeSig true "framedFile" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "framedFile" ((PVar "tag") (PVar "version") (PVar "fields") (PVar "covered")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EApp (EVar "framedHeader") (EVar "tag")) (EVar "version")) (EVar "fields")) (EApp (EVar "sha256Hex") (EVar "covered")))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "covered"))) (ELit (LString ""))))
(DTypeSig true "declaredVersion" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredVersion" ((PVar "tag") (PCon "SList" (PCons (PCon "SAtom" (PVar "t")) (PCons (PVar "v") PWild)))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declaredVersion" (PWild PWild) (EVar "None"))
(DTypeSig false "fieldCountWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fieldCountWord" ((PLit (LInt 5))) (ELit (LString "five")))
(DFunDef false "fieldCountWord" ((PLit (LInt 6))) (ELit (LString "six")))
(DFunDef false "fieldCountWord" ((PLit (LInt 7))) (ELit (LString "seven")))
(DFunDef false "fieldCountWord" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))
(DTypeSig true "headerOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String"))))))))
(DFunDef false "headerOf" ((PVar "tag") (PVar "version") (PVar "count") (PCon "SList" (PCons (PCon "SAtom" (PVar "t")) (PCons (PVar "v") (PVar "rest"))))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EBinOp "++" (EBinOp "++" (ELit (LString "header/")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ".1")))) (EVar "v"))) (ELam ((PVar "declared")) (EIf (EBinOp "/=" (EVar "declared") (EVar "version")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EBinOp "++" (EBinOp "++" (ELit (LString "header/")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ".1")))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "declared"))) (ELit (LString ": format version "))) (EApp (EMethodRef "display") (EVar "declared"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "version"))) (ELit (LString ""))))))) (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EVar "rest")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EDictApp "count") (ELit (LInt 3)))) (EMatch (EApp (EApp (EVar "drop") (EDictApp "count")) (EVar "rest")) (arm (PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/digest"))) (EVar "d"))) (ELam ((PVar "digest")) (EApp (EVar "Ok") (ETuple (EApp (EApp (EVar "take") (EDictApp "count")) (EVar "rest")) (EVar "digest")))))) (arm PWild () (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EDictApp "count") (ELit (LInt 3)))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "headerOf" ((PVar "tag") PWild (PVar "count") PWild) (EApp (EApp (EVar "shapeError") (EVar "tag")) (EBinOp "+" (EDictApp "count") (ELit (LInt 3)))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "tag") (PVar "n")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected a ")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString " header of "))) (EApp (EMethodRef "display") (EApp (EVar "fieldCountWord") (EVar "n")))) (ELit (LString " fields"))))))))
(DTypeSig true "verifyDigest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit")))))
(DFunDef false "verifyDigest" ((PVar "claimed") (PVar "covered")) (EIf (EBinOp "/=" (EApp (EVar "sha256Hex") (EVar "covered")) (EVar "claimed")) (EApp (EApp (EVar "refuse") (ELit (LString "header/digest"))) (ELit (LString "the body does not match the digest"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "openFramed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String") (TyCon "String"))))))))
(DFunDef false "openFramed" ((PVar "tag") (PVar "version") (PVar "count") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "file"))) (ELit (LString "no header line"))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "covered")) () (EMatch (EApp (EApp (EVar "declaredVersion") (EVar "tag")) (EVar "node")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "version")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EApp (EApp (EVar "headerOf") (EVar "tag")) (EVar "version")) (EDictApp "count")) (EVar "node")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest")) () (EApp (EVar "Ok") (ETuple (EVar "fields") (EVar "digest") (EVar "covered"))))))))))))))
(DTypeSig true "checkedFramed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))))
(DFunDef false "checkedFramed" ((PVar "tag") (PVar "version") (PVar "gate") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "tag")) (EVar "version")) (ELit (LInt 2))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest") (PVar "covered")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EVar "readKeyFields") (EVar "version")) (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") PWild) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "gated") (EVar "gate")) (EVar "key"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "verifyDigest") (EVar "digest")) (EVar "covered"))) (ELam (PWild) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "covered"))))))))))))))))
(DTypeSig true "gated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "InterfaceKey") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit")))))
(DFunDef false "gated" ((PVar "gate") (PVar "key")) (EMatch (EApp (EVar "gate") (EVar "key")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Err") (EApp (EVar "StaleKey") (EVar "component")))) (arm (PCon "None") () (EApp (EVar "Ok") (ELit LUnit)))))
