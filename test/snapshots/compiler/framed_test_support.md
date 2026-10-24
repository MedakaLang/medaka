# META
source_lines=39
stages=DESUGAR,MARK
# SOURCE
-- Helpers the tests of the framed prelude files share (`prelude_elab_test`,
-- `prelude_decls_test`, `driver/build_cmd_test`): a key, a tree's text, and a
-- file with its digest recomputed over a changed body.
import frontend.ast.{Decl}
import frontend.ast_codec.{declsSExp}
import string as S
import support.sexp_value.{renderSExp}
import types.interface_frame.{sha256Hex}
import types.prelude_interface.{InterfaceKey, interfaceKeyOf}

-- The key the rows write under, at the format [version] of the file's kind.
export
testKeyAt : Int -> InterfaceKey
testKeyAt version =
  interfaceKeyOf
    version
    [("runtime.mdk", "aa"), ("core.mdk", "bb")]
    "compiler-x"

-- The text of a declaration list, as the file writes it.
export
treeText : List Decl -> String
treeText ds = renderSExp (declsSExp ds)

-- [file] with its header's digest rewritten to match [body], which replaces
-- everything after the first line: only the body is wrong.
export
withDigestOf : String -> String -> String
withDigestOf file body = match S.indexOf "\n" file
  None => file
  Some i =>
    let header = S.take i file
    let claimed =
      S.take
        64
        (S.drop
          (S.length "(digest " + optionOr 0 (S.indexOf "(digest " header))
          header)
    "\{S.replace claimed (sha256Hex body) header}\n\{body}"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" false) (mem "interfaceKeyOf" false))))
(DTypeSig true "testKeyAt" (TyFun (TyCon "Int") (TyCon "InterfaceKey")))
(DFunDef false "testKeyAt" ((PVar "version")) (EApp (EApp (EApp (EVar "interfaceKeyOf") (EVar "version")) (EListLit (ETuple (ELit (LString "runtime.mdk")) (ELit (LString "aa"))) (ETuple (ELit (LString "core.mdk")) (ELit (LString "bb"))))) (ELit (LString "compiler-x"))))
(DTypeSig true "treeText" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "treeText" ((PVar "ds")) (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EVar "ds"))))
(DTypeSig true "withDigestOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withDigestOf" ((PVar "file") (PVar "body")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "file")) (arm (PCon "None") () (EVar "file")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "file"))) (DoLet false false (PVar "claimed") (EApp (EApp (EVar "S.take") (ELit (LInt 64))) (EApp (EApp (EVar "S.drop") (EBinOp "+" (EApp (EVar "S.length") (ELit (LString "(digest "))) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "S.indexOf") (ELit (LString "(digest "))) (EVar "header"))))) (EVar "header")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "S.replace") (EVar "claimed")) (EApp (EVar "sha256Hex") (EVar "body"))) (EVar "header")))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "renderSExp" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" false) (mem "interfaceKeyOf" false))))
(DTypeSig true "testKeyAt" (TyFun (TyCon "Int") (TyCon "InterfaceKey")))
(DFunDef false "testKeyAt" ((PVar "version")) (EApp (EApp (EApp (EVar "interfaceKeyOf") (EVar "version")) (EListLit (ETuple (ELit (LString "runtime.mdk")) (ELit (LString "aa"))) (ETuple (ELit (LString "core.mdk")) (ELit (LString "bb"))))) (ELit (LString "compiler-x"))))
(DTypeSig true "treeText" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "treeText" ((PVar "ds")) (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EVar "ds"))))
(DTypeSig true "withDigestOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withDigestOf" ((PVar "file") (PVar "body")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "file")) (arm (PCon "None") () (EVar "file")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "file"))) (DoLet false false (PVar "claimed") (EApp (EApp (EVar "S.take") (ELit (LInt 64))) (EApp (EApp (EVar "S.drop") (EBinOp "+" (EApp (EVar "S.length") (ELit (LString "(digest "))) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "S.indexOf") (ELit (LString "(digest "))) (EVar "header"))))) (EVar "header")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "S.replace") (EVar "claimed")) (EApp (EVar "sha256Hex") (EVar "body"))) (EVar "header")))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))))
