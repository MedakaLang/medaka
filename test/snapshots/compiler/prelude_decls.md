# META
source_lines=213
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
import types.interface_frame.{
  InterfaceFault(..), KeyGate, checkedFramed, failure, firstLine, framedFile,
  keyFields, noGate, refuse, renderFramedFault
}
import types.prelude_elab.{BinderRun(..), binderRunIs, binderSpan}
import types.prelude_interface.{InterfaceKey(..)}

-- ── the value ───────────────────────────────────────────────────────────────

-- One text's declarations, with the count of the binder ordinals they minted
-- and the first of them.
public export data PreludeTree = PreludeTree {
  ptDecls : List Decl,
  ptBinders : Int,
  ptBase : Int,
}

public export data PreludeDecls = PreludeDecls {
  pdRuntime : PreludeTree,
  pdCore : PreludeTree,
}

treeOf : List Decl -> BinderRun -> PreludeTree
treeOf decls run = PreludeTree {
  ptDecls = decls,
  ptBinders = run.brCount,
  ptBase = run.brFirst,
}

treeRun : PreludeTree -> BinderRun
treeRun tree = BinderRun { brFirst = tree.ptBase, brCount = tree.ptBinders }

-- The value for the two trees, or why it cannot be written.
export
preludeDeclsOf : List Decl -> List Decl -> Result String PreludeDecls
preludeDeclsOf runtime core = match (binderSpan runtime, binderSpan core)
  (Some rr, Some cr) => Ok PreludeDecls {
    pdRuntime = treeOf runtime rr,
    pdCore = treeOf core cr,
  }
  (None, _) => Err "the binder ordinals of runtime.mdk are not one run"
  (_, None) => Err "the binder ordinals of core.mdk are not one run"

-- ── the file ────────────────────────────────────────────────────────────────

-- Distinct from every other framed file's version.
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
  SAtom (intToString pd.pdRuntime.ptBinders),
  SAtom (intToString pd.pdRuntime.ptBase),
  SAtom (intToString pd.pdCore.ptBinders),
  SAtom (intToString pd.pdCore.ptBase),
]

-- The whole file for [pd] under [key]; the key's own format field is not
-- written, the header always carries `declsFormatVersion`.
export
encodeDeclsFile : InterfaceKey -> PreludeDecls -> String
encodeDeclsFile key pd =
  let covered =
    "\{renderSExp (countersNode pd)}\n\{renderSExp (declsSExp pd.pdRuntime.ptDecls)}\n\{renderSExp (declsSExp pd.pdCore.ptDecls)}\n"
  framedFile "medaka-decls" declsFormatVersion (keyFields key) covered

export
renderDeclsFault : InterfaceFault -> String
renderDeclsFault fault =
  renderFramedFault "prelude declarations" declsFormatVersion fault

-- The key a file's header claims and the bytes its digest covers, after its
-- version, header and digest are checked, without decoding them.
export
readDeclsFramed : String -> Result InterfaceFault (InterfaceKey, String)
readDeclsFramed = readDeclsFramedGated noGate

-- `readDeclsFramed` for a file [gate] has to find fresh: a stale key is refused
-- before the digest is checked.
export
readDeclsFramedGated : KeyGate ->
  String ->
  Result InterfaceFault (InterfaceKey, String)
readDeclsFramedGated = checkedFramed "medaka-decls" declsFormatVersion

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
decodeDeclsBody covered = do
  (node, rest) <- firstLine "counters" "no counters line" covered
  counters <- mapErr Malformed (countersOf node)
  decodeBody counters rest

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
  binderRunIs (treeRun pd.pdRuntime) pd.pdRuntime.ptDecls
    && binderRunIs (treeRun pd.pdCore) pd.pdCore.ptDecls

-- The runs the counters line claims for the runtime and the core tree.
countersOf : SExp -> Result SexpError (BinderRun, BinderRun)
countersOf (SList [SAtom "counters", a, b, c, d]) = do
  rn <- atomInt "counters" a
  rb <- atomInt "counters" b
  cn <- atomInt "counters" c
  cb <- atomInt "counters" d
  Ok (
    BinderRun { brFirst = rb, brCount = rn },
    BinderRun { brFirst = cb, brCount = cn },
  )
countersOf _ = Err SexpError {
  seOffset = 0,
  sePath = "counters",
  seWhat = "expected a counters line of four numbers",
}

decodeBody : (BinderRun, BinderRun) ->
  String ->
  Result InterfaceFault PreludeDecls
decodeBody (rr, cr) body
  | negativeRun rr || negativeRun cr = refuse "counters" "a counter is negative"
  | otherwise =
    let cur = cursorOf body
    match readDecls cur
      Err e => failure e
      Ok runtime => match readDecls cur
        Err e => failure e
        Ok core =>
          if cursorAtEnd cur then
            Ok PreludeDecls {
              pdRuntime = treeOf runtime rr,
              pdCore = treeOf core cr,
            }
          else
            failure SexpError {
              seOffset = cursorOffset cur,
              sePath = "",
              seWhat = "trailing text after the core declarations",
            }

negativeRun : BinderRun -> Bool
negativeRun run = run.brFirst < 0 || run.brCount < 0
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "readDecls" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "KeyGate" false) (mem "checkedFramed" false) (mem "failure" false) (mem "firstLine" false) (mem "framedFile" false) (mem "keyFields" false) (mem "noGate" false) (mem "refuse" false) (mem "renderFramedFault" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "BinderRun" true) (mem "binderRunIs" false) (mem "binderSpan" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "PreludeTree" () ((variant "PreludeTree" (ConNamed (field "ptDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "ptBinders" (TyCon "Int")) (field "ptBase" (TyCon "Int"))))) ())
(DData Public "PreludeDecls" () ((variant "PreludeDecls" (ConNamed (field "pdRuntime" (TyCon "PreludeTree")) (field "pdCore" (TyCon "PreludeTree"))))) ())
(DTypeSig false "treeOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BinderRun") (TyCon "PreludeTree"))))
(DFunDef false "treeOf" ((PVar "decls") (PVar "run")) (ERecordCreate "PreludeTree" ((fa "ptDecls" (EVar "decls")) (fa "ptBinders" (EFieldAccess (EVar "run") "brCount")) (fa "ptBase" (EFieldAccess (EVar "run") "brFirst")))))
(DTypeSig false "treeRun" (TyFun (TyCon "PreludeTree") (TyCon "BinderRun")))
(DFunDef false "treeRun" ((PVar "tree")) (ERecordCreate "BinderRun" ((fa "brFirst" (EFieldAccess (EVar "tree") "ptBase")) (fa "brCount" (EFieldAccess (EVar "tree") "ptBinders")))))
(DTypeSig true "preludeDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeDecls")))))
(DFunDef false "preludeDeclsOf" ((PVar "runtime") (PVar "core")) (EMatch (ETuple (EApp (EVar "binderSpan") (EVar "runtime")) (EApp (EVar "binderSpan") (EVar "core"))) (arm (PTuple (PCon "Some" (PVar "rr")) (PCon "Some" (PVar "cr"))) () (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EApp (EApp (EVar "treeOf") (EVar "runtime")) (EVar "rr"))) (fa "pdCore" (EApp (EApp (EVar "treeOf") (EVar "core")) (EVar "cr"))))))) (arm (PTuple (PCon "None") PWild) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of runtime.mdk are not one run")))) (arm (PTuple PWild (PCon "None")) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of core.mdk are not one run"))))))
(DTypeSig false "declsFormatVersion" (TyCon "Int"))
(DFunDef false "declsFormatVersion" () (ELit (LInt 4)))
(DTypeSig true "declsKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "declsKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "declsFormatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeDecls") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pd")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptBase"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptBase"))))))
(DTypeSig true "encodeDeclsFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeDecls") (TyCon "String"))))
(DFunDef false "encodeDeclsFile" ((PVar "key") (PVar "pd")) (EBlock (DoLet false false (PVar "covered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pd"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptDecls"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptDecls"))))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "framedFile") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EApp (EVar "keyFields") (EVar "key"))) (EVar "covered")))))
(DTypeSig true "renderDeclsFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderDeclsFault" ((PVar "fault")) (EApp (EApp (EApp (EVar "renderFramedFault") (ELit (LString "prelude declarations"))) (EVar "declsFormatVersion")) (EVar "fault")))
(DTypeSig true "readDeclsFramed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String")))))
(DFunDef false "readDeclsFramed" () (EApp (EVar "readDeclsFramedGated") (EVar "noGate")))
(DTypeSig true "readDeclsFramedGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))
(DFunDef false "readDeclsFramedGated" () (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")))
(DTypeSig true "readDeclsKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readDeclsKey" ((PVar "text")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "readDeclsFramed") (EVar "text"))))
(DTypeSig true "readDeclsFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeDecls")))))
(DFunDef false "readDeclsFile" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "readDeclsFramed") (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "covered")) () (EApp (EApp (EVar "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pd"))))))))))
(DTypeSig true "decodeDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "decodeDeclsBody" ((PVar "covered")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "counters"))) (ELit (LString "no counters line"))) (EVar "covered"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "rest")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "countersOf") (EVar "node")))) (ELam ((PVar "counters")) (EApp (EApp (EVar "decodeBody") (EVar "counters")) (EVar "rest")))))))))
(DTypeSig true "acceptedDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "acceptedDeclsBody" ((PVar "covered")) (EApp (EApp (EVar "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EIf (EApp (EVar "describes") (EVar "pd")) (EApp (EVar "Ok") (EVar "pd")) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "the binder counters disagree with the trees")))))))
(DTypeSig false "describes" (TyFun (TyCon "PreludeDecls") (TyCon "Bool")))
(DFunDef false "describes" ((PVar "pd")) (EBinOp "&&" (EApp (EApp (EVar "binderRunIs") (EApp (EVar "treeRun") (EFieldAccess (EVar "pd") "pdRuntime"))) (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptDecls")) (EApp (EApp (EVar "binderRunIs") (EApp (EVar "treeRun") (EFieldAccess (EVar "pd") "pdCore"))) (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptDecls"))))
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "BinderRun") (TyCon "BinderRun")))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "a"))) (ELam ((PVar "rn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "rb")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "c"))) (ELam ((PVar "cn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "d"))) (ELam ((PVar "cb")) (EApp (EVar "Ok") (ETuple (ERecordCreate "BinderRun" ((fa "brFirst" (EVar "rb")) (fa "brCount" (EVar "rn")))) (ERecordCreate "BinderRun" ((fa "brFirst" (EVar "cb")) (fa "brCount" (EVar "cn")))))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "decodeBody" (TyFun (TyTuple (TyCon "BinderRun") (TyCon "BinderRun")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls")))))
(DFunDef false "decodeBody" ((PTuple (PVar "rr") (PVar "cr")) (PVar "body")) (EIf (EBinOp "||" (EApp (EVar "negativeRun") (EVar "rr")) (EApp (EVar "negativeRun") (EVar "cr"))) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "a counter is negative"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "runtime")) () (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "core")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EApp (EApp (EVar "treeOf") (EVar "runtime")) (EVar "rr"))) (fa "pdCore" (EApp (EApp (EVar "treeOf") (EVar "core")) (EVar "cr")))))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the core declarations"))))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "negativeRun" (TyFun (TyCon "BinderRun") (TyCon "Bool")))
(DFunDef false "negativeRun" ((PVar "run")) (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "run") "brFirst") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "run") "brCount") (ELit (LInt 0)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "readDecls" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "KeyGate" false) (mem "checkedFramed" false) (mem "failure" false) (mem "firstLine" false) (mem "framedFile" false) (mem "keyFields" false) (mem "noGate" false) (mem "refuse" false) (mem "renderFramedFault" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "BinderRun" true) (mem "binderRunIs" false) (mem "binderSpan" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DData Public "PreludeTree" () ((variant "PreludeTree" (ConNamed (field "ptDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "ptBinders" (TyCon "Int")) (field "ptBase" (TyCon "Int"))))) ())
(DData Public "PreludeDecls" () ((variant "PreludeDecls" (ConNamed (field "pdRuntime" (TyCon "PreludeTree")) (field "pdCore" (TyCon "PreludeTree"))))) ())
(DTypeSig false "treeOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BinderRun") (TyCon "PreludeTree"))))
(DFunDef false "treeOf" ((PVar "decls") (PVar "run")) (ERecordCreate "PreludeTree" ((fa "ptDecls" (EVar "decls")) (fa "ptBinders" (EFieldAccess (EVar "run") "brCount")) (fa "ptBase" (EFieldAccess (EVar "run") "brFirst")))))
(DTypeSig false "treeRun" (TyFun (TyCon "PreludeTree") (TyCon "BinderRun")))
(DFunDef false "treeRun" ((PVar "tree")) (ERecordCreate "BinderRun" ((fa "brFirst" (EFieldAccess (EVar "tree") "ptBase")) (fa "brCount" (EFieldAccess (EVar "tree") "ptBinders")))))
(DTypeSig true "preludeDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeDecls")))))
(DFunDef false "preludeDeclsOf" ((PVar "runtime") (PVar "core")) (EMatch (ETuple (EApp (EVar "binderSpan") (EVar "runtime")) (EApp (EVar "binderSpan") (EVar "core"))) (arm (PTuple (PCon "Some" (PVar "rr")) (PCon "Some" (PVar "cr"))) () (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EApp (EApp (EVar "treeOf") (EVar "runtime")) (EVar "rr"))) (fa "pdCore" (EApp (EApp (EVar "treeOf") (EVar "core")) (EVar "cr"))))))) (arm (PTuple (PCon "None") PWild) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of runtime.mdk are not one run")))) (arm (PTuple PWild (PCon "None")) () (EApp (EVar "Err") (ELit (LString "the binder ordinals of core.mdk are not one run"))))))
(DTypeSig false "declsFormatVersion" (TyCon "Int"))
(DFunDef false "declsFormatVersion" () (ELit (LInt 4)))
(DTypeSig true "declsKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "declsKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "declsFormatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeDecls") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pd")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptBase"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptBinders"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptBase"))))))
(DTypeSig true "encodeDeclsFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeDecls") (TyCon "String"))))
(DFunDef false "encodeDeclsFile" ((PVar "key") (PVar "pd")) (EBlock (DoLet false false (PVar "covered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pd"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptDecls"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptDecls"))))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "framedFile") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")) (EApp (EVar "keyFields") (EVar "key"))) (EVar "covered")))))
(DTypeSig true "renderDeclsFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderDeclsFault" ((PVar "fault")) (EApp (EApp (EApp (EVar "renderFramedFault") (ELit (LString "prelude declarations"))) (EVar "declsFormatVersion")) (EVar "fault")))
(DTypeSig true "readDeclsFramed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String")))))
(DFunDef false "readDeclsFramed" () (EApp (EVar "readDeclsFramedGated") (EVar "noGate")))
(DTypeSig true "readDeclsFramedGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))
(DFunDef false "readDeclsFramedGated" () (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-decls"))) (EVar "declsFormatVersion")))
(DTypeSig true "readDeclsKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readDeclsKey" ((PVar "text")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "readDeclsFramed") (EVar "text"))))
(DTypeSig true "readDeclsFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeDecls")))))
(DFunDef false "readDeclsFile" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readDeclsFramed") (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "covered")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pd"))))))))))
(DTypeSig true "decodeDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "decodeDeclsBody" ((PVar "covered")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "counters"))) (ELit (LString "no counters line"))) (EVar "covered"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "rest")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "countersOf") (EVar "node")))) (ELam ((PVar "counters")) (EApp (EApp (EVar "decodeBody") (EVar "counters")) (EVar "rest")))))))))
(DTypeSig true "acceptedDeclsBody" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls"))))
(DFunDef false "acceptedDeclsBody" ((PVar "covered")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "decodeDeclsBody") (EVar "covered"))) (ELam ((PVar "pd")) (EIf (EApp (EVar "describes") (EVar "pd")) (EApp (EVar "Ok") (EVar "pd")) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "the binder counters disagree with the trees")))))))
(DTypeSig false "describes" (TyFun (TyCon "PreludeDecls") (TyCon "Bool")))
(DFunDef false "describes" ((PVar "pd")) (EBinOp "&&" (EApp (EApp (EVar "binderRunIs") (EApp (EVar "treeRun") (EFieldAccess (EVar "pd") "pdRuntime"))) (EFieldAccess (EFieldAccess (EVar "pd") "pdRuntime") "ptDecls")) (EApp (EApp (EVar "binderRunIs") (EApp (EVar "treeRun") (EFieldAccess (EVar "pd") "pdCore"))) (EFieldAccess (EFieldAccess (EVar "pd") "pdCore") "ptDecls"))))
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "BinderRun") (TyCon "BinderRun")))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "a"))) (ELam ((PVar "rn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "rb")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "c"))) (ELam ((PVar "cn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "d"))) (ELam ((PVar "cb")) (EApp (EVar "Ok") (ETuple (ERecordCreate "BinderRun" ((fa "brFirst" (EVar "rb")) (fa "brCount" (EVar "rn")))) (ERecordCreate "BinderRun" ((fa "brFirst" (EVar "cb")) (fa "brCount" (EVar "cn")))))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "decodeBody" (TyFun (TyTuple (TyCon "BinderRun") (TyCon "BinderRun")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "PreludeDecls")))))
(DFunDef false "decodeBody" ((PTuple (PVar "rr") (PVar "cr")) (PVar "body")) (EIf (EBinOp "||" (EApp (EVar "negativeRun") (EVar "rr")) (EApp (EVar "negativeRun") (EVar "cr"))) (EApp (EApp (EVar "refuse") (ELit (LString "counters"))) (ELit (LString "a counter is negative"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "runtime")) () (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "core")) () (EIf (EApp (EVar "cursorAtEnd") (EVar "cur")) (EApp (EVar "Ok") (ERecordCreate "PreludeDecls" ((fa "pdRuntime" (EApp (EApp (EVar "treeOf") (EVar "runtime")) (EVar "rr"))) (fa "pdCore" (EApp (EApp (EVar "treeOf") (EVar "core")) (EVar "cr")))))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the core declarations"))))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "negativeRun" (TyFun (TyCon "BinderRun") (TyCon "Bool")))
(DFunDef false "negativeRun" ((PVar "run")) (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "run") "brFirst") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "run") "brCount") (ELit (LInt 0)))))
