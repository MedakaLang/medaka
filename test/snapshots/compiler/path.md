# META
source_lines=52
stages=DESUGAR,MARK
# SOURCE
-- Compiler-private POSIX-"/" path string operations: dirOf / baseOf, chopExt,
-- joinPath, stripMdk and modIdOf, shared by the module-entry mains and the
-- build/test drivers. stdlib/path.mdk is the general path library (dirname,
-- basename, extname, normalize); these helpers cover only what the compiler
-- itself calls.

-- dirname: the path up to (not including) the final "/"; "." if none.
export
dirOf : String -> String
dirOf path = match stringLastIndexOf "/" path
  Some i => stringSlice 0 i path
  None => "."

-- basename: the text after the final "/" (whole string if none).
export
baseOf : String -> String
baseOf path = match stringLastIndexOf "/" path
  Some i => stringSlice (i + 1) (stringLength path) path
  None => path

-- Alias of baseOf (kept for call sites that read more naturally as baseName).
export
baseName : String -> String
baseName path = baseOf path

-- Drop a trailing ".ext" from the basename (no-op if the dot is before a "/").
export
chopExt : String -> String
chopExt path = match stringLastIndexOf "." path
  Some d => match stringLastIndexOf "/" path
    Some s => if s > d then path else stringSlice 0 d path
    None => stringSlice 0 d path
  None => path

export
joinPath : String -> String -> String
joinPath a b = "\{a}/\{b}"

-- Drop a trailing ".mdk".
export
stripMdk : String -> String
stripMdk s =
  let n = stringLength s
  if n >= 4 && stringSlice (n - 4) n s == ".mdk" then
    stringSlice 0 (n - 4) s
  else
    s

-- Module id from a path: basename with the ".mdk" extension stripped.
export
modIdOf : String -> String
modIdOf path = stripMdk (baseName path)
# DESUGAR
(DTypeSig true "dirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "path"))) (arm (PCon "None") () (ELit (LString ".")))))
(DTypeSig true "baseOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseOf" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path"))) (arm (PCon "None") () (EVar "path"))))
(DTypeSig true "baseName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseName" ((PVar "path")) (EApp (EVar "baseOf") (EVar "path")))
(DTypeSig true "chopExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "chopExt" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "."))) (EVar "path")) (arm (PCon "Some" (PVar "d")) () (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "s")) () (EIf (EBinOp ">" (EVar "s") (EVar "d")) (EVar "path") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "path")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "path"))))) (arm (PCon "None") () (EVar "path"))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "stripMdk" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripMdk" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "n")) (EVar "s")) (ELit (LString ".mdk")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "modIdOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modIdOf" ((PVar "path")) (EApp (EVar "stripMdk") (EApp (EVar "baseName") (EVar "path"))))
# MARK
(DTypeSig true "dirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "path"))) (arm (PCon "None") () (ELit (LString ".")))))
(DTypeSig true "baseOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseOf" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path"))) (arm (PCon "None") () (EVar "path"))))
(DTypeSig true "baseName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseName" ((PVar "path")) (EApp (EVar "baseOf") (EVar "path")))
(DTypeSig true "chopExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "chopExt" ((PVar "path")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "."))) (EVar "path")) (arm (PCon "Some" (PVar "d")) () (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "Some" (PVar "s")) () (EIf (EBinOp ">" (EVar "s") (EVar "d")) (EVar "path") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "path")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "path"))))) (arm (PCon "None") () (EVar "path"))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "stripMdk" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripMdk" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "n")) (EVar "s")) (ELit (LString ".mdk")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "modIdOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modIdOf" ((PVar "path")) (EApp (EVar "stripMdk") (EApp (EVar "baseName") (EVar "path"))))
