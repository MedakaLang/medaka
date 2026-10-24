# META
source_lines=206
stages=DESUGAR,MARK
# SOURCE
-- The prelude's desugared declarations as a file.
--
-- `PreludeDecls` holds the declarations `desugar` produced for `runtime.mdk`
-- and for `core.mdk`, with the binder ordinals each carries.  A reader that
-- takes the trees into a process whose binder counter stands elsewhere moves
-- them by one offset (`types.prelude_elab.relocDecls`): the first minted
-- ordinal of the run it holds less the file's, so each tree records where its
-- run starts and how long it is.  A tree that mints no binder records `0 0`;
-- a run that is not contiguous cannot be relocated by one offset and is never
-- written (`preludeDeclsOf`).
--
-- File grammar: the header line, then the counters line, then one line per
-- tree (runtime, then core), each one list of declarations.
--   (medaka-decls <version> (sources ((<path> <hash>) ...)) (compiler <id>)
--     (digest <hex>))
--   (counters <Nr> <B0r> <Nc> <B0c>)
-- The framing is `types.prelude_elab`'s: the digest is the SHA-256 of the bytes
-- after the header line, counters line included, and is checked before any of
-- them is decoded.  The body is taken off the bytes by the cursor readers of
-- `frontend.ast_codec`, never built as an `SExp`.

import frontend.ast.{Decl}
import frontend.ast_codec.{declsSExp, readDecls}
import string as S
import support.sexp_value.{
  SExp(..), SexpError(..), atomInt, cursorAtEnd, cursorOf, cursorOffset,
  parseSExp, renderSExp
}
import types.interface_sexp.{InterfaceFault(..), sha256Hex}
import types.prelude_elab.{
  binderRunIs, binderSpan, checkedFramed, failure, framedHeader, refuse
}
import types.prelude_interface.{InterfaceKey(..)}

-- ── the value ───────────────────────────────────────────────────────────────

public export data PreludeDecls = PreludeDecls {
  pdRuntime : List Decl,
  pdCore : List Decl,
  pdRuntimeBinders : Int,
  pdRuntimeBase : Int,
  pdCoreBinders : Int,
  pdCoreBase : Int,
}

-- The first minted ordinal and the count of a tree's binders, `(0, 0)` for a
-- tree that mints none, or `None` when its ordinals are not one run.
span : List Decl -> Option (Int, Int)
span decls = match binderSpan decls
  (first, count) if first < 0 && count <= 0 => Some (0, 0)
  (_, count) if count < 0 => None
  (first, count) => Some (first, count)

-- The value for the two trees, or why it cannot be written.
export
preludeDeclsOf : List Decl -> List Decl -> Result String PreludeDecls
preludeDeclsOf runtime core = match (span runtime, span core)
  (Some (rb, rn), Some (cb, cn)) => Ok PreludeDecls {
    pdRuntime = runtime,
    pdCore = core,
    pdRuntimeBinders = rn,
    pdRuntimeBase = rb,
    pdCoreBinders = cn,
    pdCoreBase = cb,
  }
  (None, _) => Err "the binder ordinals of runtime.mdk are not one run"
  (_, None) => Err "the binder ordinals of core.mdk are not one run"

-- ── the file ────────────────────────────────────────────────────────────────

-- Distinct from every other framed file's version.
export
declsFormatVersion : Int
declsFormatVersion = 4

-- The key a decls file is validated against: the interface file's key with
-- this file's own format version.
export
declsKeyOf : InterfaceKey -> InterfaceKey
declsKeyOf key = InterfaceKey {
  ikFormat = declsFormatVersion,
  ikSources = key.ikSources,
  ikCompiler = key.ikCompiler,
}

countersNode : PreludeDecls -> SExp
countersNode pd = SList [
  SAtom "counters",
  SAtom (intToString pd.pdRuntimeBinders),
  SAtom (intToString pd.pdRuntimeBase),
  SAtom (intToString pd.pdCoreBinders),
  SAtom (intToString pd.pdCoreBase),
]

-- The whole file for [pd] under [key]; the key's own format field is not
-- written, the header always carries `declsFormatVersion`.
export
encodeDeclsFile : InterfaceKey -> PreludeDecls -> String
encodeDeclsFile key pd =
  let covered =
    "\{renderSExp (countersNode pd)}\n\{renderSExp (declsSExp pd.pdRuntime)}\n\{renderSExp (declsSExp pd.pdCore)}\n"
  "\{renderSExp (framedHeader "medaka-decls" declsFormatVersion key (sha256Hex covered))}\n\{covered}"

export
renderDeclsFault : InterfaceFault -> String
renderDeclsFault (WrongFormat v) =
  "prelude declarations format version \{v}, this compiler reads \{declsFormatVersion}"
renderDeclsFault (Malformed e) =
  "\{e.sePath}: \{e.seWhat} (prelude declarations)"

-- The key a file's header claims and the bytes its digest covers, after its
-- version, header and digest are checked, without decoding them.
export
readDeclsFramed : String -> Result InterfaceFault (InterfaceKey, String)
readDeclsFramed text = checkedFramed "medaka-decls" declsFormatVersion text

-- The key a file's header claims, after its version, header and digest are
-- checked, without decoding the body.
export
readDeclsKey : String -> Result InterfaceFault InterfaceKey
readDeclsKey text = map fst (readDeclsFramed text)

-- The value of a file, or why it is refused: the version first, then the
-- header, then the digest, then the counters line, then the body.  The key is
-- the one the header carries.
export
readDeclsFile : String -> Result InterfaceFault (InterfaceKey, PreludeDecls)
readDeclsFile text = do
  (key, covered) <- readDeclsFramed text
  pd <- decodeDeclsBody covered
  Ok (key, pd)

-- The value of the bytes a file's digest covers (`readDeclsFramed`): the
-- counters line, then the two trees.
export
decodeDeclsBody : String -> Result InterfaceFault PreludeDecls
decodeDeclsBody covered = match S.indexOf "\n" covered
  None => refuse "counters" "no counters line"
  Some j => match parseSExp (S.take j covered)
    Err e => failure e
    Ok node => match countersOf node
      Err e => failure e
      Ok counters => decodeBody counters (S.drop (j + 1) covered)

-- The value of the bytes a file's digest covers when it is also one a reader
-- may seed from: its counters describe its trees.  The loader and `interface
-- verify` both decide acceptance here.
export
acceptedDeclsBody : String -> Result InterfaceFault PreludeDecls
acceptedDeclsBody covered = do
  pd <- decodeDeclsBody covered
  if describes pd then
    Ok pd
  else
    refuse "counters" "the binder counters disagree with the trees"

-- Whether each tree's minted binder ordinals are exactly the run its counters
-- claim, each once.  The digest covers the counters line, so only a writer that
-- lied passes the digest and fails here; a lie would shift every id minted after
-- the tree.
describes : PreludeDecls -> Bool
describes pd =
  binderRunIs pd.pdRuntimeBinders pd.pdRuntimeBase pd.pdRuntime
    && binderRunIs pd.pdCoreBinders pd.pdCoreBase pd.pdCore

countersOf : SExp -> Result SexpError (Int, Int, Int, Int)
countersOf (SList [SAtom "counters", a, b, c, d]) = do
  rn <- atomInt "counters" a
  rb <- atomInt "counters" b
  cn <- atomInt "counters" c
  cb <- atomInt "counters" d
  Ok (rn, rb, cn, cb)
countersOf _ = Err SexpError {
  seOffset = 0,
  sePath = "counters",
  seWhat = "expected a counters line of four numbers",
}

decodeBody : (Int, Int, Int, Int) ->
  String ->
  Result InterfaceFault PreludeDecls
decodeBody (rn, rb, cn, cb) body
  | rn < 0 || rb < 0 || cn < 0 || cb < 0 =
    refuse "counters" "a counter is negative"
  | otherwise =
    let cur = cursorOf body
    match readDecls cur
      Err e => failure e
      Ok runtime => match readDecls cur
        Err e => failure e
        Ok core =>
          if cursorAtEnd cur then
            Ok PreludeDecls {
              pdRuntime = runtime,
              pdCore = core,
              pdRuntimeBinders = rn,
              pdRuntimeBase = rb,
              pdCoreBinders = cn,
              pdCoreBase = cb,
            }
          else
            failure SexpError {
              seOffset = cursorOffset cur,
              sePath = "",
              seWhat = "trailing text after the core declarations",
            }
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "readDecls" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "InterfaceFault" true) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "binderRunIs" false) (mem "binderSpan" false) (mem "checkedFramed" false) (mem "failure" false) (mem "framedHeader" false) (mem "refuse" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "PreludeDecls" () ((variant "PreludeDecls" (ConNamed (field "pdRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "pdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "pdRuntimeBinders" (TyCon "Int")) (field "pdRuntimeBase" (TyCon "Int")) (field "pdCoreBinders" (TyCon "Int")) (field "pdCoreBase" (TyCon "Int"))))) ())
(DTypeSig false "span" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "span" ((PVar "decls")) (EMatch (EApp (EVar "binderSpan") (EVar "decls")) (arm (PTuple (PVar "first") (PVar "count")) ((GBool (EBinOp "&&" (EBinOp "<" (EVar "first") (ELit (LInt 0))) (EBinOp "<=" (EVar "count") (ELit (LInt 0)))))) (EApp (EVar "Some") (ETuple (ELit (LInt 0)) (ELit (LInt 0))))) (arm (PTuple PWild (PVar "count")) ((GBool (EBinOp "<" (EVar "count") (ELit (LInt 0))))) (EVar "None")) (arm (PTuple (PVar "first") (PVar "count")) () (EApp (EVar "Some") (ETuple (EVar "first") (EVar "count"))))))
(DTypeSig true "preludeDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeDecls")))))
(DFunDef false "preludeDeclsOf" ((PVar "runtime") (PVar "core")) (EMatch (ETuple (EApp (EVar "span") (EVar "runtime")) (EApp (EVar "span") (EVar "core"))) (arm (PTuple (PCon "Some" (PTuple (PVar "rb") (PVar "rn"))) (PCon "Some" (PTuple (PVar "cb") (PVar "cn")))) () (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EVar "runtime")) (fa "pdCore" (EVar "core")) (fa "pdRuntimeBinders" (EVar "rn")) (fa "pdRuntimeBase" (EVar "rb")) (fa "pdCoreBinders" (EVar "cn")) (fa "pdCoreBase" (EVar "cb")))))) (arm (PTuple (PCon "None") PWild) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of runtime.mdk are not one run")))) (arm (PTuple PWild (PCon "None")) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of core.mdk are not one run"))))))
(DTypeSig true "declsFormatVersion" (TyCon "Int"))
(DFunDef false "declsFormatVersion" () (ELit (LInt 4)))
(DTypeSig true "declsKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "declsKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "declsFormatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeDecls") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pd")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdRuntimeBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdRuntimeBase"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdCoreBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdCoreBase"))))))
(DTypeSig true "encodeDeclsFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeDecls") (TyCon "String"))))
(DFunDef false "encodeDeclsFile" ((PVar "key") (PVar "pd")) (EBlock (DoLet false false (PVar "covered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pd"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pd") "pdRuntime"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pd") "pdCore"))))) (ELit (LString "\n")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EApp (EVar "framedHeader") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EVar "key")) (EApp (EVar "sha256Hex") (EVar "covered")))))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "covered"))) (ELit (LString ""))))))
(DTypeSig true "renderDeclsFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderDeclsFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "prelude declarations format version ")) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "declsFormatVersion"))) (ELit (LString ""))))
(DFunDef false "renderDeclsFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " (prelude declarations)"))))
(DTypeSig true "readDeclsFramed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String")))))
(DFunDef false "readDeclsFramed" ((PVar "text")) (EApp (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EVar "text")))
(DTypeSig true "readDeclsKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readDeclsKey" ((PVar "text")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "readDeclsFramed") (EVar "text"))))
(DTypeSig true "readDeclsFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeDecls")))))
(DFunDef false "readDeclsFile" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "readDeclsFramed") (EVar "text"))) (ELam ((PTuple (PVar "key") (PVar "covered"))) (EApp (EApp (EVar "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pd"))))))))
(DTypeSig true "decodeDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "decodeDeclsBody" ((PVar "covered")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "covered")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "no counters line")))) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "j")) (EVar "covered"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EMatch (EApp (EVar "countersOf") (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "counters")) () (EApp (EApp (EVar "decodeBody") (EVar "counters")) (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "covered"))))))))))
(DTypeSig true "acceptedDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "acceptedDeclsBody" ((PVar "covered")) (EApp (EApp (EVar "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EIf (EApp (EVar "describes") (EVar "pd")) (EApp (EVar "Ok") (EVar "pd")) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "the binder counters disagree with the trees")))))))
(DTypeSig false "describes" (TyFun (TyCon "PreludeDecls") (TyCon "Bool")))
(DFunDef false "describes" ((PVar "pd")) (EBinOp "&&" (EApp (EApp (EApp (EVar "binderRunIs") (EFieldAccess (EVar "pd") "pdRuntimeBinders")) (EFieldAccess (EVar "pd") "pdRuntimeBase")) (EFieldAccess (EVar "pd") "pdRuntime")) (EApp (EApp (EApp (EVar "binderRunIs") (EFieldAccess (EVar "pd") "pdCoreBinders")) (EFieldAccess (EVar "pd") "pdCoreBase")) (EFieldAccess (EVar "pd") "pdCore"))))
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "a"))) (ELam ((PVar "rn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "rb")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "c"))) (ELam ((PVar "cn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "d"))) (ELam ((PVar "cb")) (EApp (EVar "Ok") (ETuple (EVar "rn") (EVar "rb") (EVar "cn") (EVar "cb"))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "decodeBody" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls")))))
(DFunDef false "decodeBody" ((PTuple (PVar "rn") (PVar "rb") (PVar "cn") (PVar "cb")) (PVar "body")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "rn") (ELit (LInt 0))) (EBinOp "<" (EVar "rb") (ELit (LInt 0)))) (EBinOp "<" (EVar "cn") (ELit (LInt 0)))) (EBinOp "<" (EVar "cb") (ELit (LInt 0)))) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "a counter is negative"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "runtime")) () (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "core")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EVar "runtime")) (fa "pdCore" (EVar "core")) (fa "pdRuntimeBinders" (EVar "rn")) (fa "pdRuntimeBase" (EVar "rb")) (fa "pdCoreBinders" (EVar "cn")) (fa "pdCoreBase" (EVar "cb"))))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the core declarations"))))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "readDecls" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "InterfaceFault" true) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "binderRunIs" false) (mem "binderSpan" false) (mem "checkedFramed" false) (mem "failure" false) (mem "framedHeader" false) (mem "refuse" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "PreludeDecls" () ((variant "PreludeDecls" (ConNamed (field "pdRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "pdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "pdRuntimeBinders" (TyCon "Int")) (field "pdRuntimeBase" (TyCon "Int")) (field "pdCoreBinders" (TyCon "Int")) (field "pdCoreBase" (TyCon "Int"))))) ())
(DTypeSig false "span" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "span" ((PVar "decls")) (EMatch (EApp (EVar "binderSpan") (EVar "decls")) (arm (PTuple (PVar "first") (PVar "count")) ((GBool (EBinOp "&&" (EBinOp "<" (EVar "first") (ELit (LInt 0))) (EBinOp "<=" (EDictApp "count") (ELit (LInt 0)))))) (EApp (EVar "Some") (ETuple (ELit (LInt 0)) (ELit (LInt 0))))) (arm (PTuple PWild (PVar "count")) ((GBool (EBinOp "<" (EDictApp "count") (ELit (LInt 0))))) (EVar "None")) (arm (PTuple (PVar "first") (PVar "count")) () (EApp (EVar "Some") (ETuple (EVar "first") (EDictApp "count"))))))
(DTypeSig true "preludeDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeDecls")))))
(DFunDef false "preludeDeclsOf" ((PVar "runtime") (PVar "core")) (EMatch (ETuple (EApp (EVar "span") (EVar "runtime")) (EApp (EVar "span") (EVar "core"))) (arm (PTuple (PCon "Some" (PTuple (PVar "rb") (PVar "rn"))) (PCon "Some" (PTuple (PVar "cb") (PVar "cn")))) () (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EVar "runtime")) (fa "pdCore" (EVar "core")) (fa "pdRuntimeBinders" (EVar "rn")) (fa "pdRuntimeBase" (EVar "rb")) (fa "pdCoreBinders" (EVar "cn")) (fa "pdCoreBase" (EVar "cb")))))) (arm (PTuple (PCon "None") PWild) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of runtime.mdk are not one run")))) (arm (PTuple PWild (PCon "None")) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of core.mdk are not one run"))))))
(DTypeSig true "declsFormatVersion" (TyCon "Int"))
(DFunDef false "declsFormatVersion" () (ELit (LInt 4)))
(DTypeSig true "declsKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "declsKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "declsFormatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeDecls") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pd")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdRuntimeBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdRuntimeBase"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdCoreBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pd") "pdCoreBase"))))))
(DTypeSig true "encodeDeclsFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeDecls") (TyCon "String"))))
(DFunDef false "encodeDeclsFile" ((PVar "key") (PVar "pd")) (EBlock (DoLet false false (PVar "covered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pd"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pd") "pdRuntime"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pd") "pdCore"))))) (ELit (LString "\n")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EApp (EVar "framedHeader") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EVar "key")) (EApp (EVar "sha256Hex") (EVar "covered")))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "covered"))) (ELit (LString ""))))))
(DTypeSig true "renderDeclsFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderDeclsFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "prelude declarations format version ")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "declsFormatVersion"))) (ELit (LString ""))))
(DFunDef false "renderDeclsFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " (prelude declarations)"))))
(DTypeSig true "readDeclsFramed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String")))))
(DFunDef false "readDeclsFramed" ((PVar "text")) (EApp (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EVar "text")))
(DTypeSig true "readDeclsKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readDeclsKey" ((PVar "text")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "readDeclsFramed") (EVar "text"))))
(DTypeSig true "readDeclsFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeDecls")))))
(DFunDef false "readDeclsFile" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readDeclsFramed") (EVar "text"))) (ELam ((PTuple (PVar "key") (PVar "covered"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pd"))))))))
(DTypeSig true "decodeDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "decodeDeclsBody" ((PVar "covered")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "covered")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "no counters line")))) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "j")) (EVar "covered"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EMatch (EApp (EVar "countersOf") (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "counters")) () (EApp (EApp (EVar "decodeBody") (EVar "counters")) (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "covered"))))))))))
(DTypeSig true "acceptedDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "acceptedDeclsBody" ((PVar "covered")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EIf (EApp (EVar "describes") (EVar "pd")) (EApp (EVar "Ok") (EVar "pd")) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "the binder counters disagree with the trees")))))))
(DTypeSig false "describes" (TyFun (TyCon "PreludeDecls") (TyCon "Bool")))
(DFunDef false "describes" ((PVar "pd")) (EBinOp "&&" (EApp (EApp (EApp (EVar "binderRunIs") (EFieldAccess (EVar "pd") "pdRuntimeBinders")) (EFieldAccess (EVar "pd") "pdRuntimeBase")) (EFieldAccess (EVar "pd") "pdRuntime")) (EApp (EApp (EApp (EVar "binderRunIs") (EFieldAccess (EVar "pd") "pdCoreBinders")) (EFieldAccess (EVar "pd") "pdCoreBase")) (EFieldAccess (EVar "pd") "pdCore"))))
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "a"))) (ELam ((PVar "rn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "rb")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "c"))) (ELam ((PVar "cn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "d"))) (ELam ((PVar "cb")) (EApp (EVar "Ok") (ETuple (EVar "rn") (EVar "rb") (EVar "cn") (EVar "cb"))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "decodeBody" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls")))))
(DFunDef false "decodeBody" ((PTuple (PVar "rn") (PVar "rb") (PVar "cn") (PVar "cb")) (PVar "body")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "rn") (ELit (LInt 0))) (EBinOp "<" (EVar "rb") (ELit (LInt 0)))) (EBinOp "<" (EVar "cn") (ELit (LInt 0)))) (EBinOp "<" (EVar "cb") (ELit (LInt 0)))) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "a counter is negative"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "runtime")) () (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "core")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EVar "runtime")) (fa "pdCore" (EVar "core")) (fa "pdRuntimeBinders" (EVar "rn")) (fa "pdRuntimeBase" (EVar "rb")) (fa "pdCoreBinders" (EVar "cn")) (fa "pdCoreBase" (EVar "cb"))))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the core declarations"))))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
